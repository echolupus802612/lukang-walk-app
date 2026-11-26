import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var walk: WalkViewController? { window?.rootViewController as? WalkViewController }

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        WalkTheme.apply(to: window)
        window.rootViewController = WalkViewController()
        self.window = window
        window.makeKeyAndVisible()
    }

    func sceneDidBecomeActive(_ scene: UIScene) { walk?.setForeground(true) }
    func sceneDidEnterBackground(_ scene: UIScene) { walk?.setForeground(false) }
    func sceneDidDisconnect(_ scene: UIScene) { walk?.setForeground(false) }
}
