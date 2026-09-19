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
        static var mouseGain: CGFloat = 1.6
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

    func move(dx: CGFloat, dy: CGFloat, gain: CGFloat) {
        guard let surface else { return }
        let speed = hypot(dx, dy)
        let acceleration = min(1 + speed / 10, Settings.accelerationCap)
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
