// 離れている間の居場所のやりとり。
//
// UWB は数十m しか届かない。そこから先（駅の反対側、地上と地下）は GPS しかない。
// ここは「相手が遠いときだけ」使う層で、近づいて UWB が届いた瞬間に主役を明け渡す。
//
// 決めごと:
//  - 居場所は端末の中で鍵をかけてから流す。中継は中身を読めない
//  - 鍵は今日のグループの秘密 ID から作る。招待リンクを渡した時点で両方が持っている
//    （新しい鍵を別経路で配らない = 渡す経路が増えない）
//  - 中継は部屋に流すだけ。保存しない。グループが終われば部屋も消える
//  - ただし「最後の居場所」だけは、暗号文のまま部屋ごと・人ごとに1つ残す（関数 lastfix）。
//    相手のアプリが閉じていても、開けば最後にいた所が見えるように（10/3 Zenlyと同じ）
import Foundation
import CoreLocation
import CryptoKit

/// 相手から届いた居場所。
struct RemoteFix: Codable {
    let lat: Double
    let lon: Double
    let acc: Double
    let at: Double          // 相手の端末の時計（ミリ秒）

    var coordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }
    var age: TimeInterval { max(0, Date().timeIntervalSince1970 - at / 1000) }
}

/// Supabase Realtime の broadcast に、暗号文をそのまま流すだけの通り道。
/// 公式SDKを足さずに済むよう、WebSocket を直接話す（依存を増やさない）。
final class RemoteChannel: NSObject {
    /// 接続先。公開してよい鍵で、居場所の中身を読む力はない。
    private let host = "dmewybltarntlapasoiz.supabase.co"
    private let apiKey = "sb_publishable_iT6waNVeHj-Kb0Rp_Ux90w_1VCCk-WK"

    private let topic: String
    private let key: SymmetricKey
    /// 最後の居場所を残す部屋の名前（中継の部屋と同じもの）と、自分の名乗り（部屋ごとに作り直したもの）。
    private let room: String
    private let sender: String?
    private var lastStoreAt = Date.distantPast
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var heartbeat: Timer?
    private var ref = 0
    private var joined = false

    /// 相手の居場所が届いたら呼ばれる。
    var onFix: ((RemoteFix) -> Void)?
    /// 居場所以外の便り（おつかいなど）が届いたら呼ばれる。中身は送った側と同じJSON。
    var onNote: ((Data) -> Void)?
    /// つながっているかどうかが変わったら呼ばれる。
    var onState: ((Bool) -> Void)?
    /// 確認用のかぞえ（画面の下に出す）
    private(set) var sentCount = 0
    private(set) var gotCount = 0
    var isJoined: Bool { joined }

    /// - Parameter groupID: 今日のグループの秘密 ID。これ以外のものを外に出さない。
    /// - Parameter me: 自分の会員ID（名札）。最後の居場所を残すときの名乗りを作る。無ければ残さない。
    init(groupID: String, me: String? = nil) {
        // 部屋の名前は ID そのものではなく、その名前用に作り直したもの。
        // 中継業者に ID をそのまま渡さないため。
        let room = Self.derive(groupID, label: "room").prefix(16).map { String(format: "%02x", $0) }.joined()
        self.room = room
        self.topic = "realtime:kk-\(room)"
        self.key = SymmetricKey(data: Self.derive(groupID, label: "key"))
        self.sender = me.map { me in
            SHA256.hash(data: Data("sender|\(room)|\(me)".utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        }
        super.init()
    }

    private static func derive(_ id: String, label: String) -> Data {
        let salt = Data("kokodayo.remote".utf8)
        let info = Data(label.utf8)
        let ikm = SymmetricKey(data: Data(id.utf8))
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: salt, info: info, outputByteCount: 32)
            .withUnsafeBytes { Data($0) }
    }

    // MARK: - 出入り

    func connect() {
        guard task == nil else { return }
        var c = URLComponents()
        c.scheme = "wss"
        c.host = host
        c.path = "/realtime/v1/websocket"
        c.queryItems = [.init(name: "apikey", value: apiKey), .init(name: "vsn", value: "1.0.0")]
        guard let url = c.url else { return }
        let s = URLSession(configuration: .default)
        session = s
        task = s.webSocketTask(with: url)
        task?.resume()
        receive()
        join()
        heartbeat = Timer.scheduledTimer(withTimeInterval: 25, repeats: true) { [weak self] _ in self?.beat() }
    }

    func disconnect() {
        heartbeat?.invalidate(); heartbeat = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil; session = nil; joined = false
        onState?(false)
    }

    // MARK: - 送る

    /// 自分の居場所を包んで流す。相手が近くにいて UWB が効いているときは呼ばない。
    func send(_ location: CLLocation) {
        let fix = RemoteFix(lat: location.coordinate.latitude,
                            lon: location.coordinate.longitude,
                            acc: max(1, location.horizontalAccuracy),
                            at: Date().timeIntervalSince1970 * 1000)
        guard let plain = try? JSONEncoder().encode(fix),
              let sealed = try? AES.GCM.seal(plain, using: key).combined else { return }
        // 開いているあいだは20秒に1回だけ残す（流すのは毎回）。
        if Date().timeIntervalSince(lastStoreAt) > 20 { store(sealed: sealed) }
        guard joined else { return }
        sentCount += 1
        push(event: "broadcast", payload: [
            "type": "broadcast",
            "event": "p",
            "payload": ["b": sealed.base64EncodedString()],
        ])
    }

    // MARK: - 最後の居場所（暗号文のまま残す・読む）

    private static let lastFixURL = URL(string: "https://dmewybltarntlapasoiz.supabase.co/functions/v1/lastfix")!

    /// 閉じていても起こされたとき（BackgroundRelay）は、間を空けずに必ず残す。
    func store(_ location: CLLocation) {
        let fix = RemoteFix(lat: location.coordinate.latitude, lon: location.coordinate.longitude,
                            acc: max(1, location.horizontalAccuracy), at: Date().timeIntervalSince1970 * 1000)
        guard let plain = try? JSONEncoder().encode(fix),
              let sealed = try? AES.GCM.seal(plain, using: key).combined else { return }
        store(sealed: sealed)
    }

    private func store(sealed: Data, completion: (() -> Void)? = nil) {
        guard let sender else { completion?(); return }
        lastStoreAt = Date()
        var request = URLRequest(url: Self.lastFixURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "room": room, "sender": sender, "blob": sealed.base64EncodedString(),
        ])
        URLSession.shared.dataTask(with: request) { _, _, _ in completion?() }.resume()
    }

    /// 相手が最後に残した居場所（自分のものは除く・いちばん新しいもの）。
    func fetchLast() async -> RemoteFix? {
        var c = URLComponents(url: Self.lastFixURL, resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "room", value: room)]
        guard let url = c.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue(apiKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = obj["rows"] as? [[String: Any]] else { return nil }
        return rows.compactMap { row -> RemoteFix? in
            guard (row["sender"] as? String) != sender,
                  let b64 = row["blob"] as? String, let sealed = Data(base64Encoded: b64),
                  let box = try? AES.GCM.SealedBox(combined: sealed),
                  let plain = try? AES.GCM.open(box, using: key) else { return nil }
            return try? JSONDecoder().decode(RemoteFix.self, from: plain)
        }.max { $0.at < $1.at }
    }

    /// 居場所以外の便りを流す。鍵は居場所と同じ（中継は中身を読めない）。
    /// 相手が離れていて MPC が届かないときの唯一の通り道。
    func send(note: Data) {
        guard joined, let sealed = try? AES.GCM.seal(note, using: key).combined else { return }
        sentCount += 1
        push(event: "broadcast", payload: [
            "type": "broadcast",
            "event": "m",
            "payload": ["b": sealed.base64EncodedString()],
        ])
    }

    private func join() {
        push(event: "phx_join", payload: [
            "config": ["broadcast": ["self": false], "presence": ["key": UUID().uuidString]],
        ])
    }

    private func beat() {
        ref += 1
        write(["topic": "phoenix", "event": "heartbeat", "payload": [:], "ref": "\(ref)"])
    }

    private func push(event: String, payload: [String: Any]) {
        ref += 1
        write(["topic": topic, "event": event, "payload": payload, "ref": "\(ref)"])
    }

    private func write(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(text)) { _ in }
    }

    // MARK: - 受ける

    private func receive() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure:
                self.joined = false
                self.onState?(false)
                // 切れたら少し待って入り直す（駅の中で電波が途切れるのは普通のこと）
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    guard let self, self.task != nil else { return }
                    self.task = nil
                    self.connect()
                }
            case .success(let message):
                if case .string(let text) = message { self.handle(text) }
                self.receive()
            }
        }
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = obj["event"] as? String else { return }

        if event == "phx_reply", (obj["payload"] as? [String: Any])?["status"] as? String == "ok", !joined {
            joined = true
            onState?(true)
            return
        }
        guard event == "broadcast",
              let payload = obj["payload"] as? [String: Any],
              let inner = payload["payload"] as? [String: Any],
              let b64 = inner["b"] as? String,
              let sealed = Data(base64Encoded: b64),
              let box = try? AES.GCM.SealedBox(combined: sealed),
              let plain = try? AES.GCM.open(box, using: key) else { return }
        gotCount += 1
        // 居場所（p）と、それ以外の便り（m）。同じ鍵の同じ通り道を使う。
        if payload["event"] as? String == "m" {
            DispatchQueue.main.async { self.onNote?(plain) }
            return
        }
        guard let fix = try? JSONDecoder().decode(RemoteFix.self, from: plain) else { return }
        DispatchQueue.main.async { self.onFix?(fix) }
    }
}

/// 自分の居場所を拾う係。相手が遠いあいだだけ動かす（電池のため）。
final class LocationSource: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private(set) var last: CLLocation?
    var onFix: ((CLLocation) -> Void)?
    /// いま体が向いている向き。方角の画面を見ているあいだだけ入る。
    private(set) var heading: CLHeading?
    var onHeading: ((CLHeading) -> Void)?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = 5
        manager.activityType = .fitness
    }

    /// 案内中だけ細かく取る（曲がり角の手前で知らせるため）。
    private var navigating = false
    private var partnerMetres: Double?

    func setPrecise(_ on: Bool) {
        navigating = on
        applyPlan()
    }

    /// 相手までの距離を知らせる。遠いあいだは粗く・間をあけて取り、電池を持たせる。
    func setPartnerDistance(_ metres: Double?) {
        partnerMetres = metres
        applyPlan()
    }

    private func applyPlan() {
        let plan = LocationPlan.settings(partnerMetres: partnerMetres, navigating: navigating)
        if manager.desiredAccuracy != plan.accuracy { manager.desiredAccuracy = plan.accuracy }
        if manager.distanceFilter != plan.filter { manager.distanceFilter = plan.filter }
    }

    /// 位置を取り始めた時刻（最初の1分は、誤差の大きい位置でも待ちすぎない）。
    private var startedAt = Date()

    /// 共有しているあいだだけ true。画面を閉じても位置を取り続けるのはこの間だけ。
    private var sharing = false

    /// 共有を始める。設定しだいで、画面を閉じていても取り続ける。
    func start() {
        sharing = true
        startedAt = Date()
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        applyBackground()
        manager.startUpdatingLocation()
    }

    /// 画面を開いているあいだだけ、自分の場所を取る（誰とも共有しない）。
    /// 相手がいない最初の画面でも、自分の地図と「まわりを見る」を使えるようにするため。
    /// 背景での取得は切るので、閉じればiOSが止める。どこにも送らない。
    func startForeground() {
        sharing = false
        startedAt = Date()
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        manager.allowsBackgroundLocationUpdates = false
        manager.startUpdatingLocation()
    }

    /// 共有をやめる。背景での取得を切り、画面を開いているあいだだけに戻す。
    func stop() {
        // 先に背景での更新を切る。切らずに止めると青い表示が残ることがある。
        sharing = false
        manager.allowsBackgroundLocationUpdates = false
        stopHeading()
    }

    /// 画面を閉じて相手が遠いあいだは、GPSを止める（電池）。大きく動いたら BackgroundRelay が起こす。
    private(set) var suspended = false

    func suspend() {
        guard sharing, !suspended else { return }
        suspended = true
        manager.stopUpdatingLocation()
    }

    func resume() {
        guard suspended else { return }
        suspended = false
        applyBackground()
        manager.startUpdatingLocation()
    }

    /// 大きな移動の見張りが拾った位置を、いつもの位置として渡す（GPSを止めているあいだの代わり）。
    func inject(_ location: CLLocation) {
        guard location.horizontalAccuracy >= 0 else { return }
        last = location
        onFix?(location)
    }

    /// 方角は電気を食うので、その画面を見ているあいだだけ回す。
    /// シミュレータには磁石が無いので、ここは何も返さない。
    func startHeading() {
        guard CLLocationManager.headingAvailable() else { return }
        // 2度ごとだと、手に持っているだけで1秒に何十回も届く。5度で十分（電池）。
        manager.headingFilter = 5
        manager.headingOrientation = .portrait
        manager.startUpdatingHeading()
    }

    /// 地図の自分の三角のために、画面を開いているあいだは向きを取り続ける。
    /// 立てているあいだは、ほかの画面が閉じても止めない。
    var keepHeading = false {
        didSet { if keepHeading { startHeading() } }
    }

    func stopHeading() {
        guard !keepHeading else { return }
        heading = nil
        manager.stopUpdatingHeading()
    }

    /// 画面を閉じたときは、keepHeading でも止める（裏で磁石を回し続けない）。
    func pauseHeading() {
        manager.stopUpdatingHeading()
    }

    func locationManager(_ m: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        // 精度が負の値のときは、磁石が狂っている合図。使わない。
        guard newHeading.headingAccuracy >= 0 else { return }
        heading = newHeading
        onHeading?(newHeading)
    }

    /// いま、画面を閉じても位置を取り続ける設定になっているか。
    var continuesInBackground: Bool { manager.allowsBackgroundLocationUpdates }

    /// 画面を閉じているあいだも受け取るか。Info.plist に background location が
    /// 書かれていないのに true にすると落ちるので、書かれているかを見てから決める。
    func applyBackground() {
        let declared = (Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String])?
            .contains("location") ?? false
        let authorised = manager.authorizationStatus == .authorizedWhenInUse
            || manager.authorizationStatus == .authorizedAlways
        manager.allowsBackgroundLocationUpdates = sharing && declared && authorised && NearbyAlert.runsInBackground
        // 止まっている時に更新が勝手に止まると、相手の画面から自分が消える。
        manager.pausesLocationUpdatesAutomatically = false
    }

    func locationManager(_ m: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let l = locations.last(where: { LocationPlan.usable($0, last: last, startedAt: startedAt) }) else { return }
        last = l
        onFix?(l)
    }

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        if m.authorizationStatus == .authorizedWhenInUse || m.authorizationStatus == .authorizedAlways {
            applyBackground()
            m.startUpdatingLocation()
        }
    }
}

/// いまの距離を、どちらで測ったかごと持つ。
/// 電波（UWB）が新しければそちら。無ければ地図（GPS）。人には切り替えさせない。
struct MeetDistance {
    enum Source { case radio, map }
    let meters: Double
    let source: Source
    let accuracy: Double?      // 地図のときの誤差（m）

    static func choose(radio: Float?, radioAt: Date?, mine: CLLocation?, theirs: RemoteFix?) -> MeetDistance? {
        if let r = radio, let at = radioAt, Date().timeIntervalSince(at) < 3 {
            return MeetDistance(meters: Double(r), source: .radio, accuracy: nil)
        }
        if let mine, let theirs, theirs.age < 90 {
            let other = CLLocation(latitude: theirs.lat, longitude: theirs.lon)
            return MeetDistance(meters: mine.distance(from: other), source: .map,
                                accuracy: max(mine.horizontalAccuracy, theirs.acc))
        }
        return nil
    }
}

/// 位置の取り方と、使ってよい位置の見分け方（ここだけは画面と切り離して確かめられるようにしておく）。
enum LocationPlan {
    /// 使ってよい位置か。
    /// iOSは取り始めた直後に「前に取った古い位置」を先に渡すことがある（Appleの説明書にある）。
    /// 古い位置や誤差の大きい位置を相手に送ると、相手の地図で大きくずれる（9/27 本人「相手との位置が大きくズレる」）。
    static func usable(_ new: CLLocation, last: CLLocation?, startedAt: Date, now: Date = Date()) -> Bool {
        guard new.horizontalAccuracy >= 0 else { return false }                 // 無効な位置
        guard now.timeIntervalSince(new.timestamp) <= 15 else { return false }   // 古い（取り置き）
        if new.horizontalAccuracy <= 100 { return true }
        // 誤差が大きくても、ましな位置が1分以上来ていなければ使う（屋内で止まって見えるよりはいい）。
        if let last { return new.timestamp.timeIntervalSince(last.timestamp) > 60 }
        return now.timeIntervalSince(startedAt) > 20
    }

    /// 相手までの距離で、どれだけ細かく・どれだけ動いたら取るかを変える。
    /// 遠いあいだに10m単位で取り続けても、相手の画面ではほとんど変わらない（電池だけ減る）。
    static func settings(partnerMetres: Double?, navigating: Bool)
        -> (accuracy: CLLocationAccuracy, filter: CLLocationDistance) {
        if navigating { return (kCLLocationAccuracyBest, 2) }
        guard let d = partnerMetres else { return (kCLLocationAccuracyNearestTenMeters, 10) }
        if d < 300 { return (kCLLocationAccuracyNearestTenMeters, 5) }
        if d < 2_000 { return (kCLLocationAccuracyNearestTenMeters, 15) }
        return (kCLLocationAccuracyHundredMeters, 50)
    }
}
