/*
See LICENSE folder for this sample's licensing information.

Abstract:
中継の道で電波（UWB）の鍵を渡し、友だちと電波で測る。
*/

import Foundation
import NearbyInteraction
import QuartzCore
import simd

/// 10/14：電波の鍵は、そばのつなぎ（MultipeerConnectivity）でしか渡していなかった。
/// そのつなぎが切れると距離が出ない（10/11 実機：鍵は届いたのにすぐ切れて「Peers not connected」）。
/// 友だちとの2人の部屋には、位置を送るための暗号化した中継がすでにあるので、鍵はそこでも渡す。
/// Apple の文書でも、鍵はアプリのどんな通り道で渡してもよい。
///
/// そばのつなぎの測り方（PeerLink・groupPeers）には混ぜない。混ぜると同じ人を2人と数えたり、
/// 部屋に入っていない相手に呼び鈴を鳴らしたりする（10/14 の調べ）。この部品は1人の相手とだけ測り、
/// 測れた距離は画面の側が、そばのつなぎで測れていないときだけ使う。
/// iPhone どうしの測り合いは、アプリが裏に回ると止まる（ROADMAP 9/29）。これはつなぎ方を変えても同じ。
final class RelayRanger: NSObject, NISessionDelegate {
    /// 中継へ便りを流す（中身は暗号化される）。
    var send: ((Data) -> Void)?
    /// 測れた（主スレッドで呼ぶ）。
    var onReading: ((Float?, simd_float3?) -> Void)?

    private var session: NISession?
    private var peerToken: NIDiscoveryToken?
    private var peerTokenData: Data?
    private(set) var lastReadingAt: CFTimeInterval = 0

    /// いま中継の鍵で測れているか（直近3秒に距離が届いた）。
    var isRanging: Bool { session != nil && CACurrentMediaTime() - lastReadingAt < 3 }

    /// 測っている途中か（セッションがある）。
    var isActive: Bool { session != nil }

    /// 測り始めてよいか（running は、いま測っている途中か）。すべてそろったときだけ。
    /// 相手の位置が1分以内に届いている＝相手も同じ部屋に入っている（入っていない相手に流すと、
    /// 相手の端末では呼び鈴として鳴ってしまう）。電波が届くのは数十m なので、GPS で200m以内から。
    /// 境目で始めたりやめたりを繰り返さないよう、やめるのは300mを超えたとき・位置が2分届かないとき。
    static func shouldRange(supportsUWB: Bool, appActive: Bool, friendRoom: Bool, relayJoined: Bool,
                            nearbyRanging: Bool, partnerFixAge: TimeInterval?, gpsMetres: Double?,
                            running: Bool = false) -> Bool {
        guard supportsUWB, appActive, friendRoom, relayJoined, !nearbyRanging,
              let age = partnerFixAge, age < (running ? 120 : 60), let metres = gpsMetres else { return false }
        return metres <= (running ? 300 : 200)
    }

    /// 測り始める。鍵はこのとき1回送る（取りこぼしは、相手の鍵が届いたときに返す分で埋まる）。
    func start() {
        guard session == nil else { return }
        let s = NISession()
        s.delegate = self
        session = s
        sendMyToken()
        if peerToken != nil { run() }
    }

    func stop() {
        session?.invalidate()
        session = nil
        peerToken = nil
        peerTokenData = nil
        lastReadingAt = 0
    }

    /// 中継から相手の鍵が届いた。新しい鍵なら測り直し、こちらの鍵を1回だけ返す。
    func receive(_ note: Data) {
        guard let tokenData = Self.tokenData(from: note), Self.isNew(tokenData, stored: peerTokenData),
              let token = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NIDiscoveryToken.self, from: tokenData)
        else { return }
        peerToken = token
        peerTokenData = tokenData
        guard session != nil else { return }
        sendMyToken()
        run()
    }

    private func sendMyToken() {
        guard let token = session?.discoveryToken,
              let data = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
        else { return }
        send?(Self.note(tokenData: data))
    }

    private func run() {
        guard let session, let peerToken else { return }
        let config = NINearbyPeerConfiguration(peerToken: peerToken)
        // そばのつなぎの測り方（runConfig）と同じく、両方が対応していれば遠距離で測る。
        if #available(iOS 17.0, *), NISession.deviceCapabilities.supportsExtendedDistanceMeasurement {
            config.isExtendedDistanceMeasurementEnabled = true
        }
        session.run(config)
    }

    // MARK: - 便りの形（中継に流す JSON）

    struct TokenMessage: Codable {
        var type = "ni"
        let token: String
    }

    static func note(tokenData: Data) -> Data {
        (try? JSONEncoder().encode(TokenMessage(token: tokenData.base64EncodedString()))) ?? Data()
    }

    /// 中継に何を流されても、ここで線を引く（種類が違う・大きすぎるものは受け取らない）。
    static func tokenData(from note: Data) -> Data? {
        guard note.count < 4_000, let message = try? JSONDecoder().decode(TokenMessage.self, from: note),
              message.type == "ni" else { return nil }
        return Data(base64Encoded: message.token)
    }

    /// 前と同じ鍵なら何もしない（返事の返事でいつまでも往復しないように）。
    static func isNew(_ token: Data, stored: Data?) -> Bool { token != stored }

    // MARK: - NISessionDelegate

    func session(_ session: NISession, didUpdate nearbyObjects: [NINearbyObject]) {
        guard session === self.session, let peerToken,
              let object = nearbyObjects.first(where: { $0.discoveryToken == peerToken }) else { return }
        let distance = object.distance
        let direction = object.direction
        DispatchQueue.main.async { [weak self] in
            guard let self, session === self.session else { return }
            if distance != nil { self.lastReadingAt = CACurrentMediaTime() }
            self.onReading?(distance, direction)
        }
    }

    func session(_ session: NISession, didRemove nearbyObjects: [NINearbyObject],
                 reason: NINearbyObject.RemovalReason) {
        guard session === self.session else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, session === self.session else { return }
            switch reason {
            case .timeout:
                // 離れて見失っただけ。同じ鍵で測り直す。
                self.run()
            case .peerEnded:
                // 相手が測るのをやめた。次に相手が始めたら、新しい鍵が届く。
                self.peerToken = nil
                self.peerTokenData = nil
            @unknown default:
                break
            }
        }
    }

    func sessionSuspensionEnded(_ session: NISession) {
        guard session === self.session else { return }
        DispatchQueue.main.async { [weak self] in self?.run() }
    }

    func session(_ session: NISession, didInvalidateWith error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self, session === self.session else { return }
            // 次に条件がそろったとき、新しいセッションと新しい鍵で始め直す。
            self.session = nil
            self.lastReadingAt = 0
        }
    }
}
