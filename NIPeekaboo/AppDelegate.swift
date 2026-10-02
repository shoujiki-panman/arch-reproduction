/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
A class that responds to application life cycle events.
*/

import UIKit
import UserNotifications

@main
class AppDelegate: UIResponder, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    func application(_ application: UIApplication, didFinishLaunchingWithOptions
                     launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // 知らせの「合図する」を受けるには、起動が終わる前に名乗っておく必要がある。
        UNUserNotificationCenter.current().delegate = self
        NearbyAlert.registerCategory()
        // 閉じていても届く呼び鈴のために、通知の宛先をもらう（許可のダイアログは近くの知らせと同じもの）。
        application.registerForRemoteNotifications()
        // 閉じていても大きく動いたら起こしてもらう見張り。起こされた起動でも、ここで受け手を決める。
        BackgroundRelay.shared.refresh()
        return true
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        PushKnock.save(token: deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {}

    func application(_ application: UIApplication, configurationForConnecting
                     connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        return UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }

    /// 画面を開いているあいだに届いた知らせ。これを書いていないと、iOSは
    /// 前面のアプリへの知らせを黙って捨てる。アプリを見ている本人には、
    /// 「近くにいます」が一度も鳴らないことになっていた。
    /// 中身は画面の下に自前の一言が出るので、ここでは音だけ鳴らす。
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler:
                                    @escaping (UNNotificationPresentationOptions) -> Void) {
        // 家のアレクサからの買い物は、アプリを見ていても上に出す（画面の中には出る場所が無いため）。
        if notification.request.content.userInfo["errand"] != nil {
            completionHandler([.banner, .list, .sound])
            return
        }
        completionHandler([.sound])
    }

    /// 知らせのボタンが押された。ここではまだ画面が無いこともあるので、印だけ置いて渡す。
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.actionIdentifier == NearbyAlert.pingAction {
            NearbyAlert.pendingPing = true
            NotificationCenter.default.post(name: .kokodayoPingRequested, object: nil)
        }
        // 家のアレクサからの買い物。「済んだ」はアプリを開かずに返す。通知そのものを押したら、開いてから聞く。
        let info = response.notification.request.content.userInfo
        if let id = info["errandId"] as? String, let item = info["errand"] as? String {
            if response.actionIdentifier == PushKnock.errandDoneAction {
                Task {
                    await PushKnock.reportErrandDone(id: id)
                    completionHandler()
                }
                return
            }
            if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { Self.askErrandDone(id: id, item: item) }
            }
        }
        // 呼び鈴（友だちが「つなぐ」を押した）の通知から開いた。画面ができてから渡す。
        if let key = response.notification.request.content.userInfo["knock"] as? String {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                NotificationCenter.default.post(name: .kokodayoKnock, object: key)
            }
        }
        completionHandler()
    }

    /// 買い物の通知から開いたときに、買えたかを聞く（iOS 標準の確認の札）。
    private static func askErrandDone(id: String, item: String) {
        let scene = UIApplication.shared.connectedScenes.first { $0.activationState == .foregroundActive } as? UIWindowScene
        guard let root = scene?.keyWindow?.rootViewController else { return }
        let top = root.presentedViewController ?? root
        let alert = UIAlertController(title: "🛒 \(item)", message: "買えたら「済んだ」を押してください。頼んだ人に伝わります。", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "あとで", style: .cancel))
        alert.addAction(UIAlertAction(title: "済んだ", style: .default) { _ in
            Task { await PushKnock.reportErrandDone(id: id) }
        })
        top.present(alert, animated: true)
    }
}
