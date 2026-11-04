/*
See LICENSE folder for this sample's licensing information.

Abstract:
近くの信号機（高度化PICS）が流している電波から、歩行者信号の色を読む。

読み方（バイトの位置と色の番号）は ble-pics-viewer の processPics（web/pics.mjs）を
そのまま Swift に移した。元のプログラムの著作権表示と許諾表示を、MIT ライセンスに従ってここに残す。

  ble-pics-viewer — https://github.com/yumu19/ble-pics-viewer (d97a278)
  MIT License

  Copyright (c) 2025 Tsubasa Yumura

  Permission is hereby granted, free of charge, to any person obtaining a copy
  of this software and associated documentation files (the "Software"), to deal
  in the Software without restriction, including without limitation the rights
  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
  copies of the Software, and to permit persons to whom the Software is
  furnished to do so, subject to the following conditions:

  The above copyright notice and this permission notice shall be included in all
  copies or substantial portions of the Software.

  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
  SOFTWARE.
*/

import Foundation
import CoreBluetooth

/// 11/3 本人「この機能いいな」（信号機の電波を読み、青になるまでを出す試み）→「入れる方向で進めて」。
///
/// 高度化PICS は、対応した交差点の信号機が歩行者信号の状態を BLE で周りに流す仕組み（公式アプリは「信GO!」）。
/// 公式の通信仕様は見つからなかったので、公開されている ble-pics-viewer の読み方に従う。
///
/// 決めごと（正直な表示）:
///  - 残りは秒ではない。信号機の待ち時間の目盛り（減っていく棒）と同じ段階の値で、目盛りが付いた信号
///    （ゆとりシグナル）でしか入っていない（デイリーポータルZ「信号の時刻表をつくる 2025」で筆者が実物と照合）。
///    入っていないときの値は分からないので、同じ信号の値が変わるのを一度見てから「残り目盛り」として出す。
///  - 1つの交差点に歩行者信号は最大6つあり、どれが自分の渡る方向かは分かっていない。並べて出し、断定しない。
///  - 「渡ってよい」とは言わない。自分の目で信号を見るのが先。
enum PICS {
    /// 電波のメーカー番号。iPhone では、メーカーデータの先頭2バイトに小さい順（CE 01）で付いて届く。
    static let companyID: UInt16 = 0x01CE

    enum SignalState: Equatable {
        case noSignal, red, blinkGreen, green, none, unknown

        /// 元のプログラムの SIGNAL_LABELS と同じ言葉。
        var label: String {
            switch self {
            case .noSignal: return "信号なし"
            case .red: return "赤"
            case .blinkGreen: return "青点滅"
            case .green: return "青"
            case .none: return "対象なし"
            case .unknown: return "不明"
            }
        }

        /// 歩行者信号として出す値か（信号なし・対象なしは、その番号に信号が無いとみなして出さない）。
        var isShown: Bool { self == .red || self == .blinkGreen || self == .green }
    }

    struct PedestrianSignal: Equatable {
        /// 元のプログラムの remaining_time。上位4ビット＋1、8以上は不明（-1）。単位は確定していない。
        let remaining: Int
        let state: SignalState
    }

    struct Header: Equatable {
        let type: UInt8
        let messageID: UInt8
        /// 交差点の番号（4バイトを16進の大文字で）。
        let intersection: String
    }

    enum Message: Equatable {
        case name(Header, identifier: String)
        case position(Header, latitude: Double, longitude: Double)
        case signals(Header, [PedestrianSignal])
        case other(Header)

        var header: Header {
            switch self {
            case let .name(h, _), let .position(h, _, _), let .signals(h, _), let .other(h): return h
            }
        }
    }

    enum ParseError: Error, Equatable {
        case tooShort(type: Int?, needed: Int)
    }

    /// iPhone が渡すメーカーデータから、メーカー番号を除いた中身を取り出す。PICS 以外なら nil。
    static func payload(fromManufacturerData data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count >= 2, UInt16(bytes[0]) | UInt16(bytes[1]) << 8 == companyID else { return nil }
        return Data(bytes.dropFirst(2))
    }

    /// processPics と同じ位置で読む（payload はメーカー番号を含まない）。
    static func parse(_ payload: Data) throws -> Message {
        let bytes = [UInt8](payload)
        guard bytes.count >= 10 else { throw ParseError.tooShort(type: nil, needed: 10) }
        let type = bytes[2]
        let minimum: Int = [0: 24, 1: 18, 2: 11][type] ?? 10
        guard bytes.count >= minimum else { throw ParseError.tooShort(type: Int(type), needed: minimum) }
        let header = Header(type: type, messageID: bytes[3],
                            intersection: bytes[6..<10].map { String(format: "%02X", $0) }.joined())
        switch type {
        case 0:
            let text = String(decoding: bytes[10..<24], as: UTF8.self)
                .replacingOccurrences(of: "\u{FFFD}", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "\u{0}"))
            return .name(header, identifier: text)
        case 1:
            return .position(header, latitude: Double(int32(bytes, at: 10)) / 1_000_000,
                             longitude: Double(int32(bytes, at: 14)) / 1_000_000)
        case 2:
            let signals = bytes[10..<min(16, bytes.count)].map { byte -> PedestrianSignal in
                let high = Int(byte >> 4)
                return PedestrianSignal(remaining: high >= 8 ? -1 : high + 1, state: state(byte & 0x0f))
            }
            return .signals(header, signals)
        default:
            return .other(header)
        }
    }

    private static func state(_ value: UInt8) -> SignalState {
        switch value {
        case 0: return .noSignal
        case 1: return .red
        case 2: return .blinkGreen
        case 3: return .green
        case 4: return .none
        default: return .unknown
        }
    }

    /// 前の信号と比べて、目盛りの値が変わった番号（どちらも分かる値のときだけ）。
    static func changedRemaining(from old: [PedestrianSignal], to new: [PedestrianSignal]) -> Set<Int> {
        Set(zip(old, new).enumerated().compactMap { index, pair in
            pair.0.remaining > 0 && pair.1.remaining > 0 && pair.0.remaining != pair.1.remaining ? index : nil
        })
    }

    /// 大きい順（ビッグエンディアン）の符号つき32ビット。
    private static func int32(_ bytes: [UInt8], at offset: Int) -> Int32 {
        let raw = bytes[offset..<offset + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        return Int32(bitPattern: raw)
    }

    /// 案内の帯に出す1行。「信号（神宮前一丁目）：1 青（残り目盛り5）・2 赤」。出す信号が無ければ nil。
    /// live は、目盛りの値が変わるのを見た信号の番号（0始まり）。ほかの信号には目盛りを付けない。
    static func line(name: String?, signals: [PedestrianSignal], live: Set<Int> = []) -> String? {
        let shown = signals.enumerated().filter { $0.element.state.isShown }
        guard !shown.isEmpty else { return nil }
        let states = shown.map { item -> String in
            let base = "\(item.offset + 1) \(item.element.state.label)"
            guard live.contains(item.offset), item.element.remaining > 0 else { return base }
            return base + "（残り目盛り\(item.element.remaining)）"
        }.joined(separator: "・")
        let place = name.flatMap { $0.isEmpty ? nil : "（\($0)）" } ?? ""
        return "信号\(place)：\(states)"
    }
}

/// 道案内のあいだだけ、近くの信号機の電波を受け取る（電池のため。画面を開いているときだけ）。
/// いちばん電波の強い交差点の、5秒以内に届いた信号だけを出す（古い色は出さない）。
final class SignalWatcher: NSObject, CBCentralManagerDelegate {
    /// 帯に出す1行。nil で隠す（主スレッドで呼ぶ）。
    var onChange: ((String?) -> Void)?

    private struct Entry {
        var name: String?
        var signals: [PICS.PedestrianSignal] = []
        var signalAt: Date?
        var rssi = -127
        /// 目盛りの値が変わるのを見た信号の番号（目盛りが本当に入っている証）。
        var live: Set<Int> = []
    }

    private var central: CBCentralManager?
    private var wanted = false
    private var entries: [String: Entry] = [:]
    private var timer: Timer?
    private var lastLine: String?

    /// 元のプログラムの STALE_AFTER_MS と同じ5秒。
    static let staleAfter: TimeInterval = 5

    func start() {
        wanted = true
        if let central {
            if central.state == .poweredOn { scan() }
        } else {
            // 最初に作ったときに、iOS が Bluetooth の許可を聞く（道案内を始めたときだけ）。
            central = CBCentralManager(delegate: self, queue: .main)
        }
    }

    func stop() {
        wanted = false
        central?.stopScan()
        timer?.invalidate()
        timer = nil
        entries = [:]
        publish(nil)
    }

    private func scan() {
        guard wanted, let central, central.state == .poweredOn, !central.isScanning else { return }
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn { scan() } else { publish(nil) }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard let data = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
              let payload = PICS.payload(fromManufacturerData: data),
              let message = try? PICS.parse(payload) else { return }
        var entry = entries[message.header.intersection] ?? Entry()
        entry.rssi = RSSI.intValue
        switch message {
        case let .name(_, identifier): entry.name = identifier
        case let .signals(_, signals):
            entry.live.formUnion(PICS.changedRemaining(from: entry.signals, to: signals))
            entry.signals = signals
            entry.signalAt = Date()
        case .position, .other: break
        }
        entries[message.header.intersection] = entry
        refresh()
    }

    private func refresh() {
        let now = Date()
        let fresh = entries.values.filter { $0.signalAt.map { now.timeIntervalSince($0) <= Self.staleAfter } ?? false }
        let nearest = fresh.max { $0.rssi < $1.rssi }
        publish(nearest.flatMap { PICS.line(name: $0.name, signals: $0.signals, live: $0.live) })
    }

    private func publish(_ line: String?) {
        guard line != lastLine else { return }
        lastLine = line
        onChange?(line)
    }
}
