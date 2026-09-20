import GameController
import UIKit

/// Feeds GCMouse devices (a wired Magic Trackpad, or any Bluetooth mouse the phone pairs
/// with) into the PointerController. Only the foreground app receives these events.
final class MouseInput {
    private weak var pointer: PointerController?
    private var observers: [NSObjectProtocol] = []
    private(set) var connectedCount = 0
    private var moveEvents = 0
    var onConnectionChange: ((Int) -> Void)?

    init(pointer: PointerController) {
        self.pointer = pointer
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .GCMouseDidConnect, object: nil, queue: .main) { [weak self] note in
            if let mouse = note.object as? GCMouse { self?.attach(mouse) }
        })
        observers.append(center.addObserver(forName: .GCMouseDidDisconnect, object: nil, queue: .main) { [weak self] note in
            guard let self else { return }
            self.connectedCount = GCMouse.mice().count
            NSLog("[Mouse] DISCONNECTED: \((note.object as? GCMouse)?.vendorName ?? "unknown") remaining=\(self.connectedCount)")
            self.onConnectionChange?(self.connectedCount)
        })
        for mouse in GCMouse.mice() { attach(mouse) }
    }

    deinit {
        for o in observers { NotificationCenter.default.removeObserver(o) }
    }

    /// Re-arm every attached device. Returning from the background can leave a device
    /// enumerated but with its handlers dropped, which looks exactly like a dead trackpad.
    func reattachAll() {
        for mouse in GCMouse.mice() { attach(mouse) }
        connectedCount = GCMouse.mice().count
        onConnectionChange?(connectedCount)
    }

    private func attach(_ mouse: GCMouse) {
        guard let input = mouse.mouseInput else { return }
        input.mouseMovedHandler = { [weak self] _, deltaX, deltaY in
            guard let self else { return }
            self.moveEvents += 1
            if self.moveEvents <= 5 || self.moveEvents % 100 == 0 {
                NSLog("[Mouse] delta #\(self.moveEvents) dx=\(deltaX) dy=\(deltaY)")
            }
            let dy = PointerController.Settings.mouseDeltaYIsUp ? -CGFloat(deltaY) : CGFloat(deltaY)
            guard let pointer = self.pointer else { return }
            pointer.move(dx: CGFloat(deltaX), dy: dy, gain: pointer.mouseGain, accelerate: false)
        }
        input.leftButton.pressedChangedHandler = { [weak self] _, _, pressed in
            self?.pointer?.button(.left, pressed: pressed)
        }
        input.rightButton?.pressedChangedHandler = { [weak self] _, _, pressed in
            self?.pointer?.button(.right, pressed: pressed)
        }
        input.middleButton?.pressedChangedHandler = { [weak self] _, _, pressed in
            self?.pointer?.button(.middle, pressed: pressed)
        }
        input.scroll.valueChangedHandler = { [weak self] _, x, y in
            let sign: CGFloat = PointerController.Settings.naturalScrolling ? 1 : -1
            let unit = PointerController.Settings.scrollUnitPoints
            self?.pointer?.scroll(dx: -CGFloat(x) * unit * sign, dy: -CGFloat(y) * unit * sign)
        }
        connectedCount = GCMouse.mice().count
        onConnectionChange?(connectedCount)
        NSLog("[Mouse] attached: \(mouse.vendorName ?? "unknown") total=\(connectedCount)")
    }
}
