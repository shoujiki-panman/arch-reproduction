/*
See LICENSE folder for this sample's licensing information.

Abstract:
今日歩いた歩数と距離。iPhone の歩数計（CMPedometer）の数をそのまま出す。
*/

import Foundation
import CoreMotion
import UIKit

/// 10/12 本人「歩数とかで距離とかわかるといいかも」（今日歩いた分を出す）。
///
/// 歩数と距離は iPhone の歩数計が出したものをそのまま使う（こちらで歩幅を掛けて計算しない）。
/// 距離は iPhone が持っていないことがあり、そのときは歩数だけを出す。
/// 開いているあいだだけ数え、閉じたら止める（電池）。日付が変わっていたら、開いたときに今日から数え直す。
final class TodayWalk {
    private let pedometer = CMPedometer()
    private var running = false
    /// 新しい数が届いた（主スレッドで呼ぶ）。nil は「出さない」。
    var onChange: ((String?) -> Void)?

    init() {
        NotificationCenter.default.addObserver(self, selector: #selector(start),
                                               name: UIApplication.willEnterForegroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(stop),
                                               name: UIApplication.didEnterBackgroundNotification, object: nil)
    }

    @objc func start() {
        guard CMPedometer.isStepCountingAvailable(),
              CMPedometer.authorizationStatus() != .denied,
              CMPedometer.authorizationStatus() != .restricted else {
            onChange?(nil)
            return
        }
        stop()
        running = true
        let today = Calendar.current.startOfDay(for: Date())
        // 開いた時点までの分をすぐ出し、その先は歩くたびに届く分で書き換える。
        pedometer.queryPedometerData(from: today, to: Date()) { [weak self] data, _ in
            self?.deliver(data)
        }
        pedometer.startUpdates(from: today) { [weak self] data, _ in
            self?.deliver(data)
        }
    }

    @objc func stop() {
        guard running else { return }
        pedometer.stopUpdates()
        running = false
    }

    private func deliver(_ data: CMPedometerData?) {
        guard let data else { return }
        let line = Self.text(steps: data.numberOfSteps.intValue, metres: data.distance?.doubleValue)
        DispatchQueue.main.async { [weak self] in self?.onChange?(line) }
    }

    /// 「今日 7,938歩・5.6km」。まだ歩いていなければ nil（0歩の行は出さない）。
    static func text(steps: Int, metres: Double?) -> String? {
        guard steps > 0 else { return nil }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "ja_JP")
        let count = formatter.string(from: NSNumber(value: steps)) ?? "\(steps)"
        guard let metres, metres > 0 else { return "今日 \(count)歩" }
        return "今日 \(count)歩・\(NearbyAlert.text(metres))"
    }
}
