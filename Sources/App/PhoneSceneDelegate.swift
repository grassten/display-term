import UIKit

/// The scene on the iPhone itself: controller UI, and the place all keyboard input arrives.
final class PhoneSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = PhoneViewController()
        self.window = window
        window.makeKeyAndVisible()
    }
}
