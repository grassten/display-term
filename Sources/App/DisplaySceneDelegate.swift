import UIKit

/// The scene on the external display. iOS delivers no input here; it is render-only.
final class DisplaySceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let screen = windowScene.screen
        selectBestMode(on: screen)
        screen.overscanCompensation = .none

        let window = UIWindow(windowScene: windowScene)
        window.backgroundColor = .black
        window.rootViewController = DesktopViewController()
        self.window = window

        BrowserModel.shared.displayDidConnect(screen: screen)
        window.isHidden = false
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        BrowserModel.shared.displayDidDisconnect()
        window = nil
    }

    func windowScene(_ windowScene: UIWindowScene,
                     didUpdate previousCoordinateSpace: UICoordinateSpace,
                     interfaceOrientation previousInterfaceOrientation: UIInterfaceOrientation,
                     traitCollection previousTraitCollection: UITraitCollection) {
        BrowserModel.shared.displayDidConnect(screen: windowScene.screen)
    }

    /// Pick the mode with the most pixels. This is also what removes the letterboxing:
    /// our window fills the chosen mode instead of mirroring the phone's shape.
    private func selectBestMode(on screen: UIScreen) {
        let modes = screen.availableModes
        guard let best = modes.max(by: { $0.size.width * $0.size.height < $1.size.width * $1.size.height }) else { return }
        if screen.currentMode != best {
            screen.currentMode = best
        }
        let list = modes.map { "\(Int($0.size.width))x\(Int($0.size.height))" }.joined(separator: ", ")
        NSLog("[Display] modes: [\(list)] using \(Int(best.size.width))x\(Int(best.size.height)) scale=\(screen.scale) bounds=\(screen.bounds)")
    }
}
