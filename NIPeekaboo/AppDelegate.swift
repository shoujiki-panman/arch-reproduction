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
        return true
    }

    func application(_ application: UIApplication, configurationForConnecting
                     connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        return UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }

    /// 知らせのボタンが押された。ここではまだ画面が無いこともあるので、印だけ置いて渡す。
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.actionIdentifier == NearbyAlert.pingAction {
            NearbyAlert.pendingPing = true
            NotificationCenter.default.post(name: .kokodayoPingRequested, object: nil)
        }
        completionHandler()
    }
}
