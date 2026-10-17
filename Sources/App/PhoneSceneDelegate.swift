import UIKit

/// The scene on the iPhone itself: controller UI, and the place all keyboard input arrives.
final class PhoneSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = PhoneRootViewController()
        self.window = window
        window.makeKeyAndVisible()
    }

    /// Coming back to the foreground is when suspended SSH sessions get reconnected and an
    /// edited keymap.json is picked up.
    func sceneDidBecomeActive(_ scene: UIScene) {
        AppState.shared.phoneSceneBecameActive()
    }
}
