// 「AIに頼む」— 一文で言うと、アプリの中の操作を順に進める手伝い役。
//
// 形は Claude Code と Meta の Muse から借りた（2026-09-25 本人の依頼）。
//  - 言われたことを読み、手順を見せながら進める（何をしているかが見える）
//  - 相手に何かを送る前・決める前は、必ず人に確認する（提案するのはAI、決めるのは人）
//
// 読むのはiPhoneの中のAI（Apple の Foundation Models。サーバーも鍵も要らず、
// 位置も文も外に出ない）。使えない端末では、かんたんな読み方（言葉の拾い上げ）に
// 切り替える。どちらで読んだかは画面に出す。
// AIにやらせるのは「一文を、操作1つと中身に分ける」ことだけ。探す・並べる・送るは
// コードがやる（小さいモデルに判断を任せない。Jevで測った教訓）。
import Foundation
import UIKit
import MapKit
import SafariServices
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - 何をしたいか

struct AskIntent: Sendable {
    enum Kind: String, Sendable { case meet, errand, mood, route, place, onTheWay, watch, placeInfo, killTime }
    var kind: Kind
    /// 待ち合わせ・探す場所の種類（カフェ・駅など）。
    var placeKind: String = ""
    var items: [String] = []
    var mood: String = ""
    var query: String = ""
    /// 「〇〇に案内して」のように、そこへ行きたいと言っている。見つけたら案内開始を勧める。
    var go: Bool = false
    /// 「赤坂駅付近ランチ」の「赤坂駅」。ここのまわりで query を探す（空なら自分のまわり）。
    var near: String = ""
    /// ふわっとした条件を言い換えた、地図で探す言葉（「作業できる所」→ カフェ・図書館…）。
    var words: [String] = []
    /// 「7時までに来なかったら」の締め切り。
    var deadline: Date?
    /// 時間つぶしの長さ（分）。
    var minutes: Int = 0
    /// 店について聞くこと（hours / phone / site）。
    var topic: String = ""
}

enum AskParser {

    /// 一文を読む。AIが使えれば AI、使えなければ言葉の拾い上げ。2つ目は AI で読んだか。
    static func parse(_ text: String, partner: String) async -> (AskIntent, Bool) {
        // 「伝えて」「言っといて」「行き方」ははっきりした合図なので、言葉で決める。
        // Macで同じAIに6文かけたら、「ちょっと遅れるって言っといて」「改札の前で
        // 待ってると伝えて」を「会う」と取り違えた（2/6）。小さいモデルに迷わせない。
        let rule = keywordParse(text, partner: partner)
        // 見張る・時間つぶし・寄り道・店のことを聞く は、言い方がはっきりしているので言葉で決める。
        if [.watch, .killTime, .onTheWay, .placeInfo].contains(rule.kind) { return (rule, false) }
        if (rule.kind == .mood || rule.kind == .route), hasStrongSignal(text) { return (rule, false) }
        // 「ラゾーナに案内して」「〇〇まで行きたい」も言葉で決める（AIは「連れてって」を
        // 「会う」と取り違えた）。
        if rule.go { return (rule, false) }
        // 「赤坂駅付近ランチ」「渋谷でラーメン」は、場所とそのまわりで探すものに分けて言葉で決める。
        // 文のまま探して、18km先の「四ツ谷駅 赤坂口改札内の充電スポット」を出していた（9/27 実機）。
        if rule.kind == .place, let a = anchored(text) {
            return (AskIntent(kind: .place, query: a.what, near: a.near), false)
        }
        // 「近くのカフェ」「いちばん近い駅」も言葉で決める（AIは「いちばん近い駅」を
        // 相手への行き方と取り違えた）。
        if rule.kind == .place, nearbyMarkers.contains(where: { text.contains($0) }) { return (rule, false) }
        // 「ラーメン食べたい」「カラオケ行きたい」のように種類の言葉が取れたら、AIに聞かずに決める。
        // AIは「ボウリング場」（15km先を選ぶ）や「めん」を返すことがあり、待つぶん遅い（9/26 実測）。
        if rule.kind == .place, isGeneric(rule.query) { return (rule, false) }
        // 「一蘭」「一蘭どこ」のように、頼みが店や場所の名前だけなら、AIに聞かずに名前で探す。
        // AIは「一蘭」を「駅で会う」、「一蘭どこ」を「東京駅で会う」と読んだ（10/11 実機・Macで測定）。
        if rule.kind == .place, rule.words.isEmpty, looksLikeName(rule.query) { return (rule, false) }
        // 「雨でも静かに作業できるところ」は、条件を探す言葉（図書館・カフェ…）に言い換えて決める。
        if rule.kind == .place, !rule.words.isEmpty { return (rule, false) }
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), SystemLanguageModel.default.isAvailable {
            let result = await withTimeout(seconds: 10) { try await aiParse(text, partner: partner) }
            if let result { return (result, true) }
        }
        #endif
        return (keywordParse(text, partner: partner), false)
    }

    /// 店や場所の名前らしいか。短く、ひらがなで終わらない（「で落ち合おう」「休めるとこ」は名前ではない）。
    static func looksLikeName(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, q.count <= 15, !q.contains("、"), !q.contains("。"),
              let last = q.unicodeScalars.last else { return false }
        return !(0x3041...0x309F).contains(Int(last.value))
    }

    private static func hasStrongSignal(_ text: String) -> Bool {
        (["伝えて", "言っといて", "と言って", "って言って", "と伝え", "って伝え", "行き方", "どう行け", "どう行く", "道順"]
            + sendWords).contains { text.contains($0) }
    }

    /// iPhoneの中のAIが使えるか（画面に「AIで読みます／かんたんに読みます」を出すため）。
    static var aiAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) { return SystemLanguageModel.default.isAvailable }
        #endif
        return false
    }

    private static func withTimeout<T: Sendable>(seconds: Double,
                                                 _ work: @escaping @Sendable () async throws -> T) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { try? await work() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    private static func aiParse(_ text: String, partner: String) async throws -> AskIntent {
        let session = LanguageModelSession(instructions: """
        あなたは待ち合わせアプリ「ここだよ」の中の手伝い役です。
        ユーザーの一文を読み、アプリでできる操作を1つだけ選び、中身を取り出します。
        相手の名前は「\(partner)」です。
        - meet: 相手と会う・待ち合わせ場所を決める
        - errand: 相手に買い物を頼む（items に品物の名前だけを入れる）
        - mood: 相手に自分の様子を一言で伝える（mood に伝える一言）
        - route: 相手のいるところへの行き方を知りたい
        - place: それ以外で、場所やお店を探す（query に探す言葉）
        文に無いことは作らないでください。関係ない欄は空にしてください。
        例:
        「遅れるって伝えて」→ mood（mood: 遅れる）
        「駅で会おう」→ meet（placeKind: 駅）
        「帰りにパンとお茶買ってきて」→ errand（items: パン, お茶）
        「近くでそば食べたい」→ place（query: そば）
        「東京駅に連れてって」→ place（query: 東京駅）
        """)
        let response = try await session.respond(to: text, generating: AskPlanAI.self)
        let p = response.content
        return AskIntent(kind: AskIntent.Kind(rawValue: p.kind) ?? .place,
                         placeKind: p.placeKind.trimmingCharacters(in: .whitespaces),
                         items: p.items.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
                         mood: String(p.mood.prefix(20)),
                         query: p.query)
    }
    #endif

    // MARK: かんたんな読み方（AIが使えないとき）

    static func keywordParse(_ raw: String, partner: String = "") -> AskIntent {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        func has(_ words: [String]) -> Bool { words.contains { text.contains($0) } }

        // 「7時までに来なかったら教えて」（Life360 の No Show と同じ見張り）
        if has(["来なかったら", "着かなかったら", "来なければ", "着かなければ", "来ないなら", "着かないなら", "来てなかったら"]) {
            return AskIntent(kind: .watch, deadline: AskSkills.deadline(in: text))
        }
        // 「10分遅れる」「遅れそう」だけでも、相手に伝える頼みとして読む。
        if has(["遅れる", "遅れそう", "遅刻", "遅れます"]), !has(["来なかったら", "着かなかったら"]) {
            return AskIntent(kind: .mood, mood: String(text.prefix(20)))
        }
        // 「舞台まで2時間どうする？」「30分ひまつぶし」
        if let m = AskSkills.freeMinutes(in: text) {
            return AskIntent(kind: .killTime, minutes: m)
        }
        // 「途中でコーヒー買える所」（行き先への道すがら）。「〇〇に行く途中で」も行き先の指示より先に見る。
        if has(["途中で", "途中に", "道中", "寄り道", "寄れる", "ついでに寄"]), !has(["買ってきて", "買って来て"]) {
            return AskIntent(kind: .onTheWay, query: AskSkills.onTheWayWhat(text))
        }
        // 「そこ何時まで？」「スタバの電話番号」
        if let topic = AskSkills.placeTopic(text) {
            return AskIntent(kind: .placeInfo, query: AskSkills.placeInfoTarget(text), topic: topic)
        }

        // 「〇〇に案内して」「〇〇まで行きたい」「〇〇へ連れてって」
        if let dest = destination(in: text) {
            let toPartner = (!partner.isEmpty && dest.contains(partner)) || dest.contains("のところ") || dest.contains("相手")
            if toPartner { return AskIntent(kind: .route) }
            return AskIntent(kind: .place, query: dest, go: true)
        }

        if has(nearbyMarkers) {
            var q = text
            for m in nearbyMarkers { q = q.replacingOccurrences(of: m, with: "") }
            return AskIntent(kind: .place, placeKind: placeWord(in: text) ?? "", query: searchWords(q))
        }
        if has(["伝えて", "様子", "って言って", "と言って", "言っといて", "と伝え", "って伝え"] + sendWords) {
            return AskIntent(kind: .mood, mood: quoted(text) ?? String(before(text, ["って伝え", "と伝え", "って言っ", "と言っ", "って送っ", "送っといて", "送っておいて"]).prefix(20)))
        }
        if has(["行き方", "どう行", "向かう", "案内して", "のところへ", "道順"]) {
            return AskIntent(kind: .route)
        }
        if has(["買って", "おつかい", "お使い", "買い物", "頼んで"]) {
            return AskIntent(kind: .errand, items: items(in: text))
        }
        if has(["会い", "会う", "待ち合わせ", "中間", "合流"]) {
            return AskIntent(kind: .meet, placeKind: placeWord(in: text) ?? "")
        }
        var query = searchWords(text)
        // 「充電できるカフェ」「静かなカフェ」は、最後の種類の言葉（カフェ）で探す。
        if !isGeneric(query), let kind = genericWords.first(where: { query.hasSuffix($0) }) { query = kind }
        // 「お腹ぺこぺこ、なんか食べたい」は、食べ物の種類が無くても「ごはん」を探す。
        // AIに回すと、おつかいの頼みと取り違えた（10/2 Macで測定）。
        // ただし「一蘭食べたい」のように店の名前があれば、名前のまま探す（10/11 実機：一蘭が「ごはん」に化けた）。
        if !isGeneric(query), has(hungerWords), hungerWords.contains(where: { query.contains($0) }) { query = "ごはん" }
        // 「雨でも静かに作業できるところ」のように種類の言葉が無いときは、条件を探す言葉に言い換える。
        if !isGeneric(query), !AskSkills.conditionWords(text).isEmpty {
            return AskIntent(kind: .place, query: query, words: AskSkills.conditionWords(text))
        }
        return AskIntent(kind: .place, placeKind: placeWord(in: text) ?? "", query: query)
    }

    // MARK: 地図で探す言葉

    /// 頼みの文から、地図で探す言葉だけを取り出す。
    /// 「なんからーめん食べたい」→「ラーメン」、「カラオケ行きたいな」→「カラオケ」、「トイレどこ？」→「トイレ」。
    /// 文のまま探すと、名前が似た遠くの店を選ぶ（9/26 実測：「なんからーめん」→ 955km先の「南香らーめん」、
    /// 「カラオケ行きたい」→ 103km先の店、「ラーメン食べたい」→ 19km先の「えびラーメンと…が食べたい」という店）。
    static func searchWords(_ raw: String) -> String {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "？?！!。、 　"))
        // 「〜食べたい」「〜行きたいな」「〜ある？」「〜どこ」のような言い方の部分を、後ろから落とす。
        for _ in 0..<3 {
            let before = t
            if let r = t.range(of: tailPattern, options: .regularExpression), r.lowerBound > t.startIndex {
                t = String(t[..<r.lowerBound])
            }
            t = t.trimmingCharacters(in: CharacterSet(charactersIn: "？?！!。、 　"))
            if t == before { break }
        }
        // 頭の「なんか」「ちょっと」「近くで」など。
        for lead in leadFillers where t.hasPrefix(lead) && t.count > lead.count {
            t.removeFirst(lead.count)
            break
        }
        if t.hasSuffix("とか"), t.count > 2 { t.removeLast(2) }
        // ひらがなで打った種類の言葉は、カタカナでも見る（「らーめん」→「ラーメン」）。
        if let kata = t.applyingTransform(.hiraganaToKatakana, reverse: false), kata != t, isGeneric(kata) { t = kata }
        return t.isEmpty ? raw : t
    }

    /// 「赤坂駅付近ランチ」→（赤坂駅, ランチ）、「渋谷でラーメン食べたい」→（渋谷, ラーメン）。
    /// 場所の名前と、そのまわりで探すものに分ける。分けられなければ nil。
    static func anchored(_ raw: String) -> (near: String, what: String)? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // ①「〜付近」「〜の近く」「〜周辺」のように、まわりを表す言葉がはっきりあるとき。
        let around = "^(.+?)(の近く|の近所|付近|周辺|のそば|の周り|のまわり|のあたり|あたり|辺り|の辺)(の|で|に|にある)?(.+)$"
        if let m = match(around, text), !m[0].isEmpty {
            let what = searchWords(m[3])
            let place = m[0].trimmingCharacters(in: .whitespaces)
            // 1文字（「この辺」の「こ」）は場所の名前ではない。
            if !what.isEmpty, place.count >= 2, !isFiller(place) { return (place, what) }
        }
        // ②「渋谷でラーメン」「赤坂駅のカフェ」。後ろが種類の言葉のときだけ（「はなと中間で会う」を取り違えない）。
        if let m = match("^(.+?)(で|の)(.+)$", text) {
            let place = m[0].trimmingCharacters(in: .whitespaces)
            let what = searchWords(m[2])
            if place.count >= 2, !isFiller(place), !isGeneric(place), isGeneric(what) { return (place, what) }
        }
        return nil
    }

    /// 「近く」「この辺」のように、場所の名前ではない言葉。
    private static func isFiller(_ word: String) -> Bool {
        ["近く", "この辺", "この近く", "近所", "いちばん近い", "一番近い", "最寄り", "ここ", "いま", "今"]
            .contains(word) || leadFillers.contains(word)
    }

    /// 正規表現に当てて、かっこの中身を順に返す（当たらなければ nil）。
    private static func match(_ pattern: String, _ text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<m.numberOfRanges).map { i in
            Range(m.range(at: i), in: text).map { String(text[$0]) } ?? ""
        }
    }

    private static let tailPattern =
        "(が|を|に|へ|で)?(食べ|たべ|飲み|のみ|行き|いき|歌い|うたい|遊び|あそび|やり|し|寄り|より|休み|やすみ)たい(な|ね|よ|かな|なあ|なー|です|んだけど)?$"
        + "|(とか)?(って)?(ある|ない|どこ|探して|さがして|教えて|おしえて|知りたい|ないかな|あるかな|ないの|あるの)(かな|か)?$"

    private static let leadFillers = ["なんか", "何か", "ちょっと", "今から", "いまから", "これから",
                                      "どこか", "どっか", "近くで", "この辺で", "近くの", "近くに"]

    private static let placeWords = ["カフェ", "喫茶", "ごはん", "ランチ", "食事", "レストラン", "駅", "公園", "コンビニ"]
    /// 「店の前にいるねって送っといて」も、相手に伝える頼み（10/2 Macで測定：AIは待ち合わせと取り違えた）。
    /// 「駅まで送って」（車で送る）と混ざらないよう、「って」付きか「送っといて」だけ。
    static let sendWords = ["って送っ", "送っといて", "送っておいて"]
    /// おなかが空いた言い方。
    static let hungerWords = ["食べたい", "お腹", "おなか", "腹減", "腹へ", "はらへ", "はらぺこ", "腹ぺこ"]
    static let nearbyMarkers = ["近くの", "いちばん近い", "一番近い", "最寄りの", "この辺の", "この辺で"]

    /// 種類の言葉（ある1つの店ではない）。これで探すときは近い順にする。
    static let genericWords = ["カフェ", "喫茶", "コーヒー", "ごはん", "ランチ", "ディナー", "食事", "レストラン",
                               "ラーメン", "そば", "うどん", "寿司", "焼肉", "居酒屋", "ファミレス", "ハンバーガー",
                               "パン", "駅", "コンビニ", "公園", "トイレ", "薬局", "ドラッグストア", "スーパー",
                               "ATM", "銀行", "病院", "本屋", "書店", "ホテル", "駐車場", "駐輪場", "休憩",
                               "カラオケ", "ボウリング", "映画館", "ゲームセンター", "ゲーセン", "ネットカフェ",
                               "漫画喫茶", "銭湯", "サウナ", "ジム", "牛丼", "カレー", "ピザ", "焼き鳥", "中華",
                               "餃子", "とんかつ", "ケーキ", "スイーツ", "バー",
                               "コワーキングスペース", "図書館", "ファストフード", "ショッピングモール", "美術館", "博物館"]

    /// 言葉そのもの（「カフェ」「ラーメン屋」）のときだけ。「東京駅」は駅という種類ではなく
    /// 1つの場所なので、末尾が「駅」でも種類とはみなさない（近くの別の駅を選んでいた）。
    static func isGeneric(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        return genericWords.contains { w in [w, w + "屋", w + "屋さん", w + "店", w + "場"].contains(q) }
    }

    /// 行き先。「ラゾーナに案内して」→「ラゾーナ」。
    private static func destination(in text: String) -> String? {
        // 「ドンキまで道案内お願い」も（10/2 Macで測定：たぬきへの行き方と取り違えた）。
        let pattern = "^(.+?)(に|まで|へ)(道案内|案内|連れて|行きたい|行こう|行って|行く|向かいたい)"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range(at: 1), in: text) else { return nil }
        var dest = String(text[r]).trimmingCharacters(in: .whitespaces)
        for lead in ["今から", "いまから", "これから"] where dest.hasPrefix(lead) { dest.removeFirst(lead.count) }
        return dest.isEmpty ? nil : dest
    }

    private static func placeWord(in text: String) -> String? {
        placeWords.first { text.contains($0) }
    }

    /// 「」の中身。
    private static func quoted(_ text: String) -> String? {
        guard let open = text.firstIndex(of: "「"), let close = text[open...].firstIndex(of: "」") else { return nil }
        let inner = text[text.index(after: open)..<close]
        return inner.isEmpty ? nil : String(inner.prefix(20))
    }

    private static func before(_ text: String, _ marks: [String]) -> String {
        for mark in marks {
            if let r = text.range(of: mark) { return String(text[..<r.lowerBound]) }
        }
        return text
    }

    /// 「帰りに牛乳と卵を買ってきて」→ [牛乳, 卵]
    private static func items(in text: String) -> [String] {
        var body = before(text, ["を買って", "買ってきて", "を頼", "買って", "を買い"])
        for lead in ["帰りに", "ついでに", "あとで", "今日", "いま", "おつかい", "お使い", "で", "に"] where body.hasPrefix(lead) {
            body.removeFirst(lead.count)
        }
        if let r = body.range(of: "に", options: .backwards), body.distance(from: body.startIndex, to: r.lowerBound) <= 4 {
            body = String(body[r.upperBound...])   // 「はなに牛乳と卵」→「牛乳と卵」
        }
        let parts = body.components(separatedBy: CharacterSet(charactersIn: "、,と・&＆ "))
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && $0.count <= 12 }
    }

    /// 場所の種類の言葉を、地図の分類にする。
    static func categories(for word: String) -> [MKPointOfInterestCategory]? {
        switch word {
        case let w where w.contains("カフェ") || w.contains("喫茶"): return [.cafe]
        case let w where w.contains("ごはん") || w.contains("ランチ") || w.contains("食事") || w.contains("レストラン"):
            return [.restaurant]
        case let w where w.contains("駅"): return [.publicTransport]
        case let w where w.contains("公園"): return [.park]
        default: return nil
        }
    }
}

#if canImport(FoundationModels)
@available(iOS 26.0, *)
@Generable
struct AskPlanAI {
    @Guide(description: "操作の種類", .anyOf(["meet", "errand", "mood", "route", "place"]))
    var kind: String
    @Guide(description: "待ち合わせや探す場所の種類。例: カフェ、駅、公園、ごはん。文に無ければ空文字")
    var placeKind: String
    @Guide(description: "errand のときの品物の名前だけ。例: 牛乳、卵。それ以外は空の配列")
    var items: [String]
    @Guide(description: "mood のときに相手に伝える一言（20文字以内）。それ以外は空文字")
    var mood: String
    @Guide(description: "place のときに探す言葉。例: 近くのカフェ、東京駅。それ以外は空文字")
    var query: String
}
#endif

// MARK: - AIに頼めること（9/28 本人が6つとも選んだ）

/// 一文から「何を・いつまで・何分」を取り出す部分。どれも言葉の決まりで決める（小さいAIに任せない）。
/// 形は Googleマップ「マップに相談」・Gemini のナビ・Life360 の No Show・Yelp Assistant の頼まれ方から借りた。
enum AskSkills {

    // MARK: ふわっとした条件 → 探す言葉

    /// 「雨でも静かに作業できるところ」→ [カフェ, 図書館, コワーキングスペース]。当てはまらなければ空。
    static func conditionWords(_ text: String) -> [String] {
        func has(_ w: [String]) -> Bool { w.contains { text.contains($0) } }
        var out: [String] = []
        func add(_ w: [String]) { for x in w where !out.contains(x) { out.append(x) } }
        if has(["作業", "勉強", "仕事", "パソコン", "PC", "Wi-Fi", "WiFi", "wifi", "ワイファイ", "電源", "充電"]) {
            add(has(["静か"]) ? ["図書館", "カフェ", "コワーキングスペース"] : ["カフェ", "コワーキングスペース", "図書館"])
        }
        if has(["子連れ", "子ども", "子供", "ベビーカー", "キッズ", "赤ちゃん"]) { add(["ファミレス", "ショッピングモール", "公園"]) }
        if has(["休憩", "休みたい", "座りたい", "一息", "ひと息", "涼み", "暖まり", "温まり"]) {
            add(has(["雨", "寒", "暑", "涼", "暖", "温"]) ? ["カフェ", "ファミレス"] : ["カフェ", "公園", "ファミレス"])
        }
        if has(["飲みたい", "飲める", "お酒", "一杯"]) { add(["居酒屋", "バー"]) }
        if has(["安く", "安い", "さくっと", "サクッと", "手軽", "すぐ食べ"]) { add(["牛丼", "ファストフード", "うどん"]) }
        if has(["デート", "おしゃれ", "雰囲気"]) { add(["カフェ", "レストラン"]) }
        if has(["静か"]), out.isEmpty { add(["カフェ", "図書館"]) }
        if has(["雨"]), out.isEmpty { add(["カフェ", "ショッピングモール", "本屋"]) }
        return Array(out.prefix(3))
    }

    // MARK: 見張る（締め切り）

    /// 「7時までに」「19時半までに」「30分たっても」「1時間以内に」→ 締め切りの時刻。読めなければ nil。
    /// 「7時」は、いまより後でいちばん近い7時（朝7時を過ぎていれば夜7時）。
    static func deadline(in text: String, now: Date = Date(), calendar: Calendar = .current) -> Date? {
        let t = text.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? text
        if let m = firstMatch("([0-9]+)\\s*分(たって|経って|後|以内|しても|過ぎても)", t), let n = Int(m[0]) {
            return now.addingTimeInterval(TimeInterval(n * 60))
        }
        if let m = firstMatch("([0-9]+)\\s*時間(たって|経って|後|以内|しても|過ぎても)", t), let n = Int(m[0]) {
            return now.addingTimeInterval(TimeInterval(n * 3600))
        }
        guard let m = firstMatch("([0-9]{1,2})\\s*時\\s*(半|([0-9]{1,2})\\s*分)?", t), var hour = Int(m[0]), hour < 24 else { return nil }
        let minute = m[1] == "半" ? 30 : (Int(m[2]) ?? 0)
        if t.contains("午後") || t.contains("夜"), hour < 12 { hour += 12 }
        var day = calendar.dateComponents([.year, .month, .day], from: now)
        day.hour = hour
        day.minute = minute
        guard var date = calendar.date(from: day) else { return nil }
        // 過ぎていれば、12時間後（夜の7時）→ それも過ぎていれば翌日。
        if date <= now, hour < 12, let pm = calendar.date(byAdding: .hour, value: 12, to: date), pm > now { date = pm }
        if date <= now, let next = calendar.date(byAdding: .day, value: 1, to: date) { date = next }
        return date
    }

    // MARK: 時間つぶし

    /// 「2時間どうする」「30分ひまつぶし」「1時間半あいた」→ 分。時間つぶしの頼みでなければ nil。
    static func freeMinutes(in text: String) -> Int? {
        let t = text.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? text
        let asks = ["時間つぶ", "ひまつぶ", "暇つぶ", "ヒマつぶ", "どうする", "何しよ", "なにしよ", "空いた", "あいた", "空いてる",
                    "あいてる", "ひま", "暇", "時間ある", "時間がある"]
        guard asks.contains(where: { t.contains($0) }) else { return nil }
        // 「10分遅れるけどどうする」は時間つぶしではない。
        guard !["遅れ", "遅刻", "伝え", "着く", "来る"].contains(where: { t.contains($0) }) else { return nil }
        var minutes = 0
        if let m = firstMatch("([0-9]+)\\s*時間(半)?", t), let h = Int(m[0]) { minutes += h * 60 + (m[1] == "半" ? 30 : 0) }
        if let m = firstMatch("([0-9]+)\\s*分", t), let n = Int(m[0]) { minutes += n }
        if minutes == 0, ["時間つぶ", "ひまつぶ", "暇つぶ", "ヒマつぶ"].contains(where: { t.contains($0) }) { minutes = 60 }
        return minutes > 0 ? minutes : nil
    }

    /// 空いた時間の長さで、行く所の種類を変える（短ければ近場で座れる所、長ければ映画・美術館など）。
    static func killTimePlan(minutes: Int) -> [String] {
        switch minutes {
        case ..<45: return ["カフェ", "本屋", "公園"]
        case ..<120: return ["カフェ", "本屋", "ショッピングモール", "公園"]
        default: return ["映画館", "美術館", "カラオケ", "ショッピングモール", "カフェ"]
        }
    }

    // MARK: 寄り道

    /// 「途中でコーヒー買える所」→「コーヒー」、「駅に行く途中で寄れるコンビニ」→「コンビニ」。
    static func onTheWayWhat(_ text: String) -> String {
        var t = text
        if let r = t.range(of: "途中で") ?? t.range(of: "途中に") ?? t.range(of: "道中") ?? t.range(of: "寄り道") {
            t = String(t[r.upperBound...])
        }
        for w in ["寄れる", "寄って", "ついでに寄", "買える", "食べられる", "飲める", "で", "に", "の"] where t.hasPrefix(w) {
            t.removeFirst(w.count)
        }
        for tail in ["買える所", "買えるところ", "買える場所", "寄れる所", "寄れるところ", "ある所", "あるところ", "ところ", "所", "場所"]
            where t.hasSuffix(tail) && t.count > tail.count {
            t.removeLast(tail.count)
        }
        t = t.replacingOccurrences(of: "寄れる", with: "").replacingOccurrences(of: "買える", with: "")
        return AskParser.searchWords(t)
    }

    // MARK: 店のことを聞く

    /// 何を聞いているか。exit / hours / phone / site。店のことを聞いていなければ nil。
    static func placeTopic(_ text: String) -> String? {
        if ["何番出口", "どの出口", "出口", "どこから出"].contains(where: { text.contains($0) }) { return "exit" }
        if ["何時まで", "何時から", "営業時間", "開いてる", "空いてる？", "やってる", "閉まる", "何時に開"].contains(where: { text.contains($0) }) {
            return "hours"
        }
        if ["電話番号", "電話したい", "予約"].contains(where: { text.contains($0) }) { return "phone" }
        if ["ホームページ", "サイト", "メニュー"].contains(where: { text.contains($0) }) { return "site" }
        return nil
    }

    /// 「スタバって何時まで？」→「スタバ」、「そこ何時まで」→ 空（いま見ている場所）。
    static func placeInfoTarget(_ text: String) -> String {
        var t = text
        for mark in ["って", "は", "の", "何時", "営業", "開い", "やって", "電話", "予約", "ホームページ", "サイト", "メニュー", "閉ま",
                     "何番", "どの出口", "出口", "から出", "に行くには", "へ行くには"] {
            if let r = t.range(of: mark) { t = String(t[..<r.lowerBound]) }
        }
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        return ["そこ", "ここ", "あそこ", "その店", "このお店", "その店舗", "待ち合わせ"].contains(t) ? "" : t
    }

    // MARK: 遅れる連絡

    /// 相手に送る一言。到着予定（分）が出せれば入れる。「10分遅れる」のように数があれば、それも残す。
    static func lateMessage(_ text: String, etaMinutes: Int?) -> String {
        let t = text.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? text
        let said = firstMatch("([0-9]+)\\s*分", t).flatMap { Int($0[0]) }
        let late = ["遅れ", "遅刻", "間に合わ"].contains { t.contains($0) }
        switch (late, said, etaMinutes) {
        case (true, let n?, let eta?): return "\(n)分ほど遅れます（あと\(eta)分で着きます）"
        case (true, nil, let eta?): return "少し遅れます。あと\(eta)分で着きます"
        case (true, let n?, nil): return "\(n)分ほど遅れます"
        case (true, nil, nil): return "少し遅れます"
        case (false, _, let eta?): return "あと\(eta)分で着きます"
        case (false, _, nil): return "向かっています"
        }
    }

    /// 遅れる・もうすぐ着く、の連絡か（到着予定を入れる対象か）。
    static func isArrivalNote(_ text: String) -> Bool {
        ["遅れ", "遅刻", "間に合わ", "着く", "着きそう", "向かって", "向かう", "もうすぐ"].contains { text.contains($0) }
    }

    // MARK: 道のりの計算

    /// 点から、道（折れ線）までのいちばん近い距離（m）。
    static func distance(from p: MKMapPoint, toPath path: [MKMapPoint]) -> Double {
        guard path.count >= 2 else { return path.first.map { p.distance(to: $0) } ?? .greatestFiniteMagnitude }
        var best = Double.greatestFiniteMagnitude
        for i in 0..<(path.count - 1) {
            let a = path[i], b = path[i + 1]
            let dx = b.x - a.x, dy = b.y - a.y
            let len2 = dx * dx + dy * dy
            let u = len2 == 0 ? 0 : max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
            let q = MKMapPoint(x: a.x + u * dx, y: a.y + u * dy)
            best = min(best, p.distance(to: q))
        }
        return best
    }

    /// 寄り道でふえる距離（m）：自分→店→行き先 − 自分→行き先。
    static func detour(me: MKMapPoint, stop: MKMapPoint, destination: MKMapPoint) -> Double {
        me.distance(to: stop) + stop.distance(to: destination) - me.distance(to: destination)
    }

    private static func firstMatch(_ pattern: String, _ text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<m.numberOfRanges).map { i in Range(m.range(at: i), in: text).map { String(text[$0]) } ?? "" }
    }
}

// MARK: - 先回り（頼まなくても提案する）
//
// Muse の「頼まなくても状況を見て提案し、決めるのは人」の形（本人 9/25「3も一緒に」）。
// 何を出すかは観測できる事実だけで決める純粋な関数。AIには判断させない
// （小さいモデルに「状況を判断して」は筋が悪い。Jevで測った教訓）。

struct Suggestion: Equatable {
    enum Kind: String { case errandStore, earlyArrival, decideMeet, quake, warning }
    var kind: Kind
    var title: String
    var detail: String
    var primary: String
}

struct ProactiveState {
    var partner: String
    var connected: Bool
    var me: CLLocation?
    var peer: CLLocation?
    /// 相手の居場所が何秒前のものか。古ければ何も言わない。
    var peerAge: TimeInterval
    /// 相手のそばの店と、相手からの距離（m）。
    var store: (name: String, metres: Double)?
    var errandActive: Bool
    var pin: (name: String, coordinate: CLLocationCoordinate2D)?
    /// 電波が届くほど近い（もう「探す」の出番。提案は黙る）。
    var radioNear: Bool
}

enum Proactive {
    private static let key = "kokodayo.proactive"

    /// ⋯ の「先回りの提案」。はじめは入。
    static var isOn: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// 歩いて何分か。道は直線より長いので1.25倍、分速80m（地図の画面と同じ値）。
    static func walkMinutes(_ metres: Double) -> Int { max(1, Int((metres * 1.25 / 80).rounded())) }

    /// いま出す提案を1つ。上から順に、当てはまった最初のもの。
    static func decide(_ s: ProactiveState) -> Suggestion? {
        guard s.connected, let me = s.me, let peer = s.peer, s.peerAge < 180, !s.radioNear else { return nil }
        // ① 相手が店の前（60m以内）で、おつかいを頼んでいない
        if !s.errandActive, let store = s.store, store.metres <= 60 {
            return Suggestion(kind: .errandStore,
                              title: "\(s.partner)がいま「\(store.name)」の前です",
                              detail: "ついでに何か頼みますか？", primary: "頼む")
        }
        // ② 待ち合わせ場所に、自分が8分以上先に着きそう
        if let pin = s.pin {
            let spot = CLLocation(latitude: pin.coordinate.latitude, longitude: pin.coordinate.longitude)
            let mine = walkMinutes(me.distance(from: spot))
            let theirs = walkMinutes(peer.distance(from: spot))
            if theirs - mine >= 8, mine <= 30 {
                return Suggestion(kind: .earlyArrival,
                                  title: "あなたが\(theirs - mine)分ほど先に着きそうです",
                                  detail: "\(pin.name)まで あなた約\(mine)分・\(s.partner)約\(theirs)分。まわりで待てる場所を見ますか？",
                                  primary: "まわりを見る")
            }
        }
        // ③ 1.5km以内まで来たのに、どこで会うか決まっていない
        let apart = me.distance(from: peer)
        if s.pin == nil, apart <= 1_500, apart >= 200 {
            return Suggestion(kind: .decideMeet,
                              title: "\(s.partner)まで あと\(NearbyAlert.text(apart))です",
                              detail: "どこで会うか決めておきますか？（2人の真ん中から探します）",
                              primary: "決める")
        }
        return nil
    }
}

// MARK: - 場所の名前から、その場所を1つ決める

/// 「ラゾーナ」で探すと、地図の検索は中のお店を25件返し、施設そのもの（ラゾーナ川崎
/// プラザ）は入っていなかった。近い順に並べていたので、隣の「ミューザ川崎駐車場」を
/// 選んでいた（本人 9/25「ラゾーナに案内してって言ったらミューザに案内した」）。
/// データはあった。選び方が悪かった。
/// 名前で探すときは、Appleマップと同じく入力候補（MKLocalSearchCompleter）の
/// 1つ目を使う。「カフェ」のような種類の言葉なら、これまでどおり近い順。
/// 入力候補は、頼んだスレッドの run loop に返事を返す。メインで頼まないと返事が
/// 来ず、4秒待って空で終わっていた（Macで測って分かった）。だから丸ごとメインで動かす。
@MainActor
final class PlaceResolver: NSObject, MKLocalSearchCompleterDelegate {
    private let completer = MKLocalSearchCompleter()
    private var waiting: CheckedContinuation<[MKLocalSearchCompletion], Never>?

    func resolve(_ query: String, near me: CLLocation) async -> [MKMapItem] {
        if AskParser.isGeneric(query) { return await nearest(query, near: me) }
        completer.delegate = self
        // 「近くを検索」のような候補を混ぜると、それが1つ目に来て施設を取り逃がした。
        completer.resultTypes = [.pointOfInterest, .address]
        completer.region = MKCoordinateRegion(center: me.coordinate, latitudinalMeters: 5000, longitudinalMeters: 5000)
        let completions: [MKLocalSearchCompletion] = await withCheckedContinuation { k in
            waiting = k
            completer.queryFragment = query
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.finish([]) }
        }
        // 上から3つまで見て、3km以内に入る最初のものを採る。チェーン店（「スタバ」）は
        // 1つ目が遠くの有名店（目黒のロースタリー）になり、近くの店を取り逃がしていた。
        // どれも遠ければ1つ目（「東京駅」のような、遠くても行きたい1つの場所）。
        var firstItem: MKMapItem?
        for completion in completions.prefix(3) {
            guard let response = try? await MKLocalSearch(request: MKLocalSearch.Request(completion: completion)).start(),
                  let item = response.mapItems.first else { continue }
            if firstItem == nil { firstItem = item }
            if let loc = item.placemark.location, loc.distance(from: me) <= 3_000 { return [item] }
        }
        if let firstItem {
            // 1つ目が30kmより遠く、近くに同じ言葉の場所があれば、近いほうを採る。
            // （「東京駅」のように遠くても行きたい1つの場所は、近くに同じ名前が無いのでそのまま）
            if let d = firstItem.placemark.location?.distance(from: me), d > 30_000,
               let near = await nearest(query, near: me).first,
               let nd = near.placemark.location?.distance(from: me), nd <= 5_000 {
                return [near]
            }
            return [firstItem]
        }
        return await nearest(query, near: me)
    }

    /// 候補をいくつか（Appleマップの検索結果のように）。center のまわりで探し、近い順。
    /// 種類の言葉（ラーメン・カフェ）は近い順にそのまま。名前（スタバ・ラゾーナ）は、
    /// いちばん当てはまる1つを先頭に、同じ言葉で見つかったほかの場所を後ろに足す。
    /// openData: Appleマップが取りこぼす店を OpenPOI API で足す（店の名前に入る種類の言葉のときだけ）。
    /// 足すのは出典を出せる画面（「AIに頼む」の候補一覧）だけ。
    func resolveMany(_ query: String, near center: CLLocation, limit: Int = 5,
                     openData: Bool = false) async -> [MKMapItem] {
        let useOpen = openData && OpenPOI.usable(for: query)
        async let openHits: [OpenPOI.Hit] = useOpen ? OpenPOI.search(query, near: center) : []
        // まわりで探した結果でも、5kmより遠いものは並べない（51km先のうどん屋が出ていた）。
        var around = await nearest(query, near: center).filter {
            ($0.placemark.location?.distance(from: center) ?? .greatestFiniteMagnitude) <= 5_000
        }
        if useOpen {
            let known = around.compactMap { item in
                item.placemark.location.map { (name: item.name ?? "", location: $0) }
            }
            let extra = await openHits.filter { !OpenPOI.isDuplicate($0, of: known) }.map(OpenPOI.mapItem)
            around = (around + extra).sorted {
                ($0.placemark.location?.distance(from: center) ?? .greatestFiniteMagnitude)
                    < ($1.placemark.location?.distance(from: center) ?? .greatestFiniteMagnitude)
            }
        }
        if AskParser.isGeneric(query) { return Array(around.prefix(limit)) }
        let best = await resolve(query, near: center)
        var out = best
        for item in around where out.count < limit {
            let dup = out.contains { a in
                guard let p = a.placemark.location, let q = item.placemark.location else { return false }
                return p.distance(from: q) < 50 || a.name == item.name
            }
            if !dup { out.append(item) }
        }
        return out
    }

    private func nearest(_ query: String, near me: CLLocation) async -> [MKMapItem] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.region = MKCoordinateRegion(center: me.coordinate, latitudinalMeters: 3000, longitudinalMeters: 3000)
        let items = (try? await MKLocalSearch(request: request).start())?.mapItems ?? []
        return items.sorted {
            ($0.placemark.location?.distance(from: me) ?? .greatestFiniteMagnitude)
                < ($1.placemark.location?.distance(from: me) ?? .greatestFiniteMagnitude)
        }
    }

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) { finish(completer.results) }
    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) { finish([]) }

    private func finish(_ results: [MKLocalSearchCompletion]) {
        waiting?.resume(returning: results)
        waiting = nil
    }
}

// MARK: - 考えている玉

/// 考えている印。手描きの玉はやめて、SF Symbols の ✨ と iOS 標準の
/// アニメーション（variableColor）を使う（本人 9/25「デザインは自前しないで」）。
final class OrbView: UIView {
    private let symbol = UIImageView(image: UIImage(systemName: "sparkles"))

    override init(frame: CGRect) {
        super.init(frame: frame)
        symbol.tintColor = .systemPurple
        symbol.contentMode = .scaleAspectFit
        symbol.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold)
        addSubview(symbol)
        symbol.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            symbol.topAnchor.constraint(equalTo: topAnchor),
            symbol.bottomAnchor.constraint(equalTo: bottomAnchor),
            symbol.leadingAnchor.constraint(equalTo: leadingAnchor),
            symbol.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setThinking(_ on: Bool) {
        guard #available(iOS 17.0, *) else { return }
        if on {
            symbol.addSymbolEffect(.variableColor.iterative.reversing)
        } else {
            symbol.removeAllSymbolEffects()
        }
    }
}

// MARK: - 最近頼んだこと

/// 「AIに頼む」で最近頼んだ文。この端末の中だけに残す（新しい順・同じ文は1つ）。
/// Appleマップの検索画面の「最近」と同じ考え方。
enum AskHistory {
    private static let key = "kokodayo.askHistory"
    static let capacity = 8

    static var items: [String] {
        get { UserDefaults.standard.stringArray(forKey: key) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    static func record(_ text: String) { items = adding(text, to: items) }
    static func remove(_ text: String) { items = items.filter { $0 != text } }
    static func clear() { items = [] }

    /// 新しい文を先頭に。前にもあれば先頭へ移す。空白だけの文は足さない。あふれた古いものは落とす。
    static func adding(_ text: String, to list: [String], capacity: Int = capacity) -> [String] {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return list }
        return Array(([t] + list.filter { $0 != t }).prefix(capacity))
    }

    /// 見せる分。いま候補のボタンに出ている文は重ねて出さない。
    static func shown(_ list: [String], excluding chips: [String], max: Int = 5) -> [String] {
        Array(list.filter { !chips.contains($0) }.prefix(max))
    }
}

// MARK: - 1回分の頼みごと

/// 1回分の頼みごと。画面への書き込みはここを通す。止めたあと・次を頼んだあとに
/// 遅れて届いた結果（通信やAIの返事）は、画面に出さない。
@MainActor
final class AskRun {
    private weak var ui: AskViewController?
    private let id: Int

    init(ui: AskViewController, id: Int) {
        self.ui = ui
        self.id = id
    }

    /// まだこの頼みごとが画面に出ているか。
    var isLive: Bool { ui?.currentRun == id }

    @discardableResult
    func addStep(_ text: String) -> Int {
        guard isLive, let ui else { return -1 }
        return ui.addStep(text)
    }

    func finishStep(_ index: Int, note: String? = nil, failed: Bool = false) {
        guard isLive else { return }
        ui?.finishStep(index, note: note, failed: failed)
    }

    func ask(title: String, detail: String?, primary: String, secondary: String?,
             onPrimary: @escaping () -> Void, onSecondary: (() -> Void)?) {
        guard isLive else { return }
        ui?.ask(title: title, detail: detail, primary: primary, secondary: secondary,
                onPrimary: onPrimary, onSecondary: onSecondary)
    }

    func finish(_ text: String, ok: Bool = true) {
        guard isLive else { return }
        ui?.finish(text, ok: ok)
    }

    func choose(title: String, rows: [(title: String, detail: String)], credit: Bool = false,
                onPick: @escaping (Int) -> Void) {
        guard isLive else { return }
        ui?.choose(title: title, rows: rows, credit: credit, onPick: onPick)
    }

    func dismiss(animated: Bool, completion: (() -> Void)? = nil) {
        guard isLive, let ui else { return }
        ui.dismiss(animated: animated, completion: completion)
    }
}

// MARK: - 頼む画面

/// 一文を打つ（声でもいい。キーボードのマイク）→ 手順が1行ずつ進む → 送る前に確認の札。
final class AskViewController: UIViewController, UITextFieldDelegate, MKLocalSearchCompleterDelegate {

    var onSubmit: ((String) -> Void)?
    private let suggestions: [String]

    private let orb = OrbView()
    private let field = UITextField()
    private let chips = WrappingRow()
    private let recents = UIStackView()
    private let stopButton = UIButton(type: .system)
    /// いま画面に出している頼みごとの番号。止める・次を頼むと進み、前の頼みごとの遅い返事は捨てる。
    private(set) var currentRun = 0
    private let modeLabel = UILabel()
    private let titleLabel = UILabel()
    private let steps = UIStackView()
    private let card = UIStackView()
    private var stepRows: [(icon: UIImageView, label: UILabel)] = []

    /// 打っているあいだに出す場所の候補（🔍の検索をここにまとめた。10/3 本人「まとめて」）。
    /// 候補を押せば場所の札、決定キーならAIが一文として読む。
    private let places = UIStackView()
    private let completer = MKLocalSearchCompleter()
    private var placeResults: [MKLocalSearchCompletion] = []
    private let near: CLLocation?
    /// 候補の場所が選ばれた（閉じてから札を出す）。
    var onPickPlace: ((MKMapItem) -> Void)?

    init(suggestions: [String], near: CLLocation? = nil) {
        self.near = near
        self.suggestions = suggestions
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = MeetPalette.background

        field.placeholder = "例: はなと中間で会いたい、カフェで"
        field.attributedPlaceholder = NSAttributedString(string: field.placeholder ?? "",
                                                         attributes: [.foregroundColor: MeetPalette.secondary])
        field.textColor = MeetPalette.primary
        field.font = Type.font(17, .regular, .body)
        field.backgroundColor = MeetPalette.raised
        field.layer.cornerRadius = 14
        field.returnKeyType = .go
        field.delegate = self
        field.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 12, height: 1))
        field.leftViewMode = .always
        field.clearButtonMode = .whileEditing
        field.heightAnchor.constraint(equalToConstant: 48).isActive = true

        orb.translatesAutoresizingMaskIntoConstraints = false
        orb.widthAnchor.constraint(equalToConstant: 30).isActive = true
        orb.heightAnchor.constraint(equalToConstant: 30).isActive = true
        // 調べているあいだは右に「止める」（ChatGPT・Claude の ■ と同じ）。止めても、別の文を送り直してもいい。
        stopButton.setImage(UIImage(systemName: "stop.circle.fill",
                                    withConfiguration: UIImage.SymbolConfiguration(pointSize: 28)), for: .normal)
        stopButton.tintColor = MeetPalette.primary
        stopButton.accessibilityLabel = "止める"
        stopButton.isHidden = true
        stopButton.addAction(UIAction { [weak self] _ in self?.stop() }, for: .touchUpInside)
        stopButton.translatesAutoresizingMaskIntoConstraints = false
        stopButton.widthAnchor.constraint(equalToConstant: 36).isActive = true
        stopButton.heightAnchor.constraint(equalToConstant: 36).isActive = true
        stopButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        let inputRow = UIStackView(arrangedSubviews: [orb, field, stopButton])
        inputRow.axis = .horizontal
        inputRow.alignment = .center
        inputRow.spacing = 10

        modeLabel.font = Type.caption
        modeLabel.textColor = MeetPalette.secondary
        modeLabel.numberOfLines = 2
        modeLabel.text = AskParser.aiAvailable
            ? "iPhoneの中のAIで読みます。送る前には必ず確かめます"
            : "かんたんな読み方で読みます（この端末ではAIが使えません）。送る前には必ず確かめます"

        chips.spacing = 8
        chips.lineSpacing = 8
        for text in suggestions {
            var conf = UIButton.Configuration.filled()
            conf.title = text
            conf.baseBackgroundColor = MeetPalette.surface
            conf.baseForegroundColor = MeetPalette.primary
            conf.cornerStyle = .capsule
            conf.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14)
            conf.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in
                var a = attrs
                a.font = Type.font(14, .regular, .body)
                return a
            }
            let button = CapsuleButton(type: .system)
            button.configuration = conf
            button.addAction(UIAction { [weak self] _ in
                self?.field.text = text
                self?.submit()
            }, for: .touchUpInside)
            chips.addSubview(button)
        }

        titleLabel.font = Type.font(17, .bold, .headline)
        titleLabel.textColor = MeetPalette.primary
        titleLabel.numberOfLines = 2
        titleLabel.isHidden = true
        steps.axis = .vertical
        steps.spacing = 8
        card.axis = .vertical
        card.spacing = 8
        card.isLayoutMarginsRelativeArrangement = true
        card.layoutMargins = UIEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        card.backgroundColor = MeetPalette.surface
        card.layer.cornerRadius = 16
        card.layer.borderWidth = 1
        card.layer.borderColor = UIColor(red: 0.43, green: 0.36, blue: 1, alpha: 0.9).cgColor
        card.isHidden = true

        recents.axis = .vertical
        recents.spacing = 0
        reloadRecents()

        places.axis = .vertical
        places.spacing = 0
        places.isHidden = true
        completer.delegate = self
        completer.resultTypes = [.pointOfInterest, .address]
        if let near {
            completer.region = MKCoordinateRegion(center: near.coordinate,
                                                  latitudinalMeters: 5000, longitudinalMeters: 5000)
        }
        field.addTarget(self, action: #selector(fieldChanged), for: .editingChanged)

        // 結果（題・手順・確かめる札）を上に、候補と最近頼んだことをその下に。
        // 候補が上にあると、終わったときに結果が画面の外へ押し出される（9/26）。
        let column = UIStackView(arrangedSubviews: [inputRow, places, modeLabel, titleLabel, steps, card, chips, recents])
        column.axis = .vertical
        column.spacing = 12
        column.setCustomSpacing(6, after: inputRow)
        column.setCustomSpacing(16, after: card)
        column.setCustomSpacing(16, after: steps)
        column.setCustomSpacing(16, after: chips)
        let scroll = UIScrollView()
        scroll.keyboardDismissMode = .interactive
        scroll.addSubview(column)
        view.addSubview(scroll)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        column.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 18),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            column.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            column.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
            column.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 20),
            column.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -20),
        ])
    }

    /// キーボードは板と一緒に上がってくる（出きってからだと、打てるまで一拍おそい）。
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if titleLabel.isHidden { field.becomeFirstResponder() }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if titleLabel.isHidden, !field.isFirstResponder { field.becomeFirstResponder() }
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        submit()
        return true
    }

    // MARK: 打っているあいだの場所の候補

    @objc private func fieldChanged() {
        let text = (field.text ?? "").trimmingCharacters(in: .whitespaces)
        // 頼みごとを進めているあいだは、候補を出さない（結果の上に被せない）。
        guard titleLabel.isHidden, !text.isEmpty else {
            completer.cancel()
            showPlaces([])
            return
        }
        completer.queryFragment = text
    }

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        guard titleLabel.isHidden, !(field.text ?? "").isEmpty else { return }
        showPlaces(Array(completer.results.prefix(5)))
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {}

    /// 候補を並べる。打っているあいだは、例と最近頼んだことを隠す（Googleマップと同じ）。
    private func showPlaces(_ results: [MKLocalSearchCompletion]) {
        placeResults = results
        places.arrangedSubviews.forEach { $0.removeFromSuperview() }
        places.isHidden = results.isEmpty
        let typing = !(field.text ?? "").isEmpty
        if titleLabel.isHidden {
            chips.isHidden = typing
            recents.isHidden = typing || AskHistory.shown(AskHistory.items, excluding: suggestions).isEmpty
        }
        for (index, r) in results.enumerated() {
            var conf = UIButton.Configuration.plain()
            conf.title = r.title
            conf.subtitle = r.subtitle.isEmpty ? nil : r.subtitle
            conf.image = UIImage(systemName: "mappin.circle.fill")
            conf.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 20)
            conf.imagePadding = 12
            conf.baseForegroundColor = MeetPalette.primary
            conf.imageColorTransformer = UIConfigurationColorTransformer { _ in MeetPalette.action }
            conf.titleLineBreakMode = .byTruncatingTail
            conf.subtitleLineBreakMode = .byTruncatingTail
            conf.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 0, bottom: 10, trailing: 0)
            conf.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in
                var a = attrs
                a.font = Type.font(16, .semibold, .body)
                return a
            }
            conf.subtitleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in
                var a = attrs
                a.font = Type.caption
                a.foregroundColor = MeetPalette.secondary
                return a
            }
            let row = UIButton(configuration: conf)
            row.contentHorizontalAlignment = .leading
            row.addAction(UIAction { [weak self] _ in self?.pickPlace(at: index) }, for: .touchUpInside)
            places.addArrangedSubview(row)
        }
    }

    private func pickPlace(at index: Int) {
        guard placeResults.indices.contains(index) else { return }
        // 閉じるのと、場所を引くのを同時に（通信を待ってから閉じると、押してから間が空く）。
        let onPick = onPickPlace
        MKLocalSearch(request: MKLocalSearch.Request(completion: placeResults[index])).start { response, _ in
            guard let item = response?.mapItems.first else { return }
            onPick?(item)
        }
        dismiss(animated: true)
    }

    private func submit() {
        let text = (field.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        completer.cancel()
        showPlaces([])
        field.resignFirstResponder()
        AskHistory.record(text)
        onSubmit?(text)
    }

    // MARK: 最近頼んだこと

    /// 見出し（右に「消去」）と、押せばもう一度頼める行。長押しで1つずつ消せる。
    private func reloadRecents() {
        recents.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let list = AskHistory.shown(AskHistory.items, excluding: suggestions)
        recents.isHidden = list.isEmpty
        guard !list.isEmpty else { return }

        let header = UILabel()
        header.font = Type.font(15, .semibold, .subheadline)
        header.textColor = MeetPalette.secondary
        header.text = "最近頼んだこと"
        var clearConf = UIButton.Configuration.plain()
        clearConf.title = "消去"
        clearConf.baseForegroundColor = MeetPalette.action
        clearConf.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 0)
        let clear = UIButton(configuration: clearConf)
        clear.addAction(UIAction { [weak self] _ in
            AskHistory.clear()
            self?.reloadRecents()
        }, for: .touchUpInside)
        let headerRow = UIStackView(arrangedSubviews: [header, clear])
        headerRow.axis = .horizontal
        headerRow.alignment = .center
        recents.addArrangedSubview(headerRow)

        for text in list {
            var conf = UIButton.Configuration.plain()
            conf.title = text
            conf.image = UIImage(systemName: "clock.arrow.circlepath")
            conf.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 15)
            conf.imagePadding = 12
            conf.baseForegroundColor = MeetPalette.primary
            conf.imageColorTransformer = UIConfigurationColorTransformer { _ in MeetPalette.secondary }
            conf.titleLineBreakMode = .byTruncatingTail
            conf.contentInsets = NSDirectionalEdgeInsets(top: 11, leading: 0, bottom: 11, trailing: 0)
            conf.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in
                var a = attrs
                a.font = Type.font(16, .regular, .body)
                return a
            }
            let row = UIButton(configuration: conf)
            row.contentHorizontalAlignment = .leading
            row.accessibilityHint = "もう一度頼みます"
            row.addAction(UIAction { [weak self] _ in
                self?.field.text = text
                self?.submit()
            }, for: .touchUpInside)
            row.menu = UIMenu(children: [
                UIAction(title: "履歴から消す", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                    AskHistory.remove(text)
                    self?.reloadRecents()
                },
            ])
            recents.addArrangedSubview(row)
        }
    }

    // MARK: 進み具合

    /// 新しく頼まれた。前の手順を消して、考え始める。
    func begin(_ text: String) -> AskRun {
        currentRun += 1
        stopButton.isHidden = false
        chips.isHidden = true
        recents.isHidden = true
        titleLabel.isHidden = false
        titleLabel.text = text
        steps.arrangedSubviews.forEach { $0.removeFromSuperview() }
        stepRows = []
        hideCard()
        orb.setThinking(true)
        if let sheet = sheetPresentationController {
            sheet.animateChanges { sheet.selectedDetentIdentifier = .medium }
        }
        return AskRun(ui: self, id: currentRun)
    }

    /// 止める。調べている途中の返事は、届いても出さない。回っている印も止める。
    private func stop() {
        currentRun += 1
        for (icon, label) in stepRows where icon.layer.animation(forKey: "spin") != nil {
            icon.layer.removeAnimation(forKey: "spin")
            icon.image = UIImage(systemName: "minus.circle")
            icon.tintColor = MeetPalette.secondary
            label.textColor = MeetPalette.secondary
        }
        finish("止めました", ok: false)
    }

    /// 手順を1行足す（くるくる回る印つき）。番号を返す。
    @discardableResult
    func addStep(_ text: String) -> Int {
        let icon = UIImageView(image: UIImage(systemName: "circle.dotted"))
        icon.tintColor = MeetPalette.action
        icon.contentMode = .scaleAspectFit
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 20).isActive = true
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.toValue = Double.pi * 2
        spin.duration = 1.2
        spin.repeatCount = .infinity
        icon.layer.add(spin, forKey: "spin")
        let label = UILabel()
        label.font = Type.font(15, .regular, .body)
        label.textColor = MeetPalette.secondary
        label.numberOfLines = 0
        label.text = text
        let row = UIStackView(arrangedSubviews: [icon, label])
        row.axis = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 10
        row.alpha = 0
        steps.addArrangedSubview(row)
        UIView.animate(withDuration: 0.25) { row.alpha = 1 }
        stepRows.append((icon, label))
        return stepRows.count - 1
    }

    /// 手順を済みにする。note があれば言い直す（「3件見つけました」など）。
    func finishStep(_ index: Int, note: String? = nil, failed: Bool = false) {
        guard stepRows.indices.contains(index) else { return }
        let (icon, label) = stepRows[index]
        icon.layer.removeAnimation(forKey: "spin")
        icon.image = UIImage(systemName: failed ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
        icon.tintColor = failed ? .systemOrange : UIColor(red: 0.36, green: 0.79, blue: 0.65, alpha: 1)
        label.textColor = MeetPalette.primary
        if let note { label.text = note }
    }

    /// 確かめる札。primary を押すまで何も送らない。
    func ask(title: String, detail: String?, primary: String, secondary: String?,
             onPrimary: @escaping () -> Void, onSecondary: (() -> Void)?) {
        orb.setThinking(false)
        card.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let t = UILabel()
        t.font = Type.font(17, .bold, .headline)
        t.textColor = MeetPalette.primary
        t.numberOfLines = 0
        t.text = title
        card.addArrangedSubview(t)
        if let detail {
            let d = UILabel()
            d.font = Type.caption
            d.textColor = MeetPalette.secondary
            d.numberOfLines = 0
            d.text = detail
            card.addArrangedSubview(d)
        }
        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = 10
        row.distribution = .fillEqually
        row.addArrangedSubview(pill(primary, primary: true, action: onPrimary))
        if let secondary, let onSecondary {
            row.addArrangedSubview(pill(secondary, primary: false, action: onSecondary))
        }
        card.setCustomSpacing(12, after: card.arrangedSubviews.last!)
        card.addArrangedSubview(row)
        card.alpha = 0
        card.isHidden = false
        UIView.animate(withDuration: 0.25) { self.card.alpha = 1 }
    }

    /// 候補の一覧（Appleマップの検索結果と同じく、名前と「種類・距離」を1行ずつ）。押すとその場所の札へ。
    /// credit: 一覧に OpenPOI API の場所が入っている。出典とそのページへのリンクを下に出す（利用条件）。
    func choose(title: String, rows: [(title: String, detail: String)], credit: Bool = false,
                onPick: @escaping (Int) -> Void) {
        stopButton.isHidden = true
        orb.setThinking(false)
        card.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let t = UILabel()
        t.font = Type.font(17, .bold, .headline)
        t.textColor = MeetPalette.primary
        t.numberOfLines = 0
        t.text = title
        card.addArrangedSubview(t)
        for (i, row) in rows.enumerated() {
            var conf = UIButton.Configuration.plain()
            conf.title = row.title
            conf.subtitle = row.detail
            conf.image = UIImage(systemName: "chevron.right",
                                 withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
            conf.imagePlacement = .trailing
            conf.baseForegroundColor = MeetPalette.primary
            conf.imageColorTransformer = UIConfigurationColorTransformer { _ in MeetPalette.secondary }
            conf.titleAlignment = .leading
            conf.titleLineBreakMode = .byTruncatingTail
            conf.subtitleLineBreakMode = .byTruncatingTail
            conf.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 0, bottom: 10, trailing: 0)
            conf.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in
                var a = attrs
                a.font = Type.font(16, .semibold, .body)
                return a
            }
            conf.subtitleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in
                var a = attrs
                a.font = Type.caption
                a.foregroundColor = MeetPalette.secondary
                return a
            }
            let b = UIButton(configuration: conf)
            b.contentHorizontalAlignment = .fill
            b.addAction(UIAction { _ in onPick(i) }, for: .touchUpInside)
            card.addArrangedSubview(b)
        }
        if credit {
            var conf = UIButton.Configuration.plain()
            conf.title = OpenPOI.creditText
            conf.baseForegroundColor = MeetPalette.secondary
            conf.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 0, bottom: 0, trailing: 0)
            conf.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in
                var a = attrs
                a.font = Type.caption
                return a
            }
            let b = UIButton(configuration: conf)
            b.contentHorizontalAlignment = .leading
            b.addAction(UIAction { [weak self] _ in
                self?.present(SFSafariViewController(url: OpenPOI.attributionURL), animated: true)
            }, for: .touchUpInside)
            card.addArrangedSubview(b)
        }
        card.alpha = 0
        card.isHidden = false
        UIView.animate(withDuration: 0.25) { self.card.alpha = 1 }
    }

    /// 終わった（または進めなかった）ことを一言で。
    func finish(_ text: String, ok: Bool = true) {
        stopButton.isHidden = true
        orb.setThinking(false)
        hideCard()
        let i = addStep(text)
        finishStep(i, failed: !ok)
        chips.isHidden = false
        reloadRecents()
    }

    private func hideCard() {
        card.isHidden = true
        card.arrangedSubviews.forEach { $0.removeFromSuperview() }
    }

    private func pill(_ title: String, primary: Bool, action: @escaping () -> Void) -> UIButton {
        var conf = UIButton.Configuration.filled()
        conf.title = title
        conf.baseBackgroundColor = primary ? MeetPalette.action : MeetPalette.raised
        conf.baseForegroundColor = primary ? MeetPalette.onAction : MeetPalette.primary
        conf.cornerStyle = .capsule
        conf.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)
        conf.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in
            var a = attrs
            a.font = Type.font(15, .bold, .body)
            return a
        }
        let b = UIButton(type: .system)
        b.configuration = conf
        b.titleLabel?.adjustsFontSizeToFitWidth = true
        b.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return b
    }
}
