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
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - 何をしたいか

struct AskIntent: Sendable {
    enum Kind: String, Sendable { case meet, errand, mood, route, place }
    var kind: Kind
    /// 待ち合わせ・探す場所の種類（カフェ・駅など）。
    var placeKind: String = ""
    var items: [String] = []
    var mood: String = ""
    var query: String = ""
    /// 「〇〇に案内して」のように、そこへ行きたいと言っている。見つけたら案内開始を勧める。
    var go: Bool = false
}

enum AskParser {

    /// 一文を読む。AIが使えれば AI、使えなければ言葉の拾い上げ。2つ目は AI で読んだか。
    static func parse(_ text: String, partner: String) async -> (AskIntent, Bool) {
        // 「伝えて」「言っといて」「行き方」ははっきりした合図なので、言葉で決める。
        // Macで同じAIに6文かけたら、「ちょっと遅れるって言っといて」「改札の前で
        // 待ってると伝えて」を「会う」と取り違えた（2/6）。小さいモデルに迷わせない。
        let rule = keywordParse(text, partner: partner)
        if (rule.kind == .mood || rule.kind == .route), hasStrongSignal(text) { return (rule, false) }
        // 「ラゾーナに案内して」「〇〇まで行きたい」も言葉で決める（AIは「連れてって」を
        // 「会う」と取り違えた）。
        if rule.go { return (rule, false) }
        // 「近くのカフェ」「いちばん近い駅」も言葉で決める（AIは「いちばん近い駅」を
        // 相手への行き方と取り違えた）。
        if rule.kind == .place, nearbyMarkers.contains(where: { text.contains($0) }) { return (rule, false) }
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), SystemLanguageModel.default.isAvailable {
            let result = await withTimeout(seconds: 10) { try await aiParse(text, partner: partner) }
            if let result { return (result, true) }
        }
        #endif
        return (keywordParse(text, partner: partner), false)
    }

    private static func hasStrongSignal(_ text: String) -> Bool {
        ["伝えて", "言っといて", "と言って", "って言って", "と伝え", "って伝え", "行き方", "どう行け", "どう行く", "道順"]
            .contains { text.contains($0) }
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

        // 「〇〇に案内して」「〇〇まで行きたい」「〇〇へ連れてって」
        if let dest = destination(in: text) {
            let toPartner = (!partner.isEmpty && dest.contains(partner)) || dest.contains("のところ") || dest.contains("相手")
            if toPartner { return AskIntent(kind: .route) }
            return AskIntent(kind: .place, query: dest, go: true)
        }

        if has(nearbyMarkers) {
            var q = text
            for m in nearbyMarkers { q = q.replacingOccurrences(of: m, with: "") }
            return AskIntent(kind: .place, placeKind: placeWord(in: text) ?? "", query: q)
        }
        if has(["伝えて", "様子", "って言って", "と言って", "言っといて", "と伝え", "って伝え"]) {
            return AskIntent(kind: .mood, mood: quoted(text) ?? String(before(text, ["って伝え", "と伝え", "って言っ", "と言っ"]).prefix(20)))
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
        return AskIntent(kind: .place, placeKind: placeWord(in: text) ?? "", query: text)
    }

    private static let placeWords = ["カフェ", "喫茶", "ごはん", "ランチ", "食事", "レストラン", "駅", "公園", "コンビニ"]
    static let nearbyMarkers = ["近くの", "いちばん近い", "一番近い", "最寄りの", "この辺の", "この辺で"]

    /// 種類の言葉（ある1つの店ではない）。これで探すときは近い順にする。
    static let genericWords = ["カフェ", "喫茶", "コーヒー", "ごはん", "ランチ", "ディナー", "食事", "レストラン",
                               "ラーメン", "そば", "うどん", "寿司", "焼肉", "居酒屋", "ファミレス", "ハンバーガー",
                               "パン", "駅", "コンビニ", "公園", "トイレ", "薬局", "ドラッグストア", "スーパー",
                               "ATM", "銀行", "病院", "本屋", "書店", "ホテル", "駐車場", "駐輪場", "休憩"]

    /// 言葉そのもの（「カフェ」「ラーメン屋」）のときだけ。「東京駅」は駅という種類ではなく
    /// 1つの場所なので、末尾が「駅」でも種類とはみなさない（近くの別の駅を選んでいた）。
    static func isGeneric(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        return genericWords.contains { w in [w, w + "屋", w + "屋さん", w + "店"].contains(q) }
    }

    /// 行き先。「ラゾーナに案内して」→「ラゾーナ」。
    private static func destination(in text: String) -> String? {
        let pattern = "^(.+?)(に|まで|へ)(案内|連れて|行きたい|行こう|行って|行く|向かいたい)"
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

// MARK: - 先回り（頼まなくても提案する）
//
// Muse の「頼まなくても状況を見て提案し、決めるのは人」の形（本人 9/25「3も一緒に」）。
// 何を出すかは観測できる事実だけで決める純粋な関数。AIには判断させない
// （小さいモデルに「状況を判断して」は筋が悪い。Jevで測った教訓）。

struct Suggestion: Equatable {
    enum Kind: String { case errandStore, earlyArrival, decideMeet }
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
        if let firstItem { return [firstItem] }
        return await nearest(query, near: me)
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

// MARK: - 頼む画面

/// 一文を打つ（声でもいい。キーボードのマイク）→ 手順が1行ずつ進む → 送る前に確認の札。
final class AskViewController: UIViewController, UITextFieldDelegate {

    var onSubmit: ((String) -> Void)?
    private let suggestions: [String]

    private let orb = OrbView()
    private let field = UITextField()
    private let chips = WrappingRow()
    private let modeLabel = UILabel()
    private let titleLabel = UILabel()
    private let steps = UIStackView()
    private let card = UIStackView()
    private var stepRows: [(icon: UIImageView, label: UILabel)] = []

    init(suggestions: [String]) {
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
        let inputRow = UIStackView(arrangedSubviews: [orb, field])
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

        let column = UIStackView(arrangedSubviews: [inputRow, modeLabel, chips, titleLabel, steps, card])
        column.axis = .vertical
        column.spacing = 12
        column.setCustomSpacing(6, after: inputRow)
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

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if titleLabel.isHidden { field.becomeFirstResponder() }
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        submit()
        return true
    }

    private func submit() {
        let text = (field.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        field.resignFirstResponder()
        onSubmit?(text)
    }

    // MARK: 進み具合

    /// 新しく頼まれた。前の手順を消して、考え始める。
    func begin(_ text: String) {
        chips.isHidden = true
        titleLabel.isHidden = false
        titleLabel.text = text
        steps.arrangedSubviews.forEach { $0.removeFromSuperview() }
        stepRows = []
        hideCard()
        orb.setThinking(true)
        if let sheet = sheetPresentationController {
            sheet.animateChanges { sheet.selectedDetentIdentifier = .medium }
        }
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

    /// 終わった（または進めなかった）ことを一言で。
    func finish(_ text: String, ok: Bool = true) {
        orb.setThinking(false)
        hideCard()
        let i = addStep(text)
        finishStep(i, failed: !ok)
        chips.isHidden = false
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
