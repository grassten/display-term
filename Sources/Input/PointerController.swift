import UIKit

/// Something that can show a cursor and receive pointer events in its own coordinate space.
/// Implemented by DesktopViewController (the external display).
protocol PointerSurface: AnyObject {
    var pointerBounds: CGRect { get }
    func pointerMoved(to point: CGPoint, buttons: Int)
    func pointerButton(_ button: PointerController.Button, pressed: Bool, at point: CGPoint,
                       clickCount: Int, modifiers: UIKeyModifierFlags)
    func pointerScrolled(dx: CGFloat, dy: CGFloat, at point: CGPoint)
    func pointerVisibilityChanged(_ visible: Bool)
}

/// Owns the virtual cursor: position, click counting, idle hiding. Input sources
/// (GCMouse, the phone touchpad) feed deltas in; the surface renders and dispatches.
final class PointerController {
    enum Button: Int { case left = 0, middle = 1, right = 2 }

    /// Tunables. Flip the two booleans if the cursor or scrolling moves the wrong way.
    enum Settings {
        /// On. A wired Magic Trackpad is a real pointer again as long as AssistiveTouch is
        /// off: with no system cursor for iOS to drive, GCMouse deltas are the device's own
        /// and nothing confines them to the phone's screen. While AssistiveTouch is on we
        /// fall back to mapping the phone screen onto the display (see below), which is
        /// reachable but not pleasant. `assistiveTouchRunning` picks between the two live.
        static var externalPointingDevices = true
        /// Display points per unit of raw mouse delta, before acceleration.
        static var mouseGain: CGFloat = 1.6
        /// Speed-based acceleration for raw deltas, same shape as the touchpad's: the
        /// multiplier grows by one for every `mouseAccelerationSpeed` delta units per
        /// second, up to `1 + cap`. Unused on the AssistiveTouch-mapped path, where the
        /// system has already applied its own curve to its cursor.
        static var mouseAccelerationSpeed: CGFloat = 1200
        static var mouseAccelerationCap: CGFloat = 3.0
        /// Logs the pointer's whole state every two seconds. Off: it is how the question
        /// above was settled, not something to leave running.
        static var logDiagnostics = false
        /// The AssistiveTouch fallback: scale the phone screen onto the display instead of
        /// treating deltas as free relative motion. AssistiveTouch's cursor is confined to
        /// the phone's own screen and the deltas we get are its movement, so once it pins
        /// against the phone's edge they drop to zero while our cursor still has most of
        /// the display left. Proportional gain makes both cursors reach their edges
        /// together, and every edge hit re-syncs them. Ignored when AssistiveTouch is off.
        static var mapPhoneScreenToDisplay = true
        /// Kept a little above exact. If ours clamps first nothing is lost; if the phone's
        /// clamps first the rest of the display is unreachable.
        static var mouseGainHeadroom: CGFloat = 1.15
        /// Phone touchpad: display points per phone point for a slow, precise finger.
        static var touchpadGain: CGFloat = 3.0
        /// Speed-based acceleration for the touchpad: the multiplier grows by one for every
        /// `touchpadAccelerationSpeed` phone points per second, up to `1 + cap`. A slow drag
        /// stays precise; a flick crosses the 4K panel in one swipe.
        static var touchpadAccelerationSpeed: CGFloat = 400
        static var touchpadAccelerationCap: CGFloat = 3.0
        /// Legacy per-event acceleration for the mouse path (`move(accelerate: true)`).
        static var accelerationCap: CGFloat = 2.5
        static var mouseDeltaYIsUp = true
        static var naturalScrolling = true
        static var scrollUnitPoints: CGFloat = 40
        /// Display points scrolled per phone point of two-finger travel.
        static var touchScrollGain: CGFloat = 2.5
        static var idleHideSeconds: TimeInterval = 4
        /// Two presses count as a double-click when this close in time and space. The
        /// distance is in display points: a finger tapping twice on the phone lands a few
        /// phone points apart, which is 10-30 display points after gain.
        static var doubleClickInterval: TimeInterval = 0.4
        static var doubleClickDistance: CGFloat = 40
    }

    weak var surface: PointerSurface? {
        didSet {
            if let bounds = surface?.pointerBounds { position = CGPoint(x: bounds.midX, y: bounds.midY) }
        }
    }

    /// The phone screen in points; the AssistiveTouch cursor cannot leave it.
    var phoneScreenSize: CGSize = .zero

    /// AssistiveTouch decides which of two very different pointers we have, so the policy
    /// follows it live rather than being chosen once at launch. Off: raw device deltas.
    /// On: the movement of the system's own cursor, bounded by the phone's screen.
    private(set) var assistiveTouchRunning = UIAccessibility.isAssistiveTouchRunning
    /// Called on the main queue when that changes, so the UI can say which mode it is in.
    var onAssistiveTouchChange: ((Bool) -> Void)?

    /// True only while we are riding AssistiveTouch's cursor and can map it onto the display.
    var usesPhoneScreenMapping: Bool {
        assistiveTouchRunning && Settings.mapPhoneScreenToDisplay
            && phoneScreenSize.width > 0 && phoneScreenSize.height > 0
    }

    /// Gain that maps the phone screen onto the display (see Settings), or the plain gain
    /// for raw deltas when AssistiveTouch is off.
    var mouseGain: CGFloat {
        guard usesPhoneScreenMapping, let b = surface?.pointerBounds else { return Settings.mouseGain }
        return max(b.width / phoneScreenSize.width, b.height / phoneScreenSize.height) * Settings.mouseGainHeadroom
    }

    private(set) var position: CGPoint = .zero
    private(set) var isVisible = false
    var modifiers: UIKeyModifierFlags = []

    private var hideTimer: Timer?
    private var smoothedMouseSpeed: CGFloat = 0
    private var buttonsDown: Set<Button> = []
    private var lastClickTime: TimeInterval = 0
    private var lastClickPoint: CGPoint = .zero
    private var lastClickButton: Button = .left
    private var clickCount = 0

    var buttonsMask: Int {
        (buttonsDown.contains(.left) ? 1 : 0) | (buttonsDown.contains(.right) ? 2 : 0) | (buttonsDown.contains(.middle) ? 4 : 0)
    }

    var isDragging: Bool { buttonsDown.contains(.left) }

    init() {
        NotificationCenter.default.addObserver(
            forName: UIAccessibility.assistiveTouchStatusDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.assistiveTouchRunning = UIAccessibility.isAssistiveTouchRunning
            NSLog("[Pointer] AssistiveTouch \(self.assistiveTouchRunning ? "on" : "off"); mouse gain now \(self.mouseGain)")
            self.onAssistiveTouchChange?(self.assistiveTouchRunning)
        }
        NSLog("[Pointer] AssistiveTouch \(assistiveTouchRunning ? "on" : "off") at launch")
    }

    /// One mouse delta, routed by whichever pointer regime we are in. Raw deltas get the
    /// same velocity curve as the phone touchpad so a slow hand stays precise and a flick
    /// crosses the panel; mapped deltas get none, because the system already applied its
    /// own to the cursor that produced them and a second curve breaks the proportion.
    func moveFromMouse(dx: CGFloat, dy: CGFloat, dt: TimeInterval) {
        guard !usesPhoneScreenMapping else {
            move(dx: dx, dy: dy, gain: mouseGain, accelerate: false)
            return
        }
        let speed = hypot(dx, dy) / CGFloat(max(dt, 1.0 / 240.0))
        smoothedMouseSpeed = smoothedMouseSpeed * 0.6 + speed * 0.4
        let mult = 1 + min(smoothedMouseSpeed / Settings.mouseAccelerationSpeed, Settings.mouseAccelerationCap)
        move(dx: dx * mult, dy: dy * mult, gain: Settings.mouseGain, accelerate: false)
    }

    func move(dx: CGFloat, dy: CGFloat, gain: CGFloat, accelerate: Bool = true) {
        guard let surface else { return }
        let speed = hypot(dx, dy)
        // No extra acceleration on the mapped path: the system already applied its own to
        // the AssistiveTouch cursor, and adding more breaks the proportional sync.
        let acceleration = accelerate ? min(1 + speed / 10, Settings.accelerationCap) : 1
        var p = position
        p.x += dx * gain * acceleration
        p.y += dy * gain * acceleration
        let b = surface.pointerBounds
        p.x = min(max(p.x, b.minX), b.maxX - 1)
        p.y = min(max(p.y, b.minY), b.maxY - 1)
        position = p
        show()
        surface.pointerMoved(to: p, buttons: buttonsMask)
    }

    /// Time-and-distance click counting, shared by presses and taps: the second of two
    /// quick presses on different targets is a fresh single click, not a double-click.
    private func registerPress(_ button: Button) -> Int {
        let now = Date().timeIntervalSinceReferenceDate
        let near = hypot(position.x - lastClickPoint.x, position.y - lastClickPoint.y) < Settings.doubleClickDistance
        if button == lastClickButton, now - lastClickTime < Settings.doubleClickInterval, near {
            clickCount += 1
        } else {
            clickCount = 1
        }
        lastClickTime = now
        lastClickPoint = position
        lastClickButton = button
        return clickCount
    }

    func button(_ button: Button, pressed: Bool) {
        guard let surface else { return }
        show()
        if pressed {
            _ = registerPress(button)
            buttonsDown.insert(button)
        } else {
            buttonsDown.remove(button)
        }
        surface.pointerButton(button, pressed: pressed, at: position, clickCount: max(clickCount, 1), modifiers: modifiers)
    }

    /// A complete press+release at the current position (touchpad taps).
    func tap(_ button: Button) {
        guard let surface else { return }
        show()
        let count = registerPress(button)
        surface.pointerButton(button, pressed: true, at: position, clickCount: count, modifiers: modifiers)
        surface.pointerButton(button, pressed: false, at: position, clickCount: count, modifiers: modifiers)
    }

    func scroll(dx: CGFloat, dy: CGFloat) {
        guard let surface else { return }
        show()
        surface.pointerScrolled(dx: dx, dy: dy, at: position)
    }

    func show() {
        if !isVisible {
            isVisible = true
            surface?.pointerVisibilityChanged(true)
        }
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: Settings.idleHideSeconds, repeats: false) { [weak self] _ in
            self?.hide()
        }
    }

    func hide() {
        guard isVisible else { return }
        isVisible = false
        surface?.pointerVisibilityChanged(false)
    }
}
