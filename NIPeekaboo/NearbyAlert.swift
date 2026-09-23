// 「近くにいるよ」の知らせ。
//
// 合流の失敗はたいてい「相手がもう近くにいることに気づかない」ことから始まる。
// 画面を見ていなくても、近づいた一度だけ鳴らす。何度も鳴ると人は音を切る。
//
// 決めごと:
//  - 鳴るのは1回の接近につき1回だけ。離れて戻ってきたらまた鳴る
//  - 距離は本人が決める（既定は3km）。街の広さで「近い」は変わる
//  - 画面を閉じているあいだも知らせるかは本人が決める（位置を背景で使うため）
import Foundation
import UIKit
import UserNotifications

enum NearbyAlert {

    // MARK: - 設定（本人が決めるもの）

    private static let onKey = "kokodayo.near.on"
    private static let metresKey = "kokodayo.near.metres"
    private static let backgroundKey = "kokodayo.near.background"

    /// 選べる距離。3つだけ。細かい数字を選ばせる機能ではない。
    static let choices: [Double] = [300, 1000, 3000]

    static var isOn: Bool {
        get { UserDefaults.standard.object(forKey: onKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: onKey) }
    }

    static var metres: Double {
        get {
            let saved = UserDefaults.standard.double(forKey: metresKey)
            return saved > 0 ? saved : 3000
        }
        set { UserDefaults.standard.set(newValue, forKey: metresKey) }
    }

    /// 画面を閉じているあいだも位置を受け取るか。切ると、アプリを開いている
    /// あいだだけの知らせになる。
    static var runsInBackground: Bool {
        get { UserDefaults.standard.object(forKey: backgroundKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: backgroundKey) }
    }

    // MARK: - 言い方

    static func text(_ metres: Double) -> String {
        guard metres >= 1000 else { return "\(Int(metres.rounded()))m" }
        let km = String(format: "%.1f", metres / 1000)
        return (km.hasSuffix(".0") ? String(km.dropLast(2)) : km) + "km"
    }

    /// 歩いた見込み。分速80mは地図の画面と同じ値にそろえる。
    static func walkText(_ metres: Double) -> String {
        "歩いて約\(max(1, Int((metres / 80).rounded())))分"
    }

    // MARK: - 通知

    /// 許可を聞く。グループができた時に一度だけ呼ぶ（起動直後に聞かない）。
    static func ask() {
        guard isOn else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// 知らせを出す。アプリを見ているあいだは画面の文字と振動で足りるので出さない。
    static func notify(title: String, body: String) {
        guard UIApplication.shared.applicationState != .active else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

/// 近づいたかどうかの見張り。
///
/// 決めた距離をまたいだ瞬間に1回だけ「はい」と答える。境目で行ったり来たりしても
/// 鳴り続けないよう、いったん3割ぶん離れるまで次は鳴らない。
struct ApproachWatcher {
    /// 遠くから来たことが分かっている状態。起動時に既に近い場合は鳴らさないので false から始める。
    private var armed = false
    private var lastFire: Date?

    mutating func step(metres: Double, threshold: Double) -> Bool {
        if metres > threshold * 1.3 {
            armed = true
            return false
        }
        guard armed, metres <= threshold else { return false }
        // 同じ接近で二度鳴らさない。
        if let lastFire, Date().timeIntervalSince(lastFire) < 60 { return false }
        armed = false
        lastFire = Date()
        return true
    }

    /// 相手が変わった・グループが終わったときに忘れる。
    mutating func reset() {
        armed = false
        lastFire = nil
    }
}
