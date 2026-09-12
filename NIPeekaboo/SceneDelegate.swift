/*
 Arch reproduction — boots ArchViewController programmatically (no storyboard).
*/

import UIKit

class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = MeetViewController()
        window.overrideUserInterfaceStyle = .dark
        self.window = window
        window.makeKeyAndVisible()

        // Launched by tapping the waiting side's link in a messenger.
        if let url = connectionOptions.urlContexts.first?.url { open(url) }
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        if let url = URLContexts.first?.url { open(url) }
    }

    private func open(_ url: URL) {
        #if DEBUG
        print("INVITE scene got \(url) root=\(String(describing: window?.rootViewController))")
        #endif
        (window?.rootViewController as? MeetViewController)?.handleInvite(url)
    }
}
