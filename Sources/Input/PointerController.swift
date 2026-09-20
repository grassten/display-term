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
        /// Fallback gain when the phone screen size is unknown.
        static var mouseGain: CGFloat = 1.6
        /// Scale the phone screen onto the display instead of treating deltas as free
        /// relative motion. On iPhone the only pointer system is AssistiveTouch, whose
        /// cursor is confined to the phone's own screen, and GCMouse deltas are that
        /// cursor's movement: once it pins against the phone's edge the deltas drop to
        /// zero while our cursor still has most of the display left. Proportional gain
        /// makes both cursors reach their edges together, and every edge hit re-syncs them.
        static var mapPhoneScreenToDisplay = true
        /// Kept a little above exact. If ours clamps first nothing is lost; if the phone's
        /// clamps first the rest of the display is unreachable.
        static var mouseGainHeadroom: CGFloat = 1.15
        static var touchpadGain: CGFloat = 2.5
        static var accelerationCap: CGFloat = 2.5
        static var mouseDeltaYIsUp = true
        static var naturalScrolling = true
        static var scrollUnitPoints: CGFloat = 40
        static var touchScrollGain: CGFloat = 2.0
        static var idleHideSeconds: TimeInterval = 4
    }

    weak var surface: PointerSurface? {
        didSet {
            if let bounds = surface?.pointerBounds { position = CGPoint(x: bounds.midX, y: bounds.midY) }
        }
    }

    /// The phone screen in points; the AssistiveTouch cursor cannot leave it.
    var phoneScreenSize: CGSize = .zero

    /// Gain that maps the phone screen onto the display (see Settings).
    var mouseGain: CGFloat {
        guard Settings.mapPhoneScreenToDisplay, phoneScreenSize.width > 0, phoneScreenSize.height > 0,
              let b = surface?.pointerBounds else { return Settings.mouseGain }
        return max(b.width / phoneScreenSize.width, b.height / phoneScreenSize.height) * Settings.mouseGainHeadroom
    }

    private(set) var position: CGPoint = .zero
    private(set) var isVisible = false
    var modifiers: UIKeyModifierFlags = []

    private var hideTimer: Timer?
    private var buttonsDown: Set<Button> = []
    private var lastClickTime: TimeInterval = 0
    private var lastClickPoint: CGPoint = .zero
    private var lastClickButton: Button = .left
    private var clickCount = 0

    var buttonsMask: Int {
        (buttonsDown.contains(.left) ? 1 : 0) | (buttonsDown.contains(.right) ? 2 : 0) | (buttonsDown.contains(.middle) ? 4 : 0)
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

    func button(_ button: Button, pressed: Bool) {
        guard let surface else { return }
        show()
        if pressed {
            let now = Date().timeIntervalSinceReferenceDate
            let near = hypot(position.x - lastClickPoint.x, position.y - lastClickPoint.y) < 6
            if button == lastClickButton, now - lastClickTime < 0.4, near {
                clickCount += 1
            } else {
                clickCount = 1
            }
            lastClickTime = now
            lastClickPoint = position
            lastClickButton = button
            buttonsDown.insert(button)
        } else {
            buttonsDown.remove(button)
        }
        surface.pointerButton(button, pressed: pressed, at: position, clickCount: max(clickCount, 1), modifiers: modifiers)
    }

    /// A complete press+release with an explicit click count (used by touchpad taps).
    func tap(_ button: Button, clickCount count: Int) {
        guard let surface else { return }
        show()
        clickCount = count
        lastClickTime = Date().timeIntervalSinceReferenceDate
        lastClickPoint = position
        lastClickButton = button
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
