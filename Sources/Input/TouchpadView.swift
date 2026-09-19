import UIKit

/// The phone's screen as a trackpad while docked.
/// 1 finger: move · tap: click · double-tap: double-click · 2 fingers: scroll ·
/// 2-finger tap: right-click · long-press then move: drag/select · pinch: zoom.
final class TouchpadView: UIView, UIGestureRecognizerDelegate {
    weak var pointer: PointerController?
    var onZoom: ((CGFloat) -> Void)?

    private let hintLabel = UILabel()
    private var lastPan: CGPoint = .zero
    private var lastTwoFingerPan: CGPoint = .zero
    private var lastTapTime: TimeInterval = 0
    private var tapCount = 0
    private var dragging = false
    private var dragLast: CGPoint = .zero
    private let haptic = UIImpactFeedbackGenerator(style: .light)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .secondarySystemBackground
        layer.cornerRadius = 14
        layer.borderWidth = 1
        layer.borderColor = UIColor.separator.cgColor
        isMultipleTouchEnabled = true

        hintLabel.text = "Trackpad\n1 finger move · tap click · 2 fingers scroll\n2-finger tap right-click · hold+move drag · pinch zoom"
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

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.minimumNumberOfTouches = 1
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        addGestureRecognizer(pan)

        let twoFingerPan = UIPanGestureRecognizer(target: self, action: #selector(handleTwoFingerPan(_:)))
        twoFingerPan.minimumNumberOfTouches = 2
        twoFingerPan.maximumNumberOfTouches = 2
        twoFingerPan.delegate = self
        addGestureRecognizer(twoFingerPan)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.numberOfTouchesRequired = 1
        addGestureRecognizer(tap)

        let twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(handleTwoFingerTap(_:)))
        twoFingerTap.numberOfTouchesRequired = 2
        addGestureRecognizer(twoFingerTap)

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.35
        longPress.delegate = self
        addGestureRecognizer(longPress)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.delegate = self
        addGestureRecognizer(pinch)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        return true
    }

    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        switch g.state {
        case .began:
            lastPan = .zero
        case .changed:
            guard !dragging else { return }
            let t = g.translation(in: self)
            pointer?.move(dx: t.x - lastPan.x, dy: t.y - lastPan.y, gain: PointerController.Settings.touchpadGain)
            lastPan = t
        default:
            break
        }
    }

    @objc private func handleTwoFingerPan(_ g: UIPanGestureRecognizer) {
        switch g.state {
        case .began:
            lastTwoFingerPan = .zero
        case .changed:
            let t = g.translation(in: self)
            let dx = (t.x - lastTwoFingerPan.x) * PointerController.Settings.touchScrollGain
            let dy = (t.y - lastTwoFingerPan.y) * PointerController.Settings.touchScrollGain
            lastTwoFingerPan = t
            // Finger moves up (negative dy) reveals content below: scrollBy positive.
            pointer?.scroll(dx: -dx, dy: -dy)
        default:
            break
        }
    }

    @objc private func handleTap(_ g: UITapGestureRecognizer) {
        guard g.state == .ended else { return }
        let now = Date().timeIntervalSinceReferenceDate
        tapCount = (now - lastTapTime < 0.35) ? tapCount + 1 : 1
        lastTapTime = now
        pointer?.tap(.left, clickCount: tapCount)
    }

    @objc private func handleTwoFingerTap(_ g: UITapGestureRecognizer) {
        guard g.state == .ended else { return }
        pointer?.tap(.right, clickCount: 1)
    }

    @objc private func handleLongPress(_ g: UILongPressGestureRecognizer) {
        switch g.state {
        case .began:
            dragging = true
            dragLast = g.location(in: self)
            haptic.impactOccurred()
            pointer?.button(.left, pressed: true)
        case .changed:
            let p = g.location(in: self)
            pointer?.move(dx: p.x - dragLast.x, dy: p.y - dragLast.y, gain: PointerController.Settings.touchpadGain)
            dragLast = p
        case .ended, .cancelled, .failed:
            if dragging {
                dragging = false
                pointer?.button(.left, pressed: false)
            }
        default:
            break
        }
    }

    @objc private func handlePinch(_ g: UIPinchGestureRecognizer) {
        guard g.state == .changed else { return }
        if g.scale > 1.25 {
            onZoom?(0.1)
            g.scale = 1
        } else if g.scale < 0.8 {
            onZoom?(-0.1)
            g.scale = 1
        }
    }
}
