// 一度つないだ相手を覚えておく。
//
// 毎回リンクを送り合うのが面倒だ、という話から。
// 覚えるのは「この人とはつないでよい」という事実と、その人の鍵と名前だけ。
// 居場所も、会った場所も、履歴も持たない。
//
// 再開のときの部屋名は、2人の鍵から毎回その場で計算する（下の pairRoom）。
// だからリンクも合言葉も要らないし、こちらから相手に何かを送る必要もない。
import Foundation
import UIKit
import UserNotifications
import CryptoKit

/// この端末の名札。グループごとの鍵と違って作り直さない。
///
/// これが無いと「次からリンク無し」が成り立たない。グループの鍵は毎回作り直す
/// ので、覚えた相手と次に同じ部屋を計算できず、押しても届かないボタンになる。
/// 名札は公開鍵なので、渡すのは「この端末だ」という事実だけ。居場所も履歴も
/// 含まない。渡す相手は、一度つないだ人だけ。
enum SelfIdentity {
    private static let service = "jp.shutanuma.kokodayo.identity"
    private static let account = "self"

    /// 公開鍵（相手に渡すほう）。変わらないので一度だけ作る（画面の更新のたびに呼ばれる）。
    static var publicKey: String {
        if let cachedPublic { return cachedPublic }
        let value = key().publicKey.rawRepresentation.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        // 仮の名札（下の key() を参照）は覚えない。次に読めたときに本物に戻る。
        if !unavailable { cachedPublic = value }
        return value
    }
    private static var cachedPublic: String?
    /// キーチェーンは読むのが遅い。一度読んだら覚えておく。
    private static var cachedKey: Curve25519.Signing.PrivateKey?
    /// いま本物の名札を読めない（画面ロック中など）。このあいだは名札を相手に渡さない。
    private(set) static var unavailable = false

    /// 画面を閉じていても（再起動後に一度ロックを外していれば）読める置き方。
    /// 以前は「ロックを外しているあいだだけ」にしていて、画面ロック中に裏で動いたときに読めず、
    /// 新しい名札を作ってしまっていた。それを相手が覚え、2台で部屋の名前が食い違った
    /// （9/28 実機：友だちの行の「部屋」の4文字が2台で違った）。
    private static let accessible = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

    /// 署名にも使う秘密鍵。無ければその場で作って、以後ずっと同じものを使う。
    /// 「無い」のではなく「いま読めない」ときは、作らない（作ると名札が変わってしまう）。
    static func key() -> Curve25519.Signing.PrivateKey {
        if let cachedKey { return cachedKey }
        switch load() {
        case .found(let existing):
            cachedKey = existing
            unavailable = false
            loosenAccess()
            return existing
        case .missing:
            let key = Curve25519.Signing.PrivateKey()
            let item: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecAttrAccessible as String: accessible,
                kSecAttrSynchronizable as String: false,
                kSecValueData as String: key.rawRepresentation,
            ]
            SecItemAdd(item as CFDictionary, nil)
            cachedKey = key
            unavailable = false
            return key
        case .locked:
            // 仮の鍵で動かす（覚えない・渡さない）。部屋の名前は合わないが、名札を書き換えるよりいい。
            unavailable = true
            return Curve25519.Signing.PrivateKey()
        }
    }

    private enum Loaded {
        case found(Curve25519.Signing.PrivateKey)
        case missing
        case locked
    }

    private static func load() -> Loaded {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return .missing }
        guard status == errSecSuccess, let data = result as? Data,
              let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) else { return .locked }
        return .found(key)
    }

    /// 前の置き方（ロック中は読めない）で入っている名札を、ロック中も読める置き方に直す。
    private static func loosenAccess() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemUpdate(query as CFDictionary, [kSecAttrAccessible as String: accessible] as CFDictionary)
    }
}

struct KnownFriend: Codable, Equatable {
    /// 相手の公開鍵（グループでの member ID と同じもの）
    let key: String
    var name: String
    /// 最後につないだ日。並べ替えと、古いものを落とすためだけに使う。
    var lastMet: Date
    /// 相手の iPhone の通知の宛先（Apple のプッシュ通知）と、その環境（sandbox / production）。
    /// 閉じている相手にも「つなごうとしています」を届けるため。部屋の中で暗号にして受け取ったもの。
    var push: String? = nil
    var pushEnv: String? = nil

    static func == (a: KnownFriend, b: KnownFriend) -> Bool { a.key == b.key }
}

enum KnownFriends {
    // v1 は「グループごとの鍵」を覚えていた。次に同じ部屋を計算できない値なので、
    // 置き場所ごと変える（押しても届かないボタンを出さないため）。
    private static let fileName = "friends-v2.json"
    private static var url: URL? {
        try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                     appropriateFor: nil, create: true)
            .appendingPathComponent(fileName)
    }

    /// 覚えている相手。新しく会った順。
    /// 画面の更新のたびに呼ばれるので、ファイルは最初の一度だけ読み、あとは覚えておく（書くときに入れ替える）。
    static func all() -> [KnownFriend] {
        if let cache { return cache }
        guard let url else { return [] }
        // ファイルが無いのは「まだ誰も覚えていない」。覚えておいてよい。
        guard FileManager.default.fileExists(atPath: url.path) else {
            cache = []
            return []
        }
        // あるのに読めないのは、画面ロック中などで「いま読めない」だけ。空だと覚えてはいけない
        // （9/28「友達がいなくなった」：ロック中に裏で起きたとき空を覚え、そのまま一覧が消えていた）。
        guard let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([KnownFriend].self, from: data) else { return [] }
        let sorted = list.sorted { $0.lastMet > $1.lastMet }
        cache = sorted
        // 前の置き方（ロック中は読めない）のファイルを、読めたときに直しておく。
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                               ofItemAtPath: url.path)
        return sorted
    }
    private static var cache: [KnownFriend]?

    /// いま一覧を読めているか（読めないまま書くと、覚えていた友だちを消してしまう）。
    private static var readable: Bool {
        _ = all()
        return cache != nil
    }

    /// つないだ相手を覚える。同じ相手なら名前と日付だけ新しくする。
    static func remember(key: String, name: String, push: String? = nil, pushEnv: String? = nil) {
        guard !key.isEmpty, readable else { return }
        let before = all().first { $0.key == key }
        // 同じ名前で違う名札のものは、前に間違って覚えた名札とみなして入れ替える
        // （その名札では部屋の名前が合わず、押しても相手に届かない）。
        var list = all().filter { $0.key != key && $0.name != name }
        list.insert(KnownFriend(key: key, name: name, lastMet: Date(),
                                push: push ?? before?.push, pushEnv: pushEnv ?? before?.pushEnv), at: 0)
        // 何人でも覚えておく。消えるのは、本人が消したときだけ（本人 9/28「どちらかが削除しない限り消えないように」）。
        save(list)
    }

    static func forget(key: String) {
        guard readable else { return }
        save(all().filter { $0.key != key })
    }

    private static func save(_ list: [KnownFriend]) {
        cache = list.sorted { $0.lastMet > $1.lastMet }
        guard let url, let data = try? JSONEncoder().encode(list) else { return }
        // 画面ロック中でも読めるように（再起動後に一度ロックを外していれば）。名札と同じ考え方。
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var target = url
        try? target.setResourceValues(values)
    }

    /// 2人の鍵から、毎回同じ部屋の名前を作る。
    /// どちらの端末で計算しても同じになるよう、鍵を並べ替えてから混ぜる。
    /// 元の鍵は外に出ない（中継業者に渡るのはこの計算結果だけ）。
    static func pairSecret(mine: String, theirs: String) -> String {
        let pair = [mine, theirs].sorted().joined(separator: "|")
        // 画面の更新のたびに友だちの数だけ呼ばれる。同じ2人なら答えは同じなので覚えておく。
        if let hit = pairMemo[pair] { return hit }
        let ikm = SymmetricKey(data: Data(pair.utf8))
        let out = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm,
                                         salt: Data("kokodayo.pair".utf8),
                                         info: Data("room".utf8),
                                         outputByteCount: 32)
        let value = out.withUnsafeBytes { Data($0) }.base64EncodedString()
        pairMemo[pair] = value
        return value
    }
    private static var pairMemo: [String: String] = [:]
}

// MARK: - 閉じていても届く呼び鈴（Apple のプッシュ通知）

/// 友だちが「つなぐ」を押したとき、相手のアプリが閉じていても知らせる（9/28 本人が「Aのあとで B」を選んだ）。
/// 宛先（device token）は友だちとの部屋の中で暗号にして渡し、送るのは Supabase の関数（knock）から Apple へ。
/// 中継に渡るのは宛先と「名前」だけで、居場所は渡らない。
enum PushKnock {
    private static let tokenKey = "kokodayo.pushToken"
    private static let endpoint = URL(string: "https://dmewybltarntlapasoiz.supabase.co/functions/v1/knock")!
    private static let apiKey = "sb_publishable_iT6waNVeHj-Kb0Rp_Ux90w_1VCCk-WK"

    static var myToken: String? { UserDefaults.standard.string(forKey: tokenKey) }

    /// 家のアレクサから買い物を届けるために、自分の宛先と環境をコピーする（kokodayo://push-token で開く）。
    /// コピーするのは通知の宛先だけで、居場所や友だちの情報は入らない。
    static func copyMyToken() -> String {
        guard let token = myToken else { return "まだ通知の宛先がありません。通知を許可してから開き直してください。" }
        UIPasteboard.general.string = "\(token) \(environment)"
        return "通知の宛先をコピーしました"
    }

    // MARK: 家のアレクサからの買い物（おつかい MCP）

    /// 買い物の通知に付く「済んだ」ボタン。押すとアプリを開かずに、おつかい MCP に済んだを返す。
    static let errandCategory = "ERRAND"
    static let errandDoneAction = "ERRAND_DONE"
    private static let errandServer = "https://otsukai-mcp.shoujiki-panman.workers.dev/errands"

    /// 通知そのものを押して開いたとき、画面が出そろってから「済んだ？」を聞くために預けておく。
    @MainActor static var pendingErrand: (id: String, item: String)?

    static var errandNotificationCategory: UNNotificationCategory {
        let done = UNNotificationAction(identifier: errandDoneAction, title: "済んだ", options: [])
        return UNNotificationCategory(identifier: errandCategory, actions: [done], intentIdentifiers: [], options: [])
    }

    /// 済んだを返す。本人確認は「この iPhone の通知の宛先」で行う（届け先と同じ宛先だけが済んだにできる）。
    @discardableResult
    static func reportErrandDone(id: String) async -> Bool {
        guard let token = myToken, id.count == 36, let url = URL(string: "\(errandServer)/\(id)/done") else { return false }
        // 閉じた状態で「済んだ」を押すと、アプリは裏で一瞬だけ起こされる。送り終わるまで止めないよう時間をもらう。
        let task = await UIApplication.shared.beginBackgroundTask(withName: "errand-done")
        defer { Task { @MainActor in UIApplication.shared.endBackgroundTask(task) } }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue(token, forHTTPHeaderField: "x-push-token")
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    static func save(token: Data) {
        UserDefaults.standard.set(token.map { String(format: "%02x", $0) }.joined(), forKey: tokenKey)
    }

    /// 開発用の署名で入れたアプリは sandbox、App Store / TestFlight は production。
    /// 入っている配布用ファイル（embedded.mobileprovision）の中の aps-environment で見分ける。
    static let environment: String = {
        guard let path = Bundle.main.path(forResource: "embedded", ofType: "mobileprovision"),
              let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .isoLatin1) else { return "production" }
        guard let r = text.range(of: "<key>aps-environment</key>") else { return "production" }
        return text[r.upperBound...].prefix(80).contains("development") ? "sandbox" : "production"
    }()

    /// 相手に「〇〇が近くにいます（あと◯km）」を送る。文面はサーバーが決める（送るのは距離の数字だけ）。
    static func near(_ friend: KnownFriend, name: String, metres: Double) async {
        guard let to = friend.push else { return }
        var request = URLRequest(url: endpoint, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = ["to": to, "env": friend.pushEnv ?? "production", "name": name,
                                   "kind": "near", "metres": Int(metres.rounded())]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await URLSession.shared.data(for: request)
    }

    /// 相手に「〇〇がつなごうとしています」を送る。宛先を知らなければ何もしない（アプリを開いていれば呼び鈴Aで届く）。
    static func ring(_ friend: KnownFriend, from me: String, name: String) async {
        guard let to = friend.push else { return }
        var request = URLRequest(url: endpoint, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let body: [String: String] = ["to": to, "env": friend.pushEnv ?? "production", "from": me, "name": name]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await URLSession.shared.data(for: request)
    }
}

extension Notification.Name {
    /// 呼び鈴の通知が押された（object に相手の名札）。
    static let kokodayoKnock = Notification.Name("kokodayo.knock")
}
