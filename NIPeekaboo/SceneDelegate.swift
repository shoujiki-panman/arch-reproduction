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
        // 端末のライト／ダークに合わせる（以前は暗い色で固定していた）。
        self.window = window
        window.makeKeyAndVisible()

        // Launched by tapping the waiting side's link in a messenger.
        if let url = connectionOptions.urlContexts.first?.url { open(url) }
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        if let url = URLContexts.first?.url { open(url) }
    }

    /// 買い物の通知から開いたとき、画面が前に出てから「済んだ？」を聞く。
    func sceneDidBecomeActive(_ scene: UIScene) {
        AppDelegate.askPendingErrandIfReady()
    }

    private func open(_ url: URL) {
        if url.scheme == "kokodayo", url.host == "push-token" {
            let alert = UIAlertController(title: PushKnock.copyMyToken(), message: nil, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            window?.rootViewController?.present(alert, animated: true)
            return
        }
        #if DEBUG
        print("INVITE scene got \(url) root=\(String(describing: window?.rootViewController))")
        #endif
        (window?.rootViewController as? MeetViewController)?.handleInvite(url)
    }
}
