// 一度つないだ相手を覚えておく。
//
// 毎回リンクを送り合うのが面倒だ、という話から。
// 覚えるのは「この人とはつないでよい」という事実と、その人の鍵と名前だけ。
// 居場所も、会った場所も、履歴も持たない。
//
// 再開のときの部屋名は、2人の鍵から毎回その場で計算する（下の pairRoom）。
// だからリンクも合言葉も要らないし、こちらから相手に何かを送る必要もない。
import Foundation
import CryptoKit

struct KnownFriend: Codable, Equatable {
    /// 相手の公開鍵（グループでの member ID と同じもの）
    let key: String
    var name: String
    /// 最後につないだ日。並べ替えと、古いものを落とすためだけに使う。
    var lastMet: Date

    static func == (a: KnownFriend, b: KnownFriend) -> Bool { a.key == b.key }
}

enum KnownFriends {
    private static let fileName = "friends.json"
    private static var url: URL? {
        try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                     appropriateFor: nil, create: true)
            .appendingPathComponent(fileName)
    }

    /// 覚えている相手。新しく会った順。
    static func all() -> [KnownFriend] {
        guard let url, let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([KnownFriend].self, from: data) else { return [] }
        return list.sorted { $0.lastMet > $1.lastMet }
    }

    /// つないだ相手を覚える。同じ相手なら名前と日付だけ新しくする。
    static func remember(key: String, name: String) {
        guard !key.isEmpty else { return }
        var list = all().filter { $0.key != key }
        list.insert(KnownFriend(key: key, name: name, lastMet: Date()), at: 0)
        save(Array(list.prefix(10)))
    }

    static func forget(key: String) {
        save(all().filter { $0.key != key })
    }

    private static func save(_ list: [KnownFriend]) {
        guard let url, let data = try? JSONEncoder().encode(list) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
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
        let ikm = SymmetricKey(data: Data(pair.utf8))
        let out = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm,
                                         salt: Data("kokodayo.pair".utf8),
                                         info: Data("room".utf8),
                                         outputByteCount: 32)
        return out.withUnsafeBytes { Data($0) }.base64EncodedString()
    }
}
