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

    /// The most pixels the phone can actually drive. iPhone 15-class hardware outputs
    /// DisplayPort up to 4K UHD (PLAN.md section 1). The Studio Display also advertises
    /// 4096x2160 (DCI 4K) and 2560x2880; picking one of those by raw pixel count sets a
    /// mode the link does not run, UIKit keeps laying out to a different size, and only
    /// part of the window is ever visible on the panel.
    private static let maxOutput = CGSize(width: 3840, height: 2160)

    /// Pick the largest mode the phone can drive. This is also what removes the
    /// letterboxing: our window fills the chosen mode instead of mirroring the phone.
    private func selectBestMode(on screen: UIScreen) {
        let modes = screen.availableModes
        let drivable = modes.filter {
            $0.size.width <= Self.maxOutput.width && $0.size.height <= Self.maxOutput.height
        }
        let pool = drivable.isEmpty ? modes : drivable
        guard let best = pool.max(by: { $0.size.width * $0.size.height < $1.size.width * $1.size.height }) else { return }
        let before = screen.bounds
        if screen.currentMode != best {
            screen.currentMode = best
        }
        let list = modes.map { "\(Int($0.size.width))x\(Int($0.size.height))" }.joined(separator: ", ")
        NSLog("[Display] modes: [\(list)] using \(Int(best.size.width))x\(Int(best.size.height)) scale=\(screen.scale) boundsBefore=\(before) boundsAfter=\(screen.bounds)")
    }
}
