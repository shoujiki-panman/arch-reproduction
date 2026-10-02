/*
See LICENSE folder for this sample's licensing information.

Abstract:
閉じていても、大きく動いたら起こしてもらい、友だちに位置を1回だけ送る。
*/

import Foundation
import CoreLocation
import UIKit

/// 10/3 本人「アプリ開いてもなくてもやってほしい。ゼンリー見習いなよ」「電池かなりへる？工夫してよ」。
///
/// ZenlyやLife360と同じく、iOSの「大きな移動の見張り」（significant-change）を使う。
/// GPSではなく基地局とWi-Fiで見張るので電気をほとんど使わず、数百m動くとiOSがアプリを起こす。
/// Appleの説明では、閉じたアプリを自動で起こし直せるのは、この見張りと場所の出入りの見張りだけ。
/// ただし、上にはじいて閉じたあとも起きるかは開発者の報告が割れている（実機で確かめる）。
///
/// 決めごと:
///  - 動くのは、覚えた友だちとつないでいて、位置の許可が「常に」のときだけ
///  - 起きたら、保存してある部屋を読み、暗号化した位置を1回流して、すぐ切る
///  - 画面のある側（ViewController）が同じ部屋に送っていても気にしない（重なっても害はない）
final class BackgroundRelay: NSObject, CLLocationManagerDelegate {
    static let shared = BackgroundRelay()

    private let manager = CLLocationManager()
    private var channel: RemoteChannel?
    private var task: UIBackgroundTaskIdentifier = .invalid
    private(set) var watching = false

    /// 大きく動いて起きた（画面のある側が、相手との距離を見直すため）。
    static let didWake = Notification.Name("kokodayo.backgroundRelay.didWake")

    private override init() {
        super.init()
        // 起こされたあとの知らせは、起動の早いうちに受け手を決めておかないと届かない。
        manager.delegate = self
    }

    /// 起動のたびと、つないだ・やめたときに呼ぶ。見張るかどうかを今の状態から決め直す。
    func refresh() {
        let should = Self.roomID() != nil
            && manager.authorizationStatus == .authorizedAlways
            && NearbyAlert.runsInBackground
            && CLLocationManager.significantLocationChangeMonitoringAvailable()
        if should, !watching {
            manager.startMonitoringSignificantLocationChanges()
            watching = true
        } else if !should, watching {
            manager.stopMonitoringSignificantLocationChanges()
            watching = false
        }
    }

    /// 友だちとつないだら、位置の許可を「常に」にしてもらう（iOSが一度だけ聞く）。
    func askForAlways() {
        guard manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .notDetermined
        else { return }
        manager.requestAlwaysAuthorization()
    }

    /// 保存してある部屋が、覚えた友だちとの部屋で、まだ続いているなら、その ID。
    static func roomID() -> String? {
        guard let group = MeetViewController.savedGroup(), group.expires > Date(),
              MeetViewController.isFriendRoom(id: group.id) else { return nil }
        return group.id
    }

    // MARK: - CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        refresh()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        NotificationCenter.default.post(name: Self.didWake, object: location)
        // 開いているあいだは、画面のある側がいつもどおり送っている。
        guard UIApplication.shared.applicationState != .active else { return }
        send(location)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}

    // MARK: - 1回だけ送る

    private func send(_ location: CLLocation) {
        guard let id = Self.roomID() else { refresh(); return }
        channel?.disconnect()
        let app = UIApplication.shared
        if task == .invalid {
            task = app.beginBackgroundTask(withName: "kokodayo.relay") { [weak self] in self?.finish() }
        }
        let channel = RemoteChannel(groupID: id)
        channel.onState = { [weak self, weak channel] joined in
            guard joined, let channel else { return }
            DispatchQueue.main.async {
                channel.send(location)
                // 送ったものが出ていくのを少し待ってから切る。
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self?.finish() }
            }
        }
        self.channel = channel
        channel.connect()
        // つながらなくても、20秒で諦める（iOSにもらった時間を使い切らない）。
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.finish() }
    }

    private func finish() {
        channel?.disconnect()
        channel = nil
        if task != .invalid {
            UIApplication.shared.endBackgroundTask(task)
            task = .invalid
        }
    }
}
