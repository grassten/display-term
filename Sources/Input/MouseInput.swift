import GameController
import UIKit

/// Feeds GCMouse devices (a wired Magic Trackpad, or any Bluetooth mouse the phone pairs
/// with) into the PointerController. Only the foreground app receives these events.
///
/// On iPhone the whole character of this input depends on AssistiveTouch. With it on, iOS
/// drives its own cursor with the device and keeps that cursor inside the phone's screen,
/// so what arrives here is the cursor's movement and it stops dead at the phone's edges.
/// With it off there is no system cursor to stop anywhere, and these deltas should be the
/// device's own: unbounded, so one swipe can cross the whole display. `diagnostics`
/// reports which of the two we are in and whether anything is arriving at all, because
/// from the outside a silent device and a dead app look identical.
final class MouseInput {
    private weak var pointer: PointerController?
    private var observers: [NSObjectProtocol] = []
    private(set) var connectedCount = 0
    var onConnectionChange: ((Int) -> Void)?
    /// Fired at most a few times a second so the phone's status line can show activity.
    var onActivity: (() -> Void)?

    private var deviceNames: [String] = []
    private var moveEvents = 0
    private var scrollEvents = 0
    private var buttonEvents = 0
    private var maxDelta: CGFloat = 0
    private var lastMoveTime: TimeInterval = 0
    private var lastActivityReport: TimeInterval = 0

    init(pointer: PointerController) {
        self.pointer = pointer
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .GCMouseDidConnect, object: nil, queue: .main) { [weak self] note in
            if let mouse = note.object as? GCMouse { self?.attach(mouse) }
        })
        // Connect is not the event that matters: a device can be enumerated and still not
        // be the one iOS is feeding. UTM, which ships this on iPhone, hangs everything off
        // "did become current", so we attach on both.
        observers.append(center.addObserver(forName: .GCMouseDidBecomeCurrent, object: nil, queue: .main) { [weak self] note in
            NSLog("[Mouse] became current: \((note.object as? GCMouse)?.vendorName ?? "unknown")")
            if let mouse = note.object as? GCMouse { self?.attach(mouse) }
        })
        observers.append(center.addObserver(forName: .GCMouseDidStopBeingCurrent, object: nil, queue: .main) { note in
            NSLog("[Mouse] stopped being current: \((note.object as? GCMouse)?.vendorName ?? "unknown")")
        })
        observers.append(center.addObserver(forName: .GCMouseDidDisconnect, object: nil, queue: .main) { [weak self] note in
            guard let self else { return }
            self.refreshDevices()
            NSLog("[Mouse] DISCONNECTED: \((note.object as? GCMouse)?.vendorName ?? "unknown") remaining=\(self.connectedCount)")
            self.onConnectionChange?(self.connectedCount)
        })
        for mouse in GCMouse.mice() { attach(mouse) }
        if let current = GCMouse.current { attach(current) }
        NSLog("[Mouse] init: mice=\(GCMouse.mice().count) current=\(GCMouse.current?.vendorName ?? "none") assistiveTouch=\(UIAccessibility.isAssistiveTouchRunning)")
    }

    deinit {
        for o in observers { NotificationCenter.default.removeObserver(o) }
    }

    /// One line for the phone's status area: what is attached, which pointer regime we are
    /// in, and whether events are actually flowing. "connected, silent" is the interesting
    /// failure: the device enumerated but iOS is routing its input somewhere else.
    var diagnostics: String {
        guard PointerController.Settings.externalPointingDevices else { return "trackpad off" }
        let assistive = pointer?.assistiveTouchRunning ?? false
        guard connectedCount > 0 else {
            return assistive ? "no trackpad · AssistiveTouch on" : "no trackpad"
        }
        let name = deviceNames.first ?? "pointing device"
        let regime = assistive ? "AssistiveTouch on (mapped)" : "raw"
        // Clicks are counted separately from movement on purpose. A trackpad that reports
        // its buttons but never its motion is a different animal from one iOS withholds
        // entirely: the first means only the pointer layer is missing, the second means
        // the device is not ours at all.
        guard moveEvents > 0 else {
            return "\(name) · \(regime) · no motion · \(buttonEvents) clicks, \(scrollEvents) scrolls"
        }
        return "\(name) · \(regime) · \(moveEvents) moves, max \(Int(maxDelta)) · \(buttonEvents) clicks, \(scrollEvents) scrolls"
    }

    /// Re-arm every attached device. Returning from the background can leave a device
    /// enumerated but with its handlers dropped, which looks exactly like a dead trackpad.
    func reattachAll() {
        for mouse in GCMouse.mice() { attach(mouse) }
        refreshDevices()
        onConnectionChange?(connectedCount)
    }

    private func refreshDevices() {
        let mice = GCMouse.mice()
        connectedCount = mice.count
        deviceNames = mice.map { $0.vendorName ?? "unknown" }
    }

    private func attach(_ mouse: GCMouse) {
        guard let input = mouse.mouseInput else { return }
        input.mouseMovedHandler = { [weak self] _, deltaX, deltaY in
            guard let self, let pointer = self.pointer else { return }
            let now = CACurrentMediaTime()
            let dt = self.lastMoveTime > 0 ? now - self.lastMoveTime : 1.0 / 120.0
            self.lastMoveTime = now
            self.moveEvents += 1
            self.maxDelta = max(self.maxDelta, max(abs(CGFloat(deltaX)), abs(CGFloat(deltaY))))
            if self.moveEvents <= 5 || self.moveEvents % 200 == 0 {
                NSLog("[Mouse] delta #\(self.moveEvents) dx=\(deltaX) dy=\(deltaY) max=\(Int(self.maxDelta)) assistiveTouch=\(pointer.assistiveTouchRunning)")
            }
            let dy = PointerController.Settings.mouseDeltaYIsUp ? -CGFloat(deltaY) : CGFloat(deltaY)
            pointer.moveFromMouse(dx: CGFloat(deltaX), dy: dy, dt: dt)
            self.reportActivity(now)
        }
        input.leftButton.pressedChangedHandler = { [weak self] _, _, pressed in
            self?.button(.left, pressed: pressed)
        }
        input.rightButton?.pressedChangedHandler = { [weak self] _, _, pressed in
            self?.button(.right, pressed: pressed)
        }
        input.middleButton?.pressedChangedHandler = { [weak self] _, _, pressed in
            self?.button(.middle, pressed: pressed)
        }
        input.scroll.valueChangedHandler = { [weak self] _, x, y in
            guard let self else { return }
            self.scrollEvents += 1
            if self.scrollEvents <= 5 || self.scrollEvents % 100 == 0 {
                NSLog("[Mouse] scroll #\(self.scrollEvents) x=\(x) y=\(y)")
            }
            let sign: CGFloat = PointerController.Settings.naturalScrolling ? 1 : -1
            let unit = PointerController.Settings.scrollUnitPoints
            self.pointer?.scroll(dx: -CGFloat(x) * unit * sign, dy: -CGFloat(y) * unit * sign)
            self.reportActivity(CACurrentMediaTime())
        }
        refreshDevices()
        onConnectionChange?(connectedCount)
        NSLog("[Mouse] attached: \(mouse.vendorName ?? "unknown") total=\(connectedCount) buttons=left\(input.rightButton != nil ? "+right" : "")\(input.middleButton != nil ? "+middle" : "") assistiveTouch=\(UIAccessibility.isAssistiveTouchRunning)")
    }

    private func button(_ button: PointerController.Button, pressed: Bool) {
        buttonEvents += 1
        if buttonEvents <= 20 {
            NSLog("[Mouse] button \(button) pressed=\(pressed)")
        }
        pointer?.button(button, pressed: pressed)
        reportActivity(CACurrentMediaTime())
    }

    private func reportActivity(_ now: TimeInterval) {
        guard now - lastActivityReport > 0.25 else { return }
        lastActivityReport = now
        onActivity?()
    }
}
