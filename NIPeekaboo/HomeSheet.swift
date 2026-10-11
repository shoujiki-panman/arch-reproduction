// ホームの下のシートと、「探す」の全画面。
//
// 作り方は自分で考えず、位置共有アプリの定番に合わせた（2026-09-25）。
// Apple「探す」・Life360・Googleマップ・Bump・Jagat の画面を見比べると、5つとも
//  - 地図が画面全部で、上に大きな文字を置かない
//  - 下に引っぱれる板が1枚。相手の行（顔・名前・距離・何分前）と、その人にできることのタイル
//  - 方角の矢印は、人のカードから入る別の全画面（×で地図に戻る）
//  - 招待は人の一覧の最後の「＋追加」
// という骨組みだった。ここはその形をそのまま作る。中身の判断は MeetViewController が持ち、
// この2つは渡された状態を描くだけにする。
import UIKit
import MapKit
import SceneKit

// MARK: - 顔の丸

/// 人の印。写真があれば写真、無ければ名前の頭文字（「探す」やLife360と同じ）。
final class FaceView: UIView {
    private let photo = UIImageView()
    private let initial = UILabel()

    /// 頭文字の地の色。名前ごとに決まるので、同じ人はいつも同じ色になる。
    private static let tints: [UIColor] = [
        UIColor(red: 0.96, green: 0.75, blue: 0.82, alpha: 1),
        UIColor(red: 0.62, green: 0.88, blue: 0.80, alpha: 1),
        UIColor(red: 0.81, green: 0.80, blue: 0.96, alpha: 1),
        UIColor(red: 0.98, green: 0.78, blue: 0.46, alpha: 1),
        UIColor(red: 0.71, green: 0.83, blue: 0.96, alpha: 1),
    ]

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        photo.contentMode = .scaleAspectFill
        initial.textAlignment = .center
        initial.textColor = .black
        for v in [photo, initial] as [UIView] {
            addSubview(v)
            v.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                v.topAnchor.constraint(equalTo: topAnchor),
                v.bottomAnchor.constraint(equalTo: bottomAnchor),
                v.leadingAnchor.constraint(equalTo: leadingAnchor),
                v.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.width / 2
        initial.font = Type.font(bounds.width * 0.42, .bold, .headline)
    }

    func set(name: String, face: UIImage?) {
        photo.image = face
        photo.isHidden = face == nil
        initial.isHidden = face != nil
        initial.text = name.first.map(String.init) ?? "?"
        let index = abs(name.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }) % Self.tints.count
        backgroundColor = Self.tints[index]
    }
}

// MARK: - 下のシート

final class HomeSheetView: UIView {

    /// 下の板だけは元の紺色のまま（本人 9/25「ここは元のデザインが好きだった」）。
    /// 地図・ピン・ボタンは iOS 標準にしたが、板の中はこの色で描く。
    /// 同じ名前の入れ子にしてあるので、板の中の MeetPalette はすべてこちらを指す。
    enum MeetPalette {
        static let background = UIColor(red: 16/255, green: 22/255, blue: 32/255, alpha: 1)
        static let surface = UIColor(red: 30/255, green: 40/255, blue: 55/255, alpha: 1)
        static let raised = UIColor(red: 44/255, green: 57/255, blue: 76/255, alpha: 1)
        static let primary = UIColor(red: 244/255, green: 247/255, blue: 252/255, alpha: 1)
        static let secondary = UIColor(red: 184/255, green: 196/255, blue: 213/255, alpha: 1)
        static let action = UIColor(red: 169/255, green: 202/255, blue: 255/255, alpha: 1)
        static let onAction = background
    }

    struct Peer {
        var name: String
        var face: UIImage?
        /// 「1.2km・歩いて約14分・いま」
        var detail: String
        var mood: String?
        /// 電波（UWB）が届いている。「探す」を目立たせる。
        var radioNear: Bool
        /// 決まっている待ち合わせの場所。
        var pinName: String?
        /// おつかいのいまの様子。「頼み中 1/3個」など。
        var errandText: String?
    }

    struct Friend {
        var name: String
        var face: UIImage?
        /// 自分はもう押した。相手が押すのを待っている。
        var waiting: Bool
        /// 2人の部屋の合言葉の頭4文字（確かめ用。2台で同じなら同じ部屋に入れる）。
        var room: String = ""
    }

    enum Mode {
        case peer(Peer, canInvite: Bool)
        case friends([Friend], waitingLine: String?, canInvite: Bool, canEnd: Bool)
    }

    var onFind: (() -> Void)?
    var onRoute: (() -> Void)?
    var onMeet: (() -> Void)?
    var onErrand: (() -> Void)?
    var onMood: (() -> Void)?
    var onInvite: (() -> Void)?
    var onEnd: (() -> Void)?
    var onConnect: ((Int) -> Void)?
    var onExplore: (() -> Void)?
    var onNearbyNow: (() -> Void)?
    /// いまの話題（X・Yahoo!リアルタイム検索）。災害とは別の入口にする（9/28）。
    var onTalk: (() -> Void)?
    var onAsk: (() -> Void)?
    /// 先回りの提案。あるときだけ、板のいちばん上に出す。
    var suggestion: Suggestion?
    /// 頼まれているおつかい。板のいちばん上に、品物の名前まで出す（10/3 本人「買い物依頼されたら分かりやすく表示しておいて」）。
    struct ErrandCard: Equatable {
        var from: String
        var place: String
        var left: [String]
        var got: [String]
    }
    var errand: ErrandCard?
    var onErrandOpen: (() -> Void)?
    /// 今日歩いた分（「今日 7,938歩・5.6km」）。検索の下に1行で出す。歩くたびに変わるので、
    /// 板は作り直さず字だけ書き換える。出す・出さないが変わったときだけ並べ直す。
    var todayWalk: String? {
        didSet {
            guard todayWalk != oldValue else { return }
            if (todayWalk == nil) == (oldValue == nil) {
                todayWalkLabel?.text = todayWalk
            } else if let mode {
                render(mode)
            }
        }
    }
    private weak var todayWalkLabel: UILabel?
    var onSuggestion: (() -> Void)?
    var onSuggestionDismiss: (() -> Void)?

    private let stack = UIStackView()
    private let grabber = UIView()
    /// ふだん出ている行（相手・タイル・友だち）。地図を触ると隠れて、検索だけになる。
    private let body = UIStackView()
    /// 引き上げたときだけ出る行（様子・追加・やめる）。
    private let more = UIStackView()
    /// 板の高さは3段：検索だけ・ふだん・引き上げ。Appleマップの下の板と同じく、地図を触ると検索だけまで下がる。
    enum Level: Int { case minimized, normal, expanded }
    private(set) var level: Level = .normal
    private var mode: Mode?
    private var wasPeer: Bool?

    override init(frame: CGRect) {
        super.init(frame: frame)
        // 元の紺色の板。端末がライトでも板の中は暗い色のまま。
        overrideUserInterfaceStyle = .dark
        backgroundColor = MeetPalette.surface
        layer.cornerRadius = 22
        layer.cornerCurve = .continuous
        layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.3
        layer.shadowRadius = 12
        layer.shadowOffset = CGSize(width: 0, height: -2)

        grabber.backgroundColor = MeetPalette.raised
        grabber.layer.cornerRadius = 2.5
        addSubview(grabber)
        grabber.translatesAutoresizingMaskIntoConstraints = false

        stack.axis = .vertical
        stack.spacing = 12
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false

        body.axis = .vertical
        body.spacing = 12
        more.axis = .vertical
        more.spacing = 0

        NSLayoutConstraint.activate([
            grabber.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            grabber.centerXAnchor.constraint(equalTo: centerXAnchor),
            grabber.widthAnchor.constraint(equalToConstant: 36),
            grabber.heightAnchor.constraint(equalToConstant: 5),
            stack.topAnchor.constraint(equalTo: grabber.bottomAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            stack.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -10),
        ])

        // つまみを上下に払うか、つまみのあたりを押すと、引き上げ／引き下げ。
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        addGestureRecognizer(pan)
        let tap = UITapGestureRecognizer(target: self, action: #selector(grabberTapped(_:)))
        addGestureRecognizer(tap)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 影の形を先に渡す（渡さないと、地図を動かすたびに毎フレーム影を計算し直す）。
    override func layoutSubviews() {
        super.layoutSubviews()
        layer.shadowPath = UIBezierPath(roundedRect: bounds, byRoundingCorners: [.topLeft, .topRight],
                                        cornerRadii: CGSize(width: 22, height: 22)).cgPath
    }

    /// 板の形（どの行が並ぶか）。距離の一行（歩くたびに変わる）は入れない。
    static func shape(of mode: Mode, suggestion: Suggestion?, errand: ErrandCard? = nil,
                      walking: Bool = false) -> String {
        func faceKey(_ image: UIImage?) -> String { image.map { "\(ObjectIdentifier($0))" } ?? "-" }
        var parts: [String] = []
        if let e = errand { parts += ["e", e.from, e.place] + e.left + ["|"] + e.got }
        if let s = suggestion { parts += ["s", s.kind.rawValue, s.title, s.detail, s.primary] }
        if walking { parts += ["w"] }
        switch mode {
        case let .peer(p, canInvite):
            parts += ["p", p.name, faceKey(p.face), p.mood ?? "", "\(p.radioNear)", p.pinName ?? "",
                      p.errandText ?? "", "\(canInvite)"]
        case let .friends(friends, waitingLine, canInvite, canEnd):
            parts += ["f", waitingLine ?? "", "\(canInvite)", "\(canEnd)"]
            for f in friends { parts += [f.name, faceKey(f.face), "\(f.waiting)"] }
        }
        return parts.joined(separator: "\u{1F}")
    }

    /// 前に並べた形と、相手の距離の一行（形が同じなら、ここだけ書き換える）。
    private var lastShape: String?
    private weak var peerDetailLabel: UILabel?

    func render(_ mode: Mode) {
        // 形が同じなら作り直さない。作り直すと、押している最中のボタンが消えて押しが空振りする
        // （電波の距離は1秒に何度も届くので、ほとんどの押しが消えていた）。
        let shape = Self.shape(of: mode, suggestion: suggestion, errand: errand, walking: todayWalk != nil)
        if shape == lastShape {
            self.mode = mode
            if case let .peer(peer, _) = mode, peerDetailLabel?.text != peer.detail {
                peerDetailLabel?.text = peer.detail
            }
            return
        }
        lastShape = shape
        self.mode = mode
        // 相手とつながった・離れたときは、下げていても「ふだん」に戻す（大事な行が隠れたままにしない）。
        var isPeer = false
        if case .peer = mode { isPeer = true }
        if let wasPeer, wasPeer != isPeer, level == .minimized { level = .normal }
        wasPeer = isPeer
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        body.arrangedSubviews.forEach { $0.removeFromSuperview() }
        more.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if let errand {
            stack.addArrangedSubview(errandRow(errand))
            // 頼まれたら、下げていても板を「ふだん」に戻す（見落とさないように）。
            if level == .minimized { level = .normal }
        }
        if let suggestion { stack.addArrangedSubview(suggestionRow(suggestion)) }
        // いちばん上は検索（Appleマップ・Googleマップと同じ）。つないでいなくても使える。
        stack.addArrangedSubview(searchRow())
        if let todayWalk { stack.addArrangedSubview(todayWalkRow(todayWalk)) }
        switch mode {
        case let .peer(peer, canInvite):
            body.addArrangedSubview(peerRow(peer))
            // 頼まれているおつかいは上の行に品物まで出しているので、ここでは頼んでいる側のときだけ。
            for line in [peer.pinName.map { "待ち合わせ：\($0)" },
                         errand == nil ? peer.errandText.map { "おつかい：\($0)" } : nil] {
                guard let line else { continue }
                body.addArrangedSubview(statusLine(line))
            }
            body.addArrangedSubview(tiles(peer))
            more.addArrangedSubview(moreRow("まわりを見る", symbol: "binoculars", action: onExplore))
            more.addArrangedSubview(moreRow("いまの話題（X・リアルタイム）", symbol: "bubble.left.and.text.bubble.right",
                                            action: onTalk))
            more.addArrangedSubview(moreRow("いま近くで（災害・警察・もしものとき）", symbol: "exclamationmark.shield",
                                            action: onNearbyNow))
            more.addArrangedSubview(moreRow("いまの様子を伝える", symbol: "text.bubble", action: onMood))
            if canInvite {
                more.addArrangedSubview(moreRow("人を追加（リンク）", symbol: "plus.circle", action: onInvite))
            }
            more.addArrangedSubview(moreRow("共有をやめる", symbol: "xmark.circle", action: onEnd, danger: true))
        case let .friends(friends, waitingLine, canInvite, canEnd):
            // いちばんの用事（友だちとつなぐ）を先に、まわりのことはその下に（10/3 配置の見直し）。
            body.addArrangedSubview(sectionTitle(!friends.isEmpty ? "友だち"
                                                  : waitingLine != nil ? "待っています" : "人と会う"))
            if let waitingLine { body.addArrangedSubview(statusLine(waitingLine)) }
            for (index, friend) in friends.enumerated() {
                body.addArrangedSubview(friendRow(friend, index: index))
            }
            if canInvite {
                body.addArrangedSubview(moreRow(waitingLine != nil ? "リンクを共有"
                                                 : friends.isEmpty ? "招待リンクを送る" : "人を追加（リンク）",
                                                 symbol: "plus.circle.fill", action: onInvite, accent: true))
            }
            if canEnd {
                body.addArrangedSubview(moreRow("やめる", symbol: "xmark.circle", action: onEnd, danger: true))
            }
            body.addArrangedSubview(sectionTitle("まわり"))
            body.addArrangedSubview(moreRow("まわりを見る（カフェ・ごはん・公園）", symbol: "binoculars",
                                             action: onExplore))
            body.addArrangedSubview(moreRow("いまの話題（X・リアルタイム）", symbol: "bubble.left.and.text.bubble.right",
                                             action: onTalk))
            body.addArrangedSubview(moreRow("いま近くで（災害・警察・もしものとき）", symbol: "exclamationmark.shield",
                                             action: onNearbyNow))
        }
        if !body.arrangedSubviews.isEmpty { stack.addArrangedSubview(body) }
        if !more.arrangedSubviews.isEmpty { stack.addArrangedSubview(more) }
        applyLevel()
    }

    /// 引き上げで出せる段があるか（友だちの一覧のときは「ふだん」が上限）。
    private var hasMore: Bool { !more.arrangedSubviews.isEmpty }

    private func applyLevel() {
        // UIStackView は、隠れている行にもう一度「隠す」を言うと数え違えて、行が重なって残る
        // （9/28 実機：「共有をやめる」と「いま近くで」が重なって出た）。変わるときだけ切り替える。
        let hideBody = level == .minimized, hideMore = level != .expanded
        if body.isHidden != hideBody { body.isHidden = hideBody }
        if more.isHidden != hideMore { more.isHidden = hideMore }
        body.alpha = hideBody ? 0 : 1
        more.alpha = hideMore ? 0 : 1
    }

    func setLevel(_ next: Level) {
        let next: Level = (next == .expanded && !hasMore) ? .normal : next
        guard level != next else { return }
        level = next
        UISelectionFeedbackGenerator().selectionChanged()
        Trans.run(Trans.smoothOut(Trans.fast)) {
            self.applyLevel()
            self.superview?.layoutIfNeeded()
        }
    }

    /// 地図を触った：検索だけの高さまで下げる。
    func minimize() { setLevel(.minimized) }

    @objc private func panned(_ pan: UIPanGestureRecognizer) {
        guard pan.state == .ended else { return }
        let dy = pan.translation(in: self).y
        let vy = pan.velocity(in: self).y
        if dy < -20 || vy < -300 {
            setLevel(Level(rawValue: level.rawValue + 1) ?? .expanded)
        } else if dy > 20 || vy > 300 {
            setLevel(Level(rawValue: level.rawValue - 1) ?? .minimized)
        }
    }

    @objc private func grabberTapped(_ tap: UITapGestureRecognizer) {
        // つまみのまわり（上の帯）を押したときだけ。行やタイルの押下は邪魔しない。
        // 検索だけ → ふだん → 引き上げ → ふだん（引き上げの段が無ければ、検索だけ ⇄ ふだん）。
        guard tap.location(in: self).y < 30 else { return }
        switch level {
        case .minimized: setLevel(.normal)
        case .normal: setLevel(hasMore ? .expanded : .minimized)
        case .expanded: setLevel(.normal)
        }
    }

    // MARK: 部品

    private func peerRow(_ peer: Peer) -> UIView {
        let face = FaceView()
        face.set(name: peer.name, face: peer.face)
        face.translatesAutoresizingMaskIntoConstraints = false
        face.widthAnchor.constraint(equalToConstant: 44).isActive = true
        face.heightAnchor.constraint(equalToConstant: 44).isActive = true

        let name = UILabel()
        name.font = Type.font(18, .bold, .headline)
        name.textColor = MeetPalette.primary
        name.text = peer.name
        let detail = UILabel()
        detail.font = Type.caption
        detail.textColor = MeetPalette.secondary
        detail.text = peer.detail
        detail.adjustsFontSizeToFitWidth = true
        detail.minimumScaleFactor = 0.8
        peerDetailLabel = detail
        let texts = UIStackView(arrangedSubviews: [name, detail])
        texts.axis = .vertical
        texts.spacing = 2
        if let mood = peer.mood, !mood.isEmpty {
            let moodLabel = UILabel()
            moodLabel.font = Type.caption
            moodLabel.textColor = MeetPalette.action
            moodLabel.text = "「\(mood)」"
            texts.addArrangedSubview(moodLabel)
        }
        let row = UIStackView(arrangedSubviews: [face, texts])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 12
        return row
    }

    private func tiles(_ peer: Peer) -> UIView {
        let items: [(String, String, (() -> Void)?, Bool)] = [
            ("探す", peer.radioNear ? "dot.radiowaves.left.and.right" : "location.north.line.fill", onFind, peer.radioNear),
            ("経路", "figure.walk", onRoute, false),
            ("待ち合わせ", peer.pinName == nil ? "mappin.and.ellipse" : "flag.fill", onMeet, false),
            ("おつかい", peer.errandText == nil ? "cart" : "cart.fill", onErrand, false),
        ]
        let row = UIStackView()
        row.axis = .horizontal
        row.distribution = .fillEqually
        row.spacing = 8
        for (title, symbol, action, strong) in items {
            var conf = UIButton.Configuration.filled()
            conf.title = title
            conf.image = UIImage(systemName: symbol,
                                 withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold))
            conf.imagePlacement = .top
            conf.imagePadding = 6
            conf.baseBackgroundColor = strong ? MeetPalette.action : MeetPalette.raised
            conf.baseForegroundColor = strong ? MeetPalette.onAction : MeetPalette.primary
            conf.cornerStyle = .large
            conf.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 2, bottom: 10, trailing: 2)
            conf.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in
                var a = attrs
                a.font = Type.font(12, .semibold, .caption1)
                return a
            }
            let button = UIButton(type: .system)
            button.configuration = conf
            button.titleLabel?.adjustsFontSizeToFitWidth = true
            button.addAction(UIAction { _ in action?() }, for: .touchUpInside)
            row.addArrangedSubview(button)
        }
        return row
    }

    /// 先回りの提案の行。✨・一言・理由、「頼む」と「いい」。
    /// 頼まれているおつかい。先回りの提案と同じ部品で、品物の名前・買った数・店まで見せる。
    private func errandRow(_ e: ErrandCard) -> UIView {
        let icon = UIImageView(image: UIImage(systemName: "cart.fill"))
        icon.tintColor = .systemOrange
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
        icon.setContentHuggingPriority(.required, for: .horizontal)
        let title = UILabel()
        title.font = Type.font(15, .bold, .headline)
        title.textColor = MeetPalette.primary
        title.numberOfLines = 2
        let total = e.left.count + e.got.count
        title.text = e.left.isEmpty ? "\(e.from)のおつかい　全部買いました"
                                    : "\(e.from)からおつかい（あと\(e.left.count)/\(total)個）"
        let detail = UILabel()
        detail.font = Type.font(15, .regular, .body)
        detail.textColor = MeetPalette.primary
        detail.numberOfLines = 0
        let lines = e.left.map { "□ \($0)" } + e.got.map { "☑︎ \($0)" }
        detail.text = lines.joined(separator: "\n")
        let place = UILabel()
        place.font = Type.caption
        place.textColor = MeetPalette.secondary
        place.text = "\(e.place)で"

        var open = UIButton.Configuration.filled()
        open.title = "リストを開く"
        open.baseBackgroundColor = .systemOrange
        open.baseForegroundColor = .white
        open.cornerStyle = .capsule
        open.contentInsets = NSDirectionalEdgeInsets(top: 7, leading: 16, bottom: 7, trailing: 16)
        let openButton = UIButton(type: .system)
        openButton.configuration = open
        openButton.addAction(UIAction { [weak self] _ in self?.onErrandOpen?() }, for: .touchUpInside)
        let buttons = UIStackView(arrangedSubviews: [openButton, UIView()])
        buttons.axis = .horizontal

        let texts = UIStackView(arrangedSubviews: [title, detail, place, buttons])
        texts.axis = .vertical
        texts.spacing = 4
        texts.setCustomSpacing(8, after: place)
        let row = UIStackView(arrangedSubviews: [icon, texts])
        row.axis = .horizontal
        row.alignment = .top
        row.spacing = 10
        row.isLayoutMarginsRelativeArrangement = true
        row.layoutMargins = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        row.backgroundColor = MeetPalette.raised
        row.layer.cornerRadius = 16
        row.layer.borderWidth = 1
        row.layer.borderColor = UIColor.systemOrange.withAlphaComponent(0.7).cgColor
        // 行のどこを押してもリストが開く。
        row.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(errandRowTapped)))
        return row
    }

    @objc private func errandRowTapped() { onErrandOpen?() }

    private func suggestionRow(_ s: Suggestion) -> UIView {
        let icon = UIImageView(image: UIImage(systemName: "sparkles"))
        icon.tintColor = .systemPurple
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
        icon.setContentHuggingPriority(.required, for: .horizontal)
        let title = UILabel()
        title.font = Type.font(15, .bold, .headline)
        title.textColor = MeetPalette.primary
        title.numberOfLines = 2
        title.text = s.title
        let detail = UILabel()
        detail.font = Type.caption
        detail.textColor = MeetPalette.secondary
        detail.numberOfLines = 3
        detail.text = s.detail

        var go = UIButton.Configuration.filled()
        go.title = s.primary
        go.baseBackgroundColor = MeetPalette.action
        go.baseForegroundColor = MeetPalette.onAction
        go.cornerStyle = .capsule
        go.contentInsets = NSDirectionalEdgeInsets(top: 7, leading: 16, bottom: 7, trailing: 16)
        let goButton = UIButton(type: .system)
        goButton.configuration = go
        goButton.addAction(UIAction { [weak self] _ in self?.onSuggestion?() }, for: .touchUpInside)
        var no = UIButton.Configuration.plain()
        no.title = "いい"
        no.baseForegroundColor = MeetPalette.secondary
        let noButton = UIButton(type: .system)
        noButton.configuration = no
        noButton.addAction(UIAction { [weak self] _ in self?.onSuggestionDismiss?() }, for: .touchUpInside)
        let buttons = UIStackView(arrangedSubviews: [goButton, noButton, UIView()])
        buttons.axis = .horizontal
        buttons.spacing = 6

        let texts = UIStackView(arrangedSubviews: [title, detail, buttons])
        texts.axis = .vertical
        texts.spacing = 3
        texts.setCustomSpacing(8, after: detail)
        let row = UIStackView(arrangedSubviews: [icon, texts])
        row.axis = .horizontal
        row.alignment = .top
        row.spacing = 10
        row.isLayoutMarginsRelativeArrangement = true
        row.layoutMargins = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        row.backgroundColor = MeetPalette.raised
        row.layer.cornerRadius = 16
        row.layer.borderWidth = 1
        row.layer.borderColor = UIColor.systemPurple.withAlphaComponent(0.6).cgColor
        return row
    }

    /// いちばん上の行。一文で頼む（AI）と、場所だけを探す虫めがね。
    private func searchRow() -> UIView {
        var askConf = UIButton.Configuration.filled()
        askConf.title = "AIに頼む・探す"
        askConf.image = UIImage(systemName: "sparkles")
        askConf.imagePadding = 8
        askConf.baseBackgroundColor = MeetPalette.raised
        askConf.baseForegroundColor = MeetPalette.primary
        askConf.cornerStyle = .large
        askConf.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14)
        askConf.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in
            var a = attrs
            a.font = Type.font(16, .regular, .body)
            return a
        }
        let ask = UIButton(type: .system)
        ask.configuration = askConf
        ask.contentHorizontalAlignment = .leading
        ask.addAction(UIAction { [weak self] _ in self?.onAsk?() }, for: .touchUpInside)
        ask.layer.borderWidth = 1
        ask.layer.borderColor = UIColor(red: 0.43, green: 0.36, blue: 1, alpha: 0.7).cgColor
        ask.layer.cornerRadius = 12

        // 🔍の検索はこの欄にまとめた（打つと場所の候補が出る。10/3 本人「まとめて」）。
        return ask
    }


    private func todayWalkRow(_ text: String) -> UIView {
        let icon = UIImageView(image: UIImage(systemName: "figure.walk"))
        icon.tintColor = MeetPalette.secondary
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(font: Type.caption)
        icon.setContentHuggingPriority(.required, for: .horizontal)
        let label = UILabel()
        label.font = Type.caption
        label.textColor = MeetPalette.secondary
        label.text = text
        todayWalkLabel = label
        let row = UIStackView(arrangedSubviews: [icon, label])
        row.spacing = 6
        row.alignment = .center
        return row
    }

    private func statusLine(_ text: String) -> UIView {
        let label = UILabel()
        label.font = Type.caption
        label.textColor = MeetPalette.secondary
        label.numberOfLines = 2
        label.text = text
        return label
    }

    private func sectionTitle(_ text: String) -> UIView {
        let label = UILabel()
        label.font = Type.font(13, .semibold, .footnote)
        label.textColor = MeetPalette.secondary
        label.text = text
        return label
    }

    private func friendRow(_ friend: Friend, index: Int) -> UIView {
        let face = FaceView()
        face.set(name: friend.name, face: friend.face)
        face.translatesAutoresizingMaskIntoConstraints = false
        face.widthAnchor.constraint(equalToConstant: 36).isActive = true
        face.heightAnchor.constraint(equalToConstant: 36).isActive = true

        let name = UILabel()
        name.font = Type.font(16, .semibold, .body)
        name.textColor = MeetPalette.primary
        name.text = friend.name
        let texts = UIStackView(arrangedSubviews: [name])
        texts.axis = .vertical
        if friend.waiting {
            let wait = UILabel()
            wait.font = Type.caption
            wait.textColor = MeetPalette.secondary
            wait.text = "\(friend.name)も押すと、つながります"
            texts.addArrangedSubview(wait)
        }
        let row = UIStackView(arrangedSubviews: [face, texts])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 12
        if !friend.waiting {
            var conf = UIButton.Configuration.filled()
            conf.title = "つなぐ"
            conf.baseBackgroundColor = MeetPalette.action
            conf.baseForegroundColor = MeetPalette.onAction
            conf.cornerStyle = .capsule
            conf.contentInsets = NSDirectionalEdgeInsets(top: 7, leading: 16, bottom: 7, trailing: 16)
            conf.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in
                var a = attrs
                a.font = Type.font(14, .bold, .body)
                return a
            }
            let button = UIButton(type: .system)
            button.configuration = conf
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.addAction(UIAction { [weak self] _ in self?.onConnect?(index) }, for: .touchUpInside)
            row.addArrangedSubview(button)
        }
        return row
    }

    private func moreRow(_ title: String, symbol: String, action: (() -> Void)?,
                         danger: Bool = false, accent: Bool = false) -> UIView {
        var conf = UIButton.Configuration.plain()
        conf.title = title
        conf.image = UIImage(systemName: symbol)
        conf.imagePadding = 10
        conf.baseForegroundColor = danger ? UIColor.systemRed : (accent ? MeetPalette.action : MeetPalette.primary)
        conf.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 0, bottom: 12, trailing: 0)
        conf.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in
            var a = attrs
            a.font = Type.font(16, .regular, .body)
            return a
        }
        let button = UIButton(type: .system)
        button.configuration = conf
        button.contentHorizontalAlignment = .leading
        button.addAction(UIAction { _ in action?() }, for: .touchUpInside)
        return button
    }
}

// MARK: - 探す（全画面）

/// 「探す」の「正確な場所を見つける」と同じ形。大きな矢印と距離だけ。×で地図へ戻る。
/// 遠いときはGPSとコンパスの向き、電波が届いたら電波の距離（向きは出ない）。
final class FindScreen: UIView {

    var onClose: (() -> Void)?
    var onCamera: (() -> Void)?

    private let caption = UILabel()
    private let nameLabel = UILabel()
    private let arrow = UIImageView(image: UIImage(systemName: "arrow.up",
                                                   withConfiguration: UIImage.SymbolConfiguration(pointSize: 170, weight: .bold)))
    private let distance = UILabel()
    private let detail = UILabel()
    private let closeButton = UIButton(type: .system)
    private let cameraButton = UIButton(type: .system)
    /// 右下の小さな地図。実際の道と進む向き。
    let miniMap = MiniMapView()

    static let ink = UIColor(red: 0.09, green: 0.22, blue: 0.36, alpha: 1)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Self.ink

        caption.font = Type.font(13, .semibold, .footnote)
        caption.textColor = MeetPalette.action
        caption.text = "探している"
        nameLabel.font = Type.font(30, .bold, .largeTitle)
        nameLabel.textColor = .white
        arrow.tintColor = .white
        arrow.contentMode = .scaleAspectFit
        distance.font = Type.font(56, .bold, .largeTitle)
        distance.textColor = .white
        distance.adjustsFontSizeToFitWidth = true
        distance.minimumScaleFactor = 0.5
        detail.font = Type.font(17, .regular, .body)
        detail.textColor = UIColor(white: 1, alpha: 0.78)
        detail.numberOfLines = 2

        for (button, symbol, title) in [(closeButton, "xmark", nil), (cameraButton, "camera.viewfinder", "カメラ")] as [(UIButton, String, String?)] {
            var conf = UIButton.Configuration.filled()
            conf.image = UIImage(systemName: symbol,
                                 withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold))
            conf.title = title
            conf.imagePadding = 6
            conf.baseBackgroundColor = UIColor(white: 1, alpha: 0.16)
            conf.baseForegroundColor = .white
            conf.cornerStyle = .capsule
            conf.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 14, bottom: 14, trailing: 14)
            button.configuration = conf
        }
        closeButton.accessibilityLabel = "閉じる"
        closeButton.addAction(UIAction { [weak self] _ in self?.onClose?() }, for: .touchUpInside)
        cameraButton.addAction(UIAction { [weak self] _ in self?.onCamera?() }, for: .touchUpInside)

        for v in [caption, nameLabel, arrow, distance, detail, closeButton, cameraButton, miniMap] as [UIView] {
            addSubview(v)
            v.translatesAutoresizingMaskIntoConstraints = false
        }
        let safe = safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            caption.topAnchor.constraint(equalTo: safe.topAnchor, constant: 20),
            caption.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 24),
            nameLabel.topAnchor.constraint(equalTo: caption.bottomAnchor, constant: 2),
            nameLabel.leadingAnchor.constraint(equalTo: caption.leadingAnchor),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: safe.trailingAnchor, constant: -24),

            arrow.centerXAnchor.constraint(equalTo: centerXAnchor),
            arrow.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -30),
            arrow.widthAnchor.constraint(equalToConstant: 200),
            arrow.heightAnchor.constraint(equalToConstant: 200),

            distance.leadingAnchor.constraint(equalTo: caption.leadingAnchor),
            distance.trailingAnchor.constraint(lessThanOrEqualTo: miniMap.leadingAnchor, constant: -12),
            distance.bottomAnchor.constraint(equalTo: detail.topAnchor, constant: -2),
            detail.leadingAnchor.constraint(equalTo: caption.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: miniMap.leadingAnchor, constant: -12),
            detail.bottomAnchor.constraint(equalTo: closeButton.topAnchor, constant: -28),

            miniMap.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -24),
            miniMap.bottomAnchor.constraint(equalTo: cameraButton.topAnchor, constant: -16),
            miniMap.widthAnchor.constraint(equalToConstant: 150),
            miniMap.heightAnchor.constraint(equalToConstant: 150),

            closeButton.leadingAnchor.constraint(equalTo: caption.leadingAnchor),
            closeButton.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -16),
            cameraButton.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -24),
            cameraButton.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// - Parameter angle: 矢印の向き（ラジアン、上が0）。出せないときは nil で矢印を消す。
    func update(name: String, distance text: String, detail line: String,
                angle: CGFloat?, cameraAvailable: Bool) {
        nameLabel.text = name
        distance.text = text
        detail.text = line
        cameraButton.isHidden = !cameraAvailable
        if let angle {
            arrow.isHidden = false
            // 向きは1秒に何十回も届く。毎回新しい動きを足すと積み重なって矢印が遅れるので、
            // いまの位置から短く引き継ぐ。
            UIView.animate(withDuration: 0.12, delay: 0,
                           options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut]) {
                self.arrow.transform = CGAffineTransform(rotationAngle: angle)
            }
        } else {
            arrow.isHidden = true
        }
    }
}

// MARK: - 地図と並べる板（地図を触ると下がる）

/// 地図と一緒に見る板（場所カード・経路）。地図を触ると、上の部分だけ見える高さまで下がる。
/// Appleマップの場所カードと同じ動き（本人 9/25「地図などタップするとさがって欲しい」）。
protocol MapSideSheet: UIViewController {
    /// 下げたときに見せる高さ（名前とボタンまで）。
    var peekHeight: CGFloat { get }
    /// 下げた・上げた。下げたときだけ見せたい行があれば、ここで切り替える。
    func didSettle(peek: Bool)
}

extension MapSideSheet {
    func didSettle(peek: Bool) {}
}

extension UISheetPresentationController.Detent.Identifier {
    static let peek = Self("peek")
}

enum MapSheets {
    /// 高さは3つ：上だけ・半分・全部。半分までは後ろの地図も触れる。はじめは半分。
    static func configure(_ vc: MapSideSheet) {
        guard let sheet = vc.sheetPresentationController else { return }
        sheet.prefersGrabberVisible = true
        if #available(iOS 16.0, *) {
            let peek = UISheetPresentationController.Detent.custom(identifier: .peek) { [weak vc] context in
                min(vc?.peekHeight ?? 170, context.maximumDetentValue * 0.45)
            }
            sheet.detents = [peek, .medium(), .large()]
            sheet.largestUndimmedDetentIdentifier = .medium
            sheet.selectedDetentIdentifier = .medium
        } else {
            sheet.detents = [.medium(), .large()]
            sheet.largestUndimmedDetentIdentifier = .medium
        }
    }

    /// 地図を触った。板を上だけの高さまで下げる。
    static func lower(_ vc: UIViewController?) {
        guard #available(iOS 16.0, *), let vc = vc as? MapSideSheet, !vc.isBeingDismissed,
              let sheet = vc.sheetPresentationController, sheet.selectedDetentIdentifier != .peek else { return }
        sheet.animateChanges { sheet.selectedDetentIdentifier = .peek }
        vc.didSettle(peek: true)
    }

    /// 新しい場所を見せる。半分の高さまで上げる。
    static func raise(_ vc: MapSideSheet) {
        guard #available(iOS 16.0, *), let sheet = vc.sheetPresentationController,
              sheet.selectedDetentIdentifier == .peek else { return }
        sheet.animateChanges { sheet.selectedDetentIdentifier = .medium }
        vc.didSettle(peek: false)
    }
}

// MARK: - 経路（アプリの中で）

/// 徒歩の経路の一覧。上に「徒歩◯分・◯km」、下に曲がり角を順に並べる。
/// 地図の線と一緒に見るので、シートは半分の高さで止める。
final class RouteSheetViewController: UIViewController, MapSideSheet {

    private let route: MKRoute
    private let name: String
    /// 行き先が人（動く）か、場所（動かない）か。
    private let movingGoal: Bool
    /// 「案内開始」が押された。
    var onStart: (() -> Void)?
    /// 閉じられた（案内を始めずに）。
    var onDismiss: (() -> Void)?
    /// 下げたときに見せる所（「案内開始」まで）。
    private let scroll = UIScrollView()
    private weak var startButton: UIButton?
    private var measuredPeek: CGFloat = 0

    var peekHeight: CGFloat { measuredPeek > 0 ? measuredPeek : 190 }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard let start = startButton, let column = start.superview else { return }
        let h = scroll.frame.minY + column.frame.minY + start.frame.maxY + 14
        guard abs(h - measuredPeek) > 1 else { return }
        measuredPeek = h
        if #available(iOS 16.0, *) { sheetPresentationController?.invalidateDetents() }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        onDismiss?()
    }

    init(route: MKRoute, name: String, movingGoal: Bool = true) {
        self.route = route
        self.name = name
        self.movingGoal = movingGoal
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = MeetPalette.background

        let minutes = max(1, Int((route.expectedTravelTime / 60).rounded()))
        let title = UILabel()
        title.font = Type.headline
        title.textColor = MeetPalette.primary
        title.numberOfLines = 2
        title.text = "\(name)まで 徒歩\(minutes)分"
        let sub = UILabel()
        sub.font = Type.caption
        sub.textColor = MeetPalette.secondary
        sub.text = "\(NearbyAlert.text(route.distance))・道なり" + (movingGoal ? "・相手が動くと変わります" : "")

        let steps = UIStackView()
        steps.axis = .vertical
        steps.spacing = 0
        // 最初の一歩は「出発地」で中身が無いので飛ばす。
        for step in route.steps where !step.instructions.isEmpty {
            steps.addArrangedSubview(stepRow(step))
        }
        if steps.arrangedSubviews.isEmpty {
            let none = UILabel()
            none.font = Type.caption
            none.textColor = MeetPalette.secondary
            none.text = "曲がり角の案内はありません。地図の線に沿って進んでください"
            none.numberOfLines = 0
            steps.addArrangedSubview(none)
        }

        // 地図アプリと同じく、一覧の上にいちばん大きな「開始」を置く。
        var startConf = UIButton.Configuration.filled()
        startConf.title = "案内開始"
        startConf.image = UIImage(systemName: "location.north.fill")
        startConf.imagePadding = 8
        startConf.baseBackgroundColor = MeetPalette.action
        startConf.baseForegroundColor = MeetPalette.onAction
        startConf.cornerStyle = .capsule
        startConf.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 20, bottom: 14, trailing: 20)
        startConf.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in
            var a = attrs
            a.font = Type.font(17, .bold, .headline)
            return a
        }
        let start = UIButton(type: .system)
        start.configuration = startConf
        start.addAction(UIAction { [weak self] _ in self?.onStart?() }, for: .touchUpInside)
        startButton = start

        scroll.alwaysBounceVertical = true
        let column = UIStackView(arrangedSubviews: [title, sub, start, steps])
        column.axis = .vertical
        column.spacing = 4
        column.setCustomSpacing(14, after: sub)
        column.setCustomSpacing(10, after: start)
        scroll.addSubview(column)
        view.addSubview(scroll)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        column.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            column.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            column.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
            column.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 24),
            column.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -24),
        ])
    }

    private func stepRow(_ step: MKRoute.Step) -> UIView {
        let icon = UIImageView(image: UIImage(systemName: Self.symbol(for: step.instructions)))
        icon.tintColor = MeetPalette.action
        icon.contentMode = .scaleAspectFit
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 22).isActive = true

        let text = UILabel()
        text.font = Type.font(16, .regular, .body)
        text.textColor = MeetPalette.primary
        text.numberOfLines = 0
        text.text = step.instructions
        let far = UILabel()
        far.font = Type.caption
        far.textColor = MeetPalette.secondary
        far.text = step.distance > 0 ? NearbyAlert.text(step.distance) : nil
        let texts = UIStackView(arrangedSubviews: [text, far])
        texts.axis = .vertical
        texts.spacing = 2

        let row = UIStackView(arrangedSubviews: [icon, texts])
        row.axis = .horizontal
        row.alignment = .top
        row.spacing = 14
        row.isLayoutMarginsRelativeArrangement = true
        row.layoutMargins = UIEdgeInsets(top: 12, left: 0, bottom: 12, right: 0)
        return row
    }

    /// 曲がる向きは案内文から拾う（MapKitは向きを別に渡してくれない）。
    static func symbol(for text: String) -> String {
        if text.contains("右") { return "arrow.turn.up.right" }
        if text.contains("左") { return "arrow.turn.up.left" }
        if text.contains("到着") || text.contains("目的地") { return "mappin.circle.fill" }
        return "arrow.up"
    }
}

// MARK: - 案内中の帯

/// 案内中の画面。上に次の曲がり角、下に残りと「終了」。
/// Googleマップ・Appleマップの案内と同じ置き方にする。
final class NavigationOverlay: UIView {

    /// 帯のないところは地図に指を渡す（地図を動かして先を見られるように）。
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }


    var onEnd: (() -> Void)?
    var onRecenter: (() -> Void)?

    /// どっちへ歩けばいいか。スマホが向いている方に対して、進む向きを矢印で出す
    /// （「右を向いて」「このまま まっすぐ」）。
    private let facing = UIView()
    private let facingArrow = UIImageView(image: UIImage(systemName: "arrow.up",
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .heavy)))
    private let facingLabel = UILabel()
    private let recenterButton = UIButton(type: .system)
    private let banner = UIView()
    private let turnIcon = UIImageView()
    private let turnDistance = UILabel()
    private let turnText = UILabel()
    private let bar = UIView()
    private let remain = UILabel()
    private let remainDetail = UILabel()
    private let endButton = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        banner.backgroundColor = FindScreen.ink
        banner.layer.cornerRadius = 20
        banner.layer.cornerCurve = .continuous
        turnIcon.tintColor = .white
        turnIcon.contentMode = .scaleAspectFit
        turnDistance.font = Type.font(26, .bold, .title2)
        turnDistance.textColor = .white
        turnText.font = Type.font(17, .semibold, .body)
        turnText.textColor = UIColor(white: 1, alpha: 0.9)
        turnText.numberOfLines = 2

        bar.backgroundColor = MeetPalette.surface
        bar.layer.cornerRadius = 22
        bar.layer.cornerCurve = .continuous
        bar.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        remain.font = Type.font(24, .bold, .title2)
        remain.textColor = MeetPalette.primary
        remainDetail.font = Type.caption
        remainDetail.textColor = MeetPalette.secondary

        var endConf = UIButton.Configuration.filled()
        endConf.title = "終了"
        endConf.baseBackgroundColor = UIColor.systemRed
        endConf.baseForegroundColor = .white
        endConf.cornerStyle = .capsule
        endConf.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 22, bottom: 12, trailing: 22)
        endConf.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in
            var a = attrs
            a.font = Type.font(17, .bold, .headline)
            return a
        }
        endButton.configuration = endConf
        endButton.addAction(UIAction { [weak self] _ in self?.onEnd?() }, for: .touchUpInside)

        let turnTexts = UIStackView(arrangedSubviews: [turnDistance, turnText])
        turnTexts.axis = .vertical
        turnTexts.spacing = 2
        let turnRow = UIStackView(arrangedSubviews: [turnIcon, turnTexts])
        turnRow.axis = .horizontal
        turnRow.alignment = .center
        turnRow.spacing = 14

        let remainTexts = UIStackView(arrangedSubviews: [remain, remainDetail])
        remainTexts.axis = .vertical
        remainTexts.spacing = 2
        let barRow = UIStackView(arrangedSubviews: [remainTexts, endButton])
        barRow.axis = .horizontal
        barRow.alignment = .center
        barRow.spacing = 12

        facing.backgroundColor = UIColor(white: 0.08, alpha: 0.85)
        facing.layer.cornerRadius = 22
        facing.layer.cornerCurve = .continuous
        facingArrow.tintColor = MeetPalette.action
        facingArrow.contentMode = .scaleAspectFit
        facingLabel.font = Type.font(17, .bold, .headline)
        facingLabel.textColor = .white
        let facingRow = UIStackView(arrangedSubviews: [facingArrow, facingLabel])
        facingRow.axis = .horizontal
        facingRow.alignment = .center
        facingRow.spacing = 10
        facing.isHidden = true

        var rc = UIButton.Configuration.filled()
        rc.title = "中央に戻す"
        rc.image = UIImage(systemName: "location.north.fill")
        rc.imagePadding = 6
        rc.baseBackgroundColor = MeetPalette.surface
        rc.baseForegroundColor = MeetPalette.action
        rc.cornerStyle = .capsule
        rc.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16)
        recenterButton.configuration = rc
        recenterButton.isHidden = true
        recenterButton.addAction(UIAction { [weak self] _ in self?.onRecenter?() }, for: .touchUpInside)

        for (parent, child) in [(banner, turnRow), (bar, barRow), (facing, facingRow)] as [(UIView, UIView)] {
            parent.addSubview(child)
            child.translatesAutoresizingMaskIntoConstraints = false
        }
        for v in [banner, bar, facing, recenterButton] {
            addSubview(v)
            v.translatesAutoresizingMaskIntoConstraints = false
        }
        let safe = safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            banner.topAnchor.constraint(equalTo: safe.topAnchor, constant: 8),
            banner.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            banner.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            turnRow.topAnchor.constraint(equalTo: banner.topAnchor, constant: 16),
            turnRow.bottomAnchor.constraint(equalTo: banner.bottomAnchor, constant: -16),
            turnRow.leadingAnchor.constraint(equalTo: banner.leadingAnchor, constant: 18),
            turnRow.trailingAnchor.constraint(equalTo: banner.trailingAnchor, constant: -18),
            turnIcon.widthAnchor.constraint(equalToConstant: 44),
            turnIcon.heightAnchor.constraint(equalToConstant: 44),

            bar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: bottomAnchor),
            barRow.topAnchor.constraint(equalTo: bar.topAnchor, constant: 18),
            barRow.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 22),
            barRow.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -18),
            barRow.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -8),

            facing.topAnchor.constraint(equalTo: banner.bottomAnchor, constant: 10),
            facing.centerXAnchor.constraint(equalTo: centerXAnchor),
            facingRow.topAnchor.constraint(equalTo: facing.topAnchor, constant: 10),
            facingRow.bottomAnchor.constraint(equalTo: facing.bottomAnchor, constant: -10),
            facingRow.leadingAnchor.constraint(equalTo: facing.leadingAnchor, constant: 16),
            facingRow.trailingAnchor.constraint(equalTo: facing.trailingAnchor, constant: -18),
            facingArrow.widthAnchor.constraint(equalToConstant: 26),
            facingArrow.heightAnchor.constraint(equalToConstant: 26),

            recenterButton.bottomAnchor.constraint(equalTo: bar.topAnchor, constant: -14),
            recenterButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
        ])
    }

    /// 進む向きを、スマホが向いている方との差（度、右が正）で出す。nil で隠す。
    func setFacing(_ degrees: Double?) {
        guard let degrees else { facing.isHidden = true; return }
        facing.isHidden = false
        let a = abs(degrees)
        facingLabel.text = a <= 25 ? "このまま まっすぐ"
            : a >= 135 ? "うしろを向いて"
            : degrees > 0 ? "右を向いて" : "左を向いて"
        facing.backgroundColor = a <= 25 ? UIColor(red: 0.12, green: 0.45, blue: 0.3, alpha: 0.92)
                                         : UIColor(white: 0.08, alpha: 0.85)
        facingArrow.tintColor = a <= 25 ? .white : MeetPalette.action
        UIView.animate(withDuration: 0.12, delay: 0,
                       options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut]) {
            self.facingArrow.transform = CGAffineTransform(rotationAngle: CGFloat(degrees * .pi / 180))
        }
    }

    func setRecenterVisible(_ visible: Bool) {
        recenterButton.isHidden = !visible
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(turn: String, distance: String, remaining: String, detail: String) {
        turnIcon.image = UIImage(systemName: RouteSheetViewController.symbol(for: turn),
                                 withConfiguration: UIImage.SymbolConfiguration(pointSize: 34, weight: .bold))
        turnDistance.text = distance
        turnText.text = turn
        remain.text = remaining
        remainDetail.text = detail
    }
}

// MARK: - 右下の小さな地図

/// 矢印やカメラの画面の右下に置く小さな地図（Googleマップのライブビューと同じ置き方）。
/// 地図は体の向きに合わせて回るので、上がそのまま「いま向いている方」になる。
/// 実際の道と、相手までの道なりの線と、相手の印だけを出す。見るだけで触らせない。
final class MiniMapView: UIView, MKMapViewDelegate {

    private let map = MKMapView()
    private var line: MKPolyline?
    private let peer = MKPointAnnotation()
    private var peerShown = false
    /// 足もとに寝かせる丸い地図にする（Android XRの、下を向くと出る地図）。
    var round = false {
        didSet {
            layer.borderWidth = round ? 0 : 2
            setNeedsLayout()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if round { layer.cornerRadius = bounds.width / 2 }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 18
        layer.cornerCurve = .continuous
        layer.borderWidth = 2
        layer.borderColor = UIColor(white: 1, alpha: 0.85).cgColor
        clipsToBounds = true

        map.delegate = self
        map.overrideUserInterfaceStyle = .unspecified
        map.showsUserLocation = true
        map.showsCompass = false
        map.isUserInteractionEnabled = false
        map.pointOfInterestFilter = .excludingAll
        if #available(iOS 16.0, *) {
            let config = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
            config.pointOfInterestFilter = .excludingAll
            map.preferredConfiguration = config
        }
        addSubview(map)
        map.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            map.topAnchor.constraint(equalTo: topAnchor),
            map.bottomAnchor.constraint(equalTo: bottomAnchor),
            map.leadingAnchor.constraint(equalTo: leadingAnchor),
            map.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 画面に出た時に呼ぶ。自分を真ん中に、向きに合わせて回し始める。
    func start() {
        map.setUserTrackingMode(.followWithHeading, animated: false)
        let camera = map.camera
        camera.centerCoordinateDistance = 450
        map.setCamera(camera, animated: false)
    }

    func stop() {
        map.setUserTrackingMode(.none, animated: false)
    }

    /// 相手までの道なりの線と、相手の居場所を貼り替える。
    func update(route: MKPolyline?, peer coordinate: CLLocationCoordinate2D?, name: String) {
        if route !== line {
            if let line { map.removeOverlay(line) }
            if let route { map.addOverlay(route) }
            line = route
        }
        if let coordinate {
            peer.coordinate = coordinate
            peer.title = name
            if !peerShown { map.addAnnotation(peer); peerShown = true }
        } else if peerShown {
            map.removeAnnotation(peer)
            peerShown = false
        }
        // 追いかけが外れていたら（地図が一度止まると外れる）戻す。
        if map.userTrackingMode != .followWithHeading, !isHidden {
            map.setUserTrackingMode(.followWithHeading, animated: false)
        }
    }

    func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
        let r = MKPolylineRenderer(overlay: overlay)
        r.strokeColor = MeetPalette.action
        r.lineWidth = 4
        return r
    }

    func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
        // 自分は丸ではなく、向いている方を指す三角（Android XRと同じ）。
        // 地図は体の向きに合わせて回っているので、上を指す三角がそのまま進む向きになる。
        if annotation is MKUserLocation {
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: "me")
                ?? MKAnnotationView(annotation: annotation, reuseIdentifier: "me")
            view.annotation = annotation
            view.image = NavArrow.image(size: 34)
            view.canShowCallout = false
            return view
        }
        guard annotation === peer else { return nil }
        let view = MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: "peer")
        view.markerTintColor = MeetPalette.arrival
        view.glyphText = (annotation.title ?? nil).flatMap { $0.first.map(String.init) }
        view.titleVisibility = .hidden
        return view
    }
}

// MARK: - カメラの上に乗せる札

/// カメラの映像の上に重ねる札。Googleのライブビュー（Android XRの説明画像）と同じく、
/// 暗い半透明の地に白い縁、左に印、右に2行。映像を隠しすぎないよう小さく保つ。
final class CameraCard: UIView {
    private let face = FaceView()
    private let icon = UIImageView()
    private let title = UILabel()
    private let subtitle = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(white: 0.06, alpha: 0.72)
        layer.cornerRadius = 22
        layer.cornerCurve = .continuous
        layer.borderWidth = 1.5
        layer.borderColor = UIColor(white: 1, alpha: 0.8).cgColor

        icon.tintColor = .white
        icon.contentMode = .scaleAspectFit
        title.font = Type.font(18, .bold, .headline)
        title.textColor = .white
        title.numberOfLines = 2
        subtitle.font = Type.font(15, .regular, .subheadline)
        subtitle.textColor = UIColor(white: 1, alpha: 0.85)
        subtitle.numberOfLines = 2

        let texts = UIStackView(arrangedSubviews: [title, subtitle])
        texts.axis = .vertical
        texts.spacing = 2
        let row = UIStackView(arrangedSubviews: [face, icon, texts])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 12
        addSubview(row)
        row.translatesAutoresizingMaskIntoConstraints = false
        for v in [face, icon] { v.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            face.widthAnchor.constraint(equalToConstant: 40),
            face.heightAnchor.constraint(equalToConstant: 40),
            icon.widthAnchor.constraint(equalToConstant: 34),
            icon.heightAnchor.constraint(equalToConstant: 34),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 人の札（顔・名前・距離）。
    func showPerson(name: String, image: UIImage?, detail: String) {
        face.isHidden = false
        icon.isHidden = true
        face.set(name: name, face: image)
        title.text = name
        subtitle.text = detail
    }

    /// 曲がり角の札（向きの矢印・案内・あと何m）。
    func showTurn(symbol: String, text: String, detail: String) {
        face.isHidden = true
        icon.isHidden = false
        icon.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 28, weight: .bold))
        title.text = text
        subtitle.text = detail
    }
}

// MARK: - 自分の三角

/// 自分の位置の印。青い丸に白い三角（Android XR・Googleマップの案内と同じ）。
enum NavArrow {
    /// 手描きの三角はやめて、SF Symbols の「location.north.circle.fill」を使う。
    static func image(size: CGFloat) -> UIImage {
        let config = UIImage.SymbolConfiguration(pointSize: size * 0.9)
            .applying(UIImage.SymbolConfiguration(paletteColors: [.white, .systemBlue]))
        return UIImage(systemName: "location.north.circle.fill", withConfiguration: config) ?? UIImage()
    }

    static func dot(size: CGFloat) -> UIImage {
        let config = UIImage.SymbolConfiguration(pointSize: size * 0.6)
            .applying(UIImage.SymbolConfiguration(paletteColors: [.systemBlue, .white]))
        return UIImage(systemName: "circle.inset.filled", withConfiguration: config) ?? UIImage()
    }
}

// MARK: - 地面に貼りつく地図

/// カメラの映像の足もとの床に貼りつく丸い地図（Android XRと同じ）。
/// 地図の画像は北が上。床に寝かせたうえで世界の北に向けるので、描かれた道は
/// 実際の道の向きと重なる。自分の三角だけは、いま向いている方へ回す。
/// 床の上に置くので、前を向いていれば目に入らず、下を向いたときだけ見える。
final class GroundMap {
    let root = SCNNode()
    private let disc = SCNNode()
    private let meYaw = SCNNode()
    private var center: CLLocation?
    private var routeRef: MKPolyline?
    private var snapshotAt = Date.distantPast
    private var working = false
    /// いま貼ってある地図の上が向いている方角（北から時計回りの度）。
    /// 北が上の地図を床に置くと、南を向いたとき文字が逆さまになる（9/29 実機）。
    /// 向いている方を上にして描き、文字を読める向きにする。
    private var snapHeading: Double = 0
    /// いま貼ってある地図に写っている範囲（半径 m）。
    private var shownRadius: CLLocationDistance = 0
    /// 床の上の地図の直径（m）。
    private let diameter: CGFloat = 1.3

    /// 写す範囲。相手が近いほど寄る（半径220mのままだと、15m先の相手が自分の三角の下に隠れた）。
    static func radius(toPeer metres: CLLocationDistance?) -> CLLocationDistance {
        guard let metres else { return 220 }
        return min(220, max(40, metres * 2.5))
    }

    /// 地図を描き直すか。動いた・向きが変わった・寄り具合が変わった・道なりの線が変わった。
    static func needsRedraw(moved: CLLocationDistance, radius: CLLocationDistance,
                            shownRadius: CLLocationDistance, headingChange: Double,
                            routeChanged: Bool) -> Bool {
        if routeChanged || shownRadius == 0 { return true }
        if moved > max(3, radius * 0.07) { return true }
        if abs(radius - shownRadius) > shownRadius * 0.3 { return true }
        return headingChange > 35
    }

    /// 2つの方角の差（0〜180度）。
    static func angleGap(_ a: Double, _ b: Double) -> Double {
        let d = abs((a - b).truncatingRemainder(dividingBy: 360))
        return d > 180 ? 360 - d : d
    }

    init() {
        let plane = SCNPlane(width: diameter, height: diameter)
        plane.cornerRadius = diameter / 2
        let material = SCNMaterial()
        material.diffuse.contents = UIColor.clear
        material.lightingModel = .constant
        material.isDoubleSided = true
        material.writesToDepthBuffer = false
        plane.materials = [material]
        disc.geometry = plane
        disc.eulerAngles.x = -.pi / 2
        root.addChildNode(disc)

        let arrow = SCNPlane(width: 0.17, height: 0.17)
        let arrowMaterial = SCNMaterial()
        arrowMaterial.diffuse.contents = NavArrow.image(size: 128)
        arrowMaterial.lightingModel = .constant
        arrowMaterial.isDoubleSided = true
        arrowMaterial.writesToDepthBuffer = false
        arrow.materials = [arrowMaterial]
        let arrowNode = SCNNode(geometry: arrow)
        arrowNode.eulerAngles.x = -.pi / 2
        arrowNode.position.y = 0.003
        arrowNode.renderingOrder = 10
        meYaw.addChildNode(arrowNode)
        root.addChildNode(meYaw)
        root.opacity = 0
    }

    /// 毎フレーム。カメラの前1.1mの床に置き、地図の上を北へ、三角を向いている方へ。
    /// 方角が取れないときは、向きの合わない地図を見せないよう消す。
    func place(camera: simd_float4x4, heading degrees: Double?) {
        guard let degrees, degrees >= 0 else { root.opacity = 0; return }
        let pos = simd_float3(camera.columns.3.x, camera.columns.3.y, camera.columns.3.z)
        let back = simd_float3(camera.columns.2.x, 0, camera.columns.2.z)   // カメラは -z を見ている
        let len = simd_length(back)
        guard len > 0.05 else { return }
        let forward = -back / len
        // 世界の向きの角度（-z が0、上から見て反時計回りが正）。
        let camYaw = atan2(-forward.x, -forward.z)
        // 貼ってある地図の上は snapHeading の方角。いま向いている方との差だけ回す。
        let turn = Float((degrees - snapHeading) * .pi / 180)   // 北から時計回り
        root.simdPosition = simd_float3(pos.x + forward.x * 1.1, pos.y - 1.25, pos.z + forward.z * 1.1)
        root.eulerAngles.y = camYaw + turn                  // 地図の上を、実際のその方角へ
        meYaw.eulerAngles.y = -turn                          // 三角は向いている方へ
        if root.opacity < 1 {
            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0.4
            root.opacity = 1
            SCNTransaction.commit()
        }
    }

    /// 地図の画像を作り直す。重いので、needsRedraw が言うときだけ・2秒に1回まで。
    func refresh(center me: CLLocation, heading: Double?, route: MKPolyline?,
                 peer: CLLocationCoordinate2D?, peerName: String) {
        guard let heading, heading >= 0 else { return }
        let moved = center.map { $0.distance(from: me) } ?? .greatestFiniteMagnitude
        let toPeer = peer.map { CLLocation(latitude: $0.latitude, longitude: $0.longitude).distance(from: me) }
        let radius = Self.radius(toPeer: toPeer)
        guard !working, Date().timeIntervalSince(snapshotAt) > 2,
              Self.needsRedraw(moved: moved, radius: radius, shownRadius: shownRadius,
                               headingChange: Self.angleGap(heading, snapHeading),
                               routeChanged: route !== routeRef) else { return }
        working = true
        snapshotAt = Date()
        let options = MKMapSnapshotter.Options()
        // 向いている方を上に。写る範囲の半分は高さの約0.268倍（MacのMapKitで実測 9/29）。
        options.camera = MKMapCamera(lookingAtCenter: me.coordinate, fromDistance: radius / 0.268,
                                     pitch: 0, heading: heading)
        options.size = CGSize(width: 512, height: 512)
        options.scale = 2
        options.traitCollection = UITraitCollection(userInterfaceStyle: .dark)
        options.pointOfInterestFilter = .excludingAll
        MKMapSnapshotter(options: options).start { [weak self] snapshot, _ in
            guard let self else { return }
            self.working = false
            guard let snapshot else { return }
            let image = Self.compose(snapshot, route: route, peer: peer, peerName: peerName)
            DispatchQueue.main.async {
                // 画像と、その画像の上の方角は同時に入れ替える（ずれた1コマを出さない）。
                (self.disc.geometry?.firstMaterial)?.diffuse.contents = image
                self.snapHeading = heading
                self.shownRadius = radius
                self.center = me
                self.routeRef = route
            }
        }
    }

    /// 地図に道なりの線と相手のピンを描き、丸く切り抜く。
    private static func compose(_ snapshot: MKMapSnapshotter.Snapshot, route: MKPolyline?,
                                peer: CLLocationCoordinate2D?, peerName: String) -> UIImage {
        let size = snapshot.image.size
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let g = ctx.cgContext
            let rect = CGRect(origin: .zero, size: size)
            g.addEllipse(in: rect)
            g.clip()
            snapshot.image.draw(at: .zero)
            UIColor(white: 0, alpha: 0.18).setFill()
            g.fill(rect)
            if let route, route.pointCount > 1 {
                let points = route.points()
                let path = UIBezierPath()
                for i in 0..<route.pointCount {
                    let p = snapshot.point(for: points[i].coordinate)
                    if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
                }
                path.lineWidth = 14
                path.lineCapStyle = .round
                path.lineJoinStyle = .round
                UIColor(red: 0.45, green: 0.75, blue: 1.0, alpha: 0.95).setStroke()
                path.stroke()
            }
            if let peer {
                let p = snapshot.point(for: peer)
                let pin = CGRect(x: p.x - 26, y: p.y - 26, width: 52, height: 52)
                UIColor(red: 0.98, green: 0.45, blue: 0.4, alpha: 1).setFill()
                g.fillEllipse(in: pin)
                UIColor.white.setStroke()
                g.setLineWidth(5)
                g.strokeEllipse(in: pin.insetBy(dx: 2.5, dy: 2.5))
                let initial = (peerName.first.map(String.init) ?? "?") as NSString
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 26, weight: .bold), .foregroundColor: UIColor.white]
                let t = initial.size(withAttributes: attrs)
                initial.draw(at: CGPoint(x: p.x - t.width / 2, y: p.y - t.height / 2), withAttributes: attrs)
            }
            // 縁を白く（床の上で地図の範囲が分かるように）。
            UIColor(white: 1, alpha: 0.7).setStroke()
            g.setLineWidth(8)
            g.strokeEllipse(in: rect.insetBy(dx: 4, dy: 4))
        }
    }
}

// MARK: - 場所の札（地図の店や駅を押したとき）

/// 選んだ場所の札。名前・種類・歩いて何分、下に「経路」と「ここで待ち合わせ」。
/// Appleマップ・Googleマップの場所の札と同じ並び。
final class PlaceCardViewController: UIViewController, MapSideSheet, UISheetPresentationControllerDelegate {
    private(set) var item: MKMapItem
    private var from: CLLocation?
    private var canMeet: Bool
    var onRoute: ((MKMapItem) -> Void)?
    var onMeet: ((MKMapItem) -> Void)?
    var onClose: (() -> Void)?
    /// いちばん近い駅の出口が分かった（地図に印を立てるため）。空なら印を消す。
    var onExits: (([StationExit]) -> Void)?

    private let titleLabel = UILabel()
    private let sub = UILabel()
    /// 「最寄りの出口：赤坂駅 5a出口（歩いて約2分）」。地下鉄でどこから出るか分かるように（9/28）。
    private let exitLabel = UILabel()
    private let buttons = UIStackView()
    private let header = UIStackView()
    private var detail: UIViewController?
    private var atPeek = false
    private var measuredPeek: CGFloat = 0

    init(item: MKMapItem, from: CLLocation?, canMeet: Bool) {
        self.item = item
        self.from = from
        self.canMeet = canMeet
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = MeetPalette.background
        titleLabel.font = Type.font(22, .bold, .title2)
        titleLabel.textColor = MeetPalette.primary
        titleLabel.numberOfLines = 2
        sub.font = Type.caption
        sub.textColor = MeetPalette.secondary
        sub.numberOfLines = 2
        buttons.axis = .horizontal
        buttons.spacing = 10
        buttons.distribution = .fillEqually

        exitLabel.font = Type.caption
        exitLabel.textColor = MeetPalette.primary
        exitLabel.numberOfLines = 0
        exitLabel.isHidden = true
        header.addArrangedSubview(titleLabel)
        header.addArrangedSubview(sub)
        header.addArrangedSubview(exitLabel)
        header.addArrangedSubview(buttons)
        header.axis = .vertical
        header.spacing = 4
        header.setCustomSpacing(16, after: sub)
        view.addSubview(header)
        header.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 22),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 22),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -22),
        ])
        if let sheet = sheetPresentationController { sheet.delegate = self }
        fill()
    }

    /// 別の場所を押された。札を出し直さずに、中身だけ入れ替える（Appleマップと同じ）。
    func update(item: MKMapItem, from: CLLocation?, canMeet: Bool) {
        self.item = item
        self.from = from
        self.canMeet = canMeet
        guard isViewLoaded else { return }
        fill()
    }

    private func fill() {
        titleLabel.text = item.name ?? "この場所"
        var parts: [String] = []
        if let kind = Self.kind(item.pointOfInterestCategory) { parts.append(kind) }
        if let from, let loc = item.placemark.location {
            let d = from.distance(from: loc)
            parts.append("\(NearbyAlert.text(d))・\(NearbyAlert.walkText(d))")
        }
        sub.text = parts.joined(separator: "・")
        loadExits()

        buttons.arrangedSubviews.forEach { $0.removeFromSuperview() }
        buttons.addArrangedSubview(button("経路", symbol: "figure.walk", primary: true) { [weak self] in
            guard let self else { return }
            self.onRoute?(self.item)
        })
        if canMeet {
            buttons.addArrangedSubview(button("ここで待ち合わせ", symbol: "flag.fill", primary: false) { [weak self] in
                guard let self else { return }
                self.onMeet?(self.item)
            })
        }

        // 店の詳しいこと（営業時間・電話・サイト・写真・評価）は、Appleマップと同じ
        // 標準の場所カード（MKMapItemDetailViewController）をそのまま下に埋める。
        // 自分で並べない（本人 9/25「押したのに詳細出てこなかった」「デザインは自前しないで」）。
        // 地図の店を押した直後は、まだ詳しいことが届いていない（識別子が無い）。届いたら埋める。
        if let old = detail {
            old.willMove(toParent: nil)
            old.view.removeFromSuperview()
            old.removeFromParent()
            detail = nil
        }
        if #available(iOS 18.0, *), item.identifier != nil {
            let card = MKMapItemDetailViewController(mapItem: item, displaysMap: false)
            card.delegate = self
            addChild(card)
            view.addSubview(card.view)
            card.view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                card.view.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 14),
                card.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                card.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                card.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
            card.didMove(toParent: self)
            card.view.alpha = atPeek ? 0 : 1
            detail = card
        }
        showTitleIfNeeded()
    }

    /// いちばん近い駅の出口を探して、距離の一行の下に出す。駅そのものを見ているときは出さない。
    private func loadExits() {
        exitLabel.isHidden = true
        onExits?([])
        guard item.pointOfInterestCategory != .publicTransport else { return }
        let shown = item
        let dest = item.placemark.coordinate
        Task { @MainActor [weak self] in
            let exits = StationExits.best(for: dest, among: await StationExits.around(dest))
            guard let self, self.item === shown, !exits.isEmpty else { return }
            let lines = exits.map { "\($0.label)（歩いて約\(StationExits.walkMinutes(from: $0, to: dest))分）" }
            let text = NSMutableAttributedString()
            if let icon = UIImage(systemName: "tram.fill")?.withTintColor(MeetPalette.action, renderingMode: .alwaysOriginal) {
                text.append(NSAttributedString(attachment: NSTextAttachment(image: icon)))
                text.append(NSAttributedString(string: " "))
            }
            text.append(NSAttributedString(string: "最寄りの出口：" + lines.joined(separator: "、")))
            text.append(NSAttributedString(string: "\n出口の場所 © OpenStreetMap",
                                           attributes: [.foregroundColor: MeetPalette.secondary,
                                                        .font: UIFont.preferredFont(forTextStyle: .caption2)]))
            self.exitLabel.attributedText = text
            self.exitLabel.isHidden = false
            self.header.setCustomSpacing(10, after: self.exitLabel)
            self.onExits?(exits)
        }
    }

    /// 名前は標準カードにも出るので、ふだんは距離の一行とボタンだけ。
    /// 下げたとき（標準カードが隠れる）と、標準カードがまだ無いときだけ、こちらにも名前を出す。
    private func showTitleIfNeeded() {
        titleLabel.isHidden = detail != nil && !atPeek
    }

    // MARK: MapSideSheet

    /// 下げたときは、名前・距離・ボタンまで見せる（名前が隠れていても、その分を足して測る）。
    var peekHeight: CGFloat { measuredPeek > 0 ? measuredPeek : 170 }

    func didSettle(peek: Bool) {
        atPeek = peek
        showTitleIfNeeded()
        // 下げたときは、標準カードの頭が下からのぞかないように隠す。
        UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.detail?.view.alpha = peek ? 0 : 1
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let width = header.bounds.width
        guard width > 0 else { return }
        let titleBlock = titleLabel.isHidden
            ? titleLabel.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height + header.spacing
            : 0
        let h = header.frame.maxY + titleBlock + 16
        guard abs(h - measuredPeek) > 1 else { return }
        measuredPeek = h
        if #available(iOS 16.0, *) { sheetPresentationController?.invalidateDetents() }
    }

    func sheetPresentationControllerDidChangeSelectedDetentIdentifier(_ sheet: UISheetPresentationController) {
        guard #available(iOS 16.0, *) else { return }
        didSettle(peek: sheet.selectedDetentIdentifier == .peek)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        onClose?()
    }

    private func button(_ title: String, symbol: String, primary: Bool, action: @escaping () -> Void) -> UIButton {
        var conf = UIButton.Configuration.filled()
        conf.title = title
        conf.image = UIImage(systemName: symbol)
        conf.imagePadding = 6
        conf.baseBackgroundColor = primary ? MeetPalette.action : MeetPalette.raised
        conf.baseForegroundColor = primary ? MeetPalette.onAction : MeetPalette.primary
        conf.cornerStyle = .capsule
        conf.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 10, bottom: 12, trailing: 10)
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

    static func kind(_ c: MKPointOfInterestCategory?) -> String? {
        guard let c else { return nil }
        let names: [MKPointOfInterestCategory: String] = [
            .cafe: "カフェ", .restaurant: "ごはん", .bakery: "パン", .foodMarket: "食料品店",
            .store: "お店", .pharmacy: "薬局", .park: "公園", .publicTransport: "駅・のりば",
            .museum: "美術館・博物館", .library: "図書館", .hotel: "ホテル", .parking: "駐車場",
            .restroom: "トイレ", .atm: "ATM", .bank: "銀行", .hospital: "病院", .school: "学校",
            .movieTheater: "映画館", .nightlife: "夜のお店", .fitnessCenter: "ジム",
        ]
        return names[c]
    }
}

@available(iOS 18.0, *)
extension PlaceCardViewController: MKMapItemDetailViewControllerDelegate {
    /// 標準カードの × は、この札ごと閉じる。
    func mapItemDetailViewControllerDidFinish(_ detailViewController: MKMapItemDetailViewController) {
        dismiss(animated: true)
    }
}

// MARK: - 場所を検索

