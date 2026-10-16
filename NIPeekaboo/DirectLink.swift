/*
See LICENSE folder for this sample's licensing information.

Abstract:
ネットを通さず、iPhone どうしを Wi-Fi Aware で直接つなぎ、電波（UWB）の鍵を運ぶ。
*/

import Foundation
import CryptoKit
import Network
import SwiftUI
import WiFiAware
import DeviceDiscoveryUI

/// 10/17 本人「ネットを通さず送れるのか」「Wi-Fi Awareも足して」。
///
/// 待ち合わせで相手が見つからないのは、花火大会・ライブ会場・駅の地下のように、人が多くて回線が詰まる所や
/// 圏外が多い。中継の道（RemoteChannel）はネットが要るので、そういう所では鍵が渡せない。
/// Wi-Fi Aware（iOS 26）は、ネットもルーターも通さず、iPhone どうしを Wi-Fi の電波で直接つなぐ。
///
/// 決めごと:
///  - 運ぶのは電波の鍵の便りだけ（RelayRanger が作る `{"type":"ni",…}`）。許可や本人確認の
///    やりとり（MultipeerConnectivity）は載せ替えない。友だちとの2人の部屋だけで使う。
///  - つながる相手は「ペアリング済みの iPhone」なら誰でもありうるので、中身は部屋の鍵で包む
///    （中継と同じ鍵）。開けられるのは同じ部屋の友だちだけ。
///  - 最初に一度、2台ともペアリングの画面（Apple の DevicePairingView／DevicePicker）が要る。
///  - 部屋の「主」（2人の鍵の小さいほう）が送り出し、もう一方が探す。2台で役が食い違わない。
///  - 書き方は Apple の見本「Building peer-to-peer apps」をなぞる（NetworkListener／NetworkBrowser）。
@available(iOS 26.0, *)
@MainActor
final class DirectLink {
    static let serviceName = "_kokodayo-ni._tcp"

    /// つなぎの上を流れるもの。部屋の鍵で包んだ便り。
    struct Envelope: Codable, Sendable {
        let sealed: Data
    }

    typealias Link = NetworkConnection<Coder<Envelope, Envelope, NetworkJSONCoder>>

    /// 便りが届いた（包みを開けたあとの中身）。
    var onNote: ((Data) -> Void)?
    /// つながった・切れた。
    var onState: ((Bool) -> Void)?

    private var key: SymmetricKey?
    private var task: Task<Void, Never>?
    private var connection: Link?
    private(set) var isConnected = false

    /// この iPhone が Wi-Fi Aware を使えるか（iPhone 12 以降・iOS 26 以降）。
    static var isSupported: Bool { WACapabilities.supportedFeatures.contains(.wifiAware) }

    /// ペアリング済みの機器ができるまで待つ（無いうちは、送り出しも探しもしない）。
    private static func waitForPairedDevice() async {
        do {
            for try await devices in WAPairedDevice.allDevices where !devices.isEmpty { return }
        } catch {}
    }

    var isRunning: Bool { task != nil }

    /// 部屋の主なら送り出し、そうでなければ探す。つながっても切れても、止めるまで続ける。
    func start(groupID: String, publisher: Bool) {
        guard task == nil, Self.isSupported else { return }
        key = RemoteChannel.noteKey(groupID: groupID)
        task = Task { [weak self] in
            await Self.waitForPairedDevice()
            while !Task.isCancelled {
                if publisher { await self?.publish() } else { await self?.subscribe() }
                // 切れたら少し待って、また待ち受け直す・探し直す。
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        connection = nil
        key = nil
        setConnected(false)
    }

    func send(_ note: Data) {
        guard let connection, let key, let sealed = try? AES.GCM.seal(note, using: key).combined else { return }
        Task { try? await connection.send(Envelope(sealed: sealed)) }
    }

    private func setConnected(_ on: Bool) {
        guard on != isConnected else { return }
        isConnected = on
        onState?(on)
    }

    // MARK: - 送り出す側・探す側（Apple の見本と同じ形）

    private static func parameters() -> NWParametersBuilder<Coder<Envelope, Envelope, NetworkJSONCoder>> {
        .parameters {
            Coder(receiving: Envelope.self, sending: Envelope.self, using: NetworkJSONCoder()) {
                TLS()
            }
        }
    }

    private func publish() async {
        guard let service = WAPublishableService.allServices[Self.serviceName] else { return }
        do {
            try await NetworkListener(for: .wifiAware(.connecting(to: service, from: .allPairedDevices)),
                                      using: Self.parameters())
                .run { [weak self] connection in
                    await self?.adopt(connection)
                }
        } catch {
            #if DEBUG
            print("DIRECT publish failed: \(error)")
            #endif
        }
    }

    private func subscribe() async {
        guard let service = WASubscribableService.allServices[Self.serviceName] else { return }
        do {
            let endpoint = try await NetworkBrowser(for: .wifiAware(.connecting(to: .allPairedDevices, from: service)))
                .run { endpoints in
                    if let first = endpoints.first { return .finish(first) } else { return .continue }
                }
            await adopt(NetworkConnection(to: endpoint, using: Self.parameters()))
        } catch {
            #if DEBUG
            print("DIRECT subscribe failed: \(error)")
            #endif
        }
    }

    /// つながった相手から届く便りを、切れるまで読む。開けられない包みは黙って捨てる（部屋の外の人）。
    private func adopt(_ link: Link) async {
        connection = link
        setConnected(true)
        do {
            for try await (envelope, _) in link.messages {
                guard let key, let box = try? AES.GCM.SealedBox(combined: envelope.sealed),
                      let plain = try? AES.GCM.open(box, using: key) else { continue }
                onNote?(plain)
            }
        } catch {
            #if DEBUG
            print("DIRECT link ended: \(error)")
            #endif
        }
        if connection === link {
            connection = nil
            setConnected(false)
        }
    }

    // MARK: - 最初の1回のペアリング（Apple の画面）

    /// ペアリングの画面。2人が同時に開く。主は「見つけてもらう」側、もう一方は「相手を選ぶ」側。
    static func pairingController(friendName: String, publisher: Bool,
                                  onDone: @escaping () -> Void) -> UIViewController {
        UIHostingController(rootView: PairingSheet(friendName: friendName, publisher: publisher, onDone: onDone))
    }

    private struct PairingSheet: View {
        let friendName: String
        let publisher: Bool
        let onDone: () -> Void

        var body: some View {
            NavigationStack {
                Form {
                    Section {
                        Text("ネットがつながらない所（地下・人の多い会場）でも、\(friendName)の iPhone と直接つないで電波で探せるようにします。最初に1回だけ、2人そろってこの画面を開いてください。")
                    }
                    Section {
                        if let pub = WAPublishableService.allServices[DirectLink.serviceName],
                           let sub = WASubscribableService.allServices[DirectLink.serviceName] {
                            if publisher {
                                DevicePairingView(.wifiAware(.connecting(to: pub, from: .userSpecifiedDevices)),
                                                  access: .permanent) {
                                    Label("\(friendName)に見つけてもらう", systemImage: "antenna.radiowaves.left.and.right")
                                } fallback: {
                                    Text("この iPhone では使えません")
                                }
                            } else {
                                DevicePicker(.wifiAware(.connecting(to: .userSpecifiedDevices, from: sub)),
                                             access: .permanent) { _ in
                                    onDone()
                                } label: {
                                    Label("\(friendName)の iPhone を選ぶ", systemImage: "iphone.radiowaves.left.and.right")
                                } fallback: {
                                    Text("この iPhone では使えません")
                                }
                            }
                        }
                    } footer: {
                        Text(publisher ? "\(friendName)の画面で、あなたの iPhone を選んでもらいます。"
                                       : "\(friendName)の画面に「見つけてもらう」が出ている状態で選んでください。")
                    }
                }
                .navigationTitle("ネットなしでつなぐ準備")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完了", action: onDone)
                    }
                }
            }
        }
    }
}
