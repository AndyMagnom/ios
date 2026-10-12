import UIKit

// Scene lifecycle owns foreground privacy and the window being captured.
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        window.backgroundColor = Theme.background
        window.rootViewController = BrowserController()
        window.makeKeyAndVisible()
        self.window = window
    }
    func sceneDidBecomeActive(_ scene: UIScene) {
        guard let browser = window?.rootViewController as? BrowserController else { return }
        browser.loadViewIfNeeded()
        browser.activate()
    }
    func sceneWillResignActive(_ scene: UIScene) { (window?.rootViewController as? BrowserController)?.resign() }
    func sceneDidDisconnect(_ scene: UIScene) { (window?.rootViewController as? BrowserController)?.resign() }
}
