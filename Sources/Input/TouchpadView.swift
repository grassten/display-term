import UIKit

/// The phone's screen as a trackpad while docked.
///
/// Raw touch handling rather than gesture recognizers. A trackpad wants one classifier
/// that sees every touch; the recognizers fought each other instead: tap and long-press
/// both fired for a slow tap (two clicks, sometimes a double-click that selected a
/// word), a tap whose finger drifted a few points was swallowed by the pan and never
/// clicked, and two quick taps on different targets counted as a double-click.
///
/// 1 finger: move · tap: click · tap-tap: double-click · hold still, then move: drag or
/// select · 2 fingers: scroll with momentum · 2-finger tap: right-click · pinch: zoom ·
/// 3-finger swipe left/right: back/forward.
final class TouchpadView: UIView {
    weak var pointer: PointerController?
    var onZoom: ((CGFloat) -> Void)?
    /// -1 back, +1 forward.
    var onNavigate: ((Int) -> Void)?

    enum Tunables {
        /// A single finger down and up within this time and drift is a click.
        static let tapMaxDuration: TimeInterval = 0.3
        static let tapSlop: CGFloat = 10
        /// Finger drift ignored before the cursor starts moving, so a tap does not nudge
        /// the cursor off its target.
        static let moveSlop: CGFloat = 3
        /// Hold still this long to press the button (then move to drag or select).
        static let holdToDrag: TimeInterval = 0.35
        static let twoFingerTapMaxDuration: TimeInterval = 0.35
        /// Relative change in finger distance per zoom step.
        static let pinchStep: CGFloat = 0.18
        /// Travel before a two-finger gesture commits to an axis.
        static let axisLockDistance: CGFloat = 8
        static let swipeDistance: CGFloat = 80
        /// Momentum after a two-finger scroll: minimum release speed (phone pt/s) and the
        /// per-frame decay at 60 Hz. UIScrollView's normal rate is 0.998 per millisecond,
        /// which is 0.967 per frame; a little more keeps long pages from running away.
        static let flingMinSpeed: CGFloat = 60
        static let flingDeceleration: CGFloat = 0.96
        static let flingStopSpeed: CGFloat = 8
    }

    private struct TouchInfo {
        let start: CGPoint
        let startTime: TimeInterval
        var last: CGPoint
        var lastTime: TimeInterval
    }

    private enum Phase { case idle, pending, moving, dragging, twoFinger, threeFinger, done }

    private var phase: Phase = .idle
    private var active: [UITouch: TouchInfo] = [:]
    private var maxTouches = 0
    private var gestureStart: TimeInterval = 0
    private var holdTimer: Timer?
    private var smoothedSpeed: CGFloat = 0

    // Two-finger state
    private var lastCentroid: CGPoint = .zero
    private var lastCentroidTime: TimeInterval = 0
    private var startCentroid: CGPoint = .zero
    private var lastDistance: CGFloat = 0
    private var pinchAccum: CGFloat = 1
    private enum Axis { case undecided, vertical, horizontal, pinch }
    private var axis: Axis = .undecided
    private var travel: CGPoint = .zero
    private var scrollVelocity: CGPoint = .zero

    // Momentum
    private var flingLink: CADisplayLink?
    private var flingVelocity: CGPoint = .zero
    private var flingLastTime: CFTimeInterval = 0

    private let hintLabel = UILabel()
    private let haptic = UIImpactFeedbackGenerator(style: .light)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .secondarySystemBackground
        layer.cornerRadius = 14
        layer.borderWidth = 1
        layer.borderColor = UIColor.separator.cgColor
        isMultipleTouchEnabled = true

        hintLabel.text = "Trackpad\n1 finger move · tap click · hold, then move to drag\n2 fingers scroll · 2-finger tap right-click · pinch zoom\n3-finger swipe back / forward"
        hintLabel.numberOfLines = 0
        hintLabel.textAlignment = .center
        hintLabel.font = .systemFont(ofSize: 12)
        hintLabel.textColor = .tertiaryLabel
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hintLabel)
        NSLayoutConstraint.activate([
            hintLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            hintLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            hintLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 8),
            hintLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
        ])
        haptic.prepare()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Touches

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        stopFling()
        let now = Date().timeIntervalSinceReferenceDate
        for t in touches {
            let p = t.location(in: self)
            active[t] = TouchInfo(start: p, startTime: now, last: p, lastTime: now)
        }
        maxTouches = max(maxTouches, active.count)
        switch active.count {
        case 1:
            phase = .pending
            gestureStart = now
            smoothedSpeed = 0
            holdTimer?.invalidate()
            holdTimer = Timer.scheduledTimer(withTimeInterval: Tunables.holdToDrag, repeats: false) { [weak self] _ in
                self?.beginDrag()
            }
        case 2:
            holdTimer?.invalidate()
            if phase == .dragging { return } // a second finger during a drag is ignored
            phase = .twoFinger
            gestureStart = now
            axis = .undecided
            travel = .zero
            pinchAccum = 1
            scrollVelocity = .zero
            let pts = active.values.map(\.last)
            lastCentroid = centroid(pts)
            startCentroid = lastCentroid
            lastCentroidTime = now
            lastDistance = distance(pts)
        default:
            holdTimer?.invalidate()
            if phase == .dragging { return }
            phase = .threeFinger
            startCentroid = centroid(active.values.map(\.last))
            lastCentroid = startCentroid
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        let now = Date().timeIntervalSinceReferenceDate
        for t in touches {
            guard var info = active[t] else { continue }
            let p = t.location(in: self)
            let dx = p.x - info.last.x, dy = p.y - info.last.y
            let dt = max(now - info.lastTime, 1.0 / 240.0)
            info.last = p
            info.lastTime = now
            active[t] = info

            switch phase {
            case .pending:
                let drift = hypot(p.x - info.start.x, p.y - info.start.y)
                if drift > Tunables.moveSlop {
                    holdTimer?.invalidate()
                    phase = .moving
                    // Catch up on the drift so small precise motions are not lost.
                    moveCursor(dx: p.x - info.start.x, dy: p.y - info.start.y, dt: now - info.startTime)
                }
            case .moving, .dragging:
                moveCursor(dx: dx, dy: dy, dt: dt)
            case .twoFinger, .threeFinger:
                break // handled below from the centroid of all fingers
            case .idle, .done:
                break
            }
        }

        if phase == .twoFinger, active.count == 2 {
            let pts = active.values.map(\.last)
            let c = centroid(pts)
            let dt = max(now - lastCentroidTime, 1.0 / 240.0)
            var dx = c.x - lastCentroid.x, dy = c.y - lastCentroid.y
            lastCentroid = c
            lastCentroidTime = now
            travel.x += dx; travel.y += dy

            let d = distance(pts)
            if lastDistance > 0 { pinchAccum *= d / lastDistance }
            lastDistance = d
            if axis == .undecided || axis == .pinch {
                if pinchAccum > 1 + Tunables.pinchStep { axis = .pinch; onZoom?(0.1); pinchAccum = 1 }
                else if pinchAccum < 1 - Tunables.pinchStep { axis = .pinch; onZoom?(-0.1); pinchAccum = 1 }
            }
            if axis == .pinch { return }
            if axis == .undecided {
                guard hypot(travel.x, travel.y) > Tunables.axisLockDistance else { return }
                axis = abs(travel.y) >= abs(travel.x) ? .vertical : .horizontal
                dx = travel.x; dy = travel.y
            }
            if axis == .vertical { dx = 0 } else { dy = 0 }
            let v = CGPoint(x: dx / dt, y: dy / dt)
            scrollVelocity = CGPoint(x: scrollVelocity.x * 0.6 + v.x * 0.4, y: scrollVelocity.y * 0.6 + v.y * 0.4)
            sendScroll(dx: dx, dy: dy)
        } else if phase == .threeFinger {
            lastCentroid = centroid(active.values.map(\.last))
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { endTouches(touches, cancelled: false) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { endTouches(touches, cancelled: true) }

    private func endTouches(_ touches: Set<UITouch>, cancelled: Bool) {
        let now = Date().timeIntervalSinceReferenceDate
        var lifted: [TouchInfo] = []
        for t in touches {
            if let info = active.removeValue(forKey: t) { lifted.append(info) }
        }
        if !active.isEmpty {
            // Fingers remain. A two-finger gesture ends when the first finger lifts, and
            // the leftover finger must not start moving the cursor.
            if phase == .twoFinger { finishTwoFinger(now: now, cancelled: cancelled); phase = .done }
            return
        }

        holdTimer?.invalidate()
        let duration = now - gestureStart
        switch phase {
        case .pending:
            // Never moved past the slop and the hold did not fire: a click, however slow.
            if !cancelled { pointer?.tap(.left) }
        case .moving:
            if let info = lifted.first, maxTouches == 1, !cancelled,
               duration <= Tunables.tapMaxDuration,
               hypot(info.last.x - info.start.x, info.last.y - info.start.y) <= Tunables.tapSlop {
                pointer?.tap(.left)
            }
        case .dragging:
            pointer?.button(.left, pressed: false)
        case .twoFinger:
            finishTwoFinger(now: now, cancelled: cancelled)
        case .threeFinger:
            let dx = lastCentroid.x - startCentroid.x, dy = lastCentroid.y - startCentroid.y
            if !cancelled, abs(dx) > Tunables.swipeDistance, abs(dx) > 2 * abs(dy) {
                onNavigate?(dx > 0 ? -1 : 1) // swipe right goes back, as in Safari
            }
        case .idle, .done:
            break
        }
        phase = .idle
        maxTouches = 0
    }

    private func finishTwoFinger(now: TimeInterval, cancelled: Bool) {
        guard !cancelled, maxTouches == 2 else { return }
        let drift = hypot(lastCentroid.x - startCentroid.x, lastCentroid.y - startCentroid.y)
        if axis == .undecided, now - gestureStart <= Tunables.twoFingerTapMaxDuration, drift <= Tunables.tapSlop {
            pointer?.tap(.right)
            return
        }
        if axis == .vertical || axis == .horizontal {
            let speed = hypot(scrollVelocity.x, scrollVelocity.y)
            if speed > Tunables.flingMinSpeed { startFling(velocity: scrollVelocity) }
        }
    }

    private func beginDrag() {
        guard phase == .pending else { return }
        phase = .dragging
        haptic.impactOccurred()
        pointer?.button(.left, pressed: true)
    }

    // MARK: Cursor and scrolling

    private func moveCursor(dx: CGFloat, dy: CGFloat, dt: TimeInterval) {
        let speed = hypot(dx, dy) / CGFloat(max(dt, 1.0 / 240.0))
        smoothedSpeed = smoothedSpeed * 0.6 + speed * 0.4
        let s = PointerController.Settings.self
        let mult = 1 + min(smoothedSpeed / s.touchpadAccelerationSpeed, s.touchpadAccelerationCap)
        pointer?.move(dx: dx * mult, dy: dy * mult, gain: s.touchpadGain, accelerate: false)
    }

    /// `dx`/`dy` are finger deltas in phone points. Fingers moving up reveal content
    /// below, so the page scrolls by the opposite amount (natural scrolling).
    private func sendScroll(dx: CGFloat, dy: CGFloat) {
        let g = PointerController.Settings.touchScrollGain
        pointer?.scroll(dx: -dx * g, dy: -dy * g)
    }

    private func startFling(velocity: CGPoint) {
        stopFling()
        flingVelocity = velocity
        flingLastTime = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(flingTick(_:)))
        link.add(to: .main, forMode: .common)
        flingLink = link
    }

    private func stopFling() {
        flingLink?.invalidate()
        flingLink = nil
    }

    @objc private func flingTick(_ link: CADisplayLink) {
        let now = link.timestamp
        let dt = CGFloat(max(min(now - flingLastTime, 0.05), 0.001))
        flingLastTime = now
        sendScroll(dx: flingVelocity.x * dt, dy: flingVelocity.y * dt)
        let decay = pow(Tunables.flingDeceleration, dt * 60)
        flingVelocity.x *= decay
        flingVelocity.y *= decay
        if hypot(flingVelocity.x, flingVelocity.y) < Tunables.flingStopSpeed { stopFling() }
    }

    // MARK: Geometry

    private func centroid(_ pts: [CGPoint]) -> CGPoint {
        guard !pts.isEmpty else { return .zero }
        let sx = pts.reduce(0) { $0 + $1.x }, sy = pts.reduce(0) { $0 + $1.y }
        return CGPoint(x: sx / CGFloat(pts.count), y: sy / CGFloat(pts.count))
    }

    private func distance(_ pts: [CGPoint]) -> CGFloat {
        guard pts.count >= 2 else { return 0 }
        return hypot(pts[0].x - pts[1].x, pts[0].y - pts[1].y)
    }
}
