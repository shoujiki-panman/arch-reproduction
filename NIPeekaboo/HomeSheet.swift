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
        initial.textColor = MeetPalette.background
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

    private let stack = UIStackView()
    private let grabber = UIView()
    /// 引き上げたときだけ出る行（様子・追加・やめる）。
    private let more = UIStackView()
    private(set) var expanded = false
    private var mode: Mode?

    override init(frame: CGRect) {
        super.init(frame: frame)
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

    func render(_ mode: Mode) {
        self.mode = mode
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        more.arrangedSubviews.forEach { $0.removeFromSuperview() }
        switch mode {
        case let .peer(peer, canInvite):
            stack.addArrangedSubview(peerRow(peer))
            for line in [peer.pinName.map { "待ち合わせ：\($0)" }, peer.errandText.map { "おつかい：\($0)" }] {
                guard let line else { continue }
                stack.addArrangedSubview(statusLine(line))
            }
            stack.addArrangedSubview(tiles(peer))
            more.addArrangedSubview(moreRow("いまの様子を伝える", symbol: "text.bubble", action: onMood))
            if canInvite {
                more.addArrangedSubview(moreRow("人を追加（リンク）", symbol: "plus.circle", action: onInvite))
            }
            more.addArrangedSubview(moreRow("共有をやめる", symbol: "xmark.circle", action: onEnd, danger: true))
        case let .friends(friends, waitingLine, canInvite, canEnd):
            stack.addArrangedSubview(sectionTitle(!friends.isEmpty ? "友だち"
                                                  : waitingLine != nil ? "待っています" : "はじめる"))
            if let waitingLine { stack.addArrangedSubview(statusLine(waitingLine)) }
            for (index, friend) in friends.enumerated() {
                stack.addArrangedSubview(friendRow(friend, index: index))
            }
            if canInvite {
                stack.addArrangedSubview(moreRow(waitingLine != nil ? "リンクを共有"
                                                 : friends.isEmpty ? "招待リンクを送る" : "人を追加（リンク）",
                                                 symbol: "plus.circle.fill", action: onInvite, accent: true))
            }
            if canEnd {
                stack.addArrangedSubview(moreRow("やめる", symbol: "xmark.circle", action: onEnd, danger: true))
            }
        }
        if !more.arrangedSubviews.isEmpty {
            more.isHidden = !expanded
            stack.addArrangedSubview(more)
        }
    }

    func setExpanded(_ open: Bool) {
        guard expanded != open else { return }
        expanded = open
        UISelectionFeedbackGenerator().selectionChanged()
        Trans.run(Trans.smoothOut(Trans.fast)) {
            self.more.isHidden = !open
            self.more.alpha = open ? 1 : 0
            self.superview?.layoutIfNeeded()
        }
    }

    @objc private func panned(_ pan: UIPanGestureRecognizer) {
        guard pan.state == .ended else { return }
        let dy = pan.translation(in: self).y
        let vy = pan.velocity(in: self).y
        if dy < -20 || vy < -300 { setExpanded(true) } else if dy > 20 || vy > 300 { setExpanded(false) }
    }

    @objc private func grabberTapped(_ tap: UITapGestureRecognizer) {
        // つまみのまわり（上の帯）を押したときだけ。行やタイルの押下は邪魔しない。
        guard tap.location(in: self).y < 30 else { return }
        setExpanded(!expanded)
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
            conf.baseForegroundColor = strong ? MeetPalette.background : MeetPalette.primary
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
            conf.baseForegroundColor = MeetPalette.background
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
            Trans.run(Trans.smoothOut(Trans.fast)) {
                self.arrow.transform = CGAffineTransform(rotationAngle: angle)
            }
        } else {
            arrow.isHidden = true
        }
    }
}

// MARK: - 経路（アプリの中で）

/// 徒歩の経路の一覧。上に「徒歩◯分・◯km」、下に曲がり角を順に並べる。
/// 地図の線と一緒に見るので、シートは半分の高さで止める。
final class RouteSheetViewController: UIViewController {

    private let route: MKRoute
    private let name: String
    /// 「案内開始」が押された。
    var onStart: (() -> Void)?

    init(route: MKRoute, name: String) {
        self.route = route
        self.name = name
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
        title.text = "\(name)まで 徒歩\(minutes)分"
        let sub = UILabel()
        sub.font = Type.caption
        sub.textColor = MeetPalette.secondary
        sub.text = "\(NearbyAlert.text(route.distance))・道なり・相手が動くと変わります"

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
        startConf.baseForegroundColor = MeetPalette.background
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

        let scroll = UIScrollView()
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

        for (parent, child) in [(banner, turnRow), (bar, barRow)] as [(UIView, UIView)] {
            parent.addSubview(child)
            child.translatesAutoresizingMaskIntoConstraints = false
        }
        for v in [banner, bar] {
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
        ])
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
        map.overrideUserInterfaceStyle = .dark
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
    static func image(size: CGFloat) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).image { ctx in
            let rect = CGRect(x: 0, y: 0, width: size, height: size)
            let g = ctx.cgContext
            g.setFillColor(UIColor(red: 0.26, green: 0.45, blue: 1.0, alpha: 0.95).cgColor)
            g.fillEllipse(in: rect.insetBy(dx: 1, dy: 1))
            g.setStrokeColor(UIColor.white.cgColor)
            g.setLineWidth(size * 0.06)
            g.strokeEllipse(in: rect.insetBy(dx: size * 0.04, dy: size * 0.04))
            // 上を指す矢じり（下が切れ込んだ三角）。
            let c = size / 2
            let path = UIBezierPath()
            path.move(to: CGPoint(x: c, y: size * 0.2))
            path.addLine(to: CGPoint(x: size * 0.74, y: size * 0.76))
            path.addLine(to: CGPoint(x: c, y: size * 0.62))
            path.addLine(to: CGPoint(x: size * 0.26, y: size * 0.76))
            path.close()
            UIColor.white.setFill()
            path.fill()
        }
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
    /// 地図に写す範囲（半径 m）と、床の上の直径（m）。
    private let radius: CLLocationDistance = 220
    private let diameter: CGFloat = 1.3

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
        let heading = Float(degrees * .pi / 180)          // 北から時計回り
        root.simdPosition = simd_float3(pos.x + forward.x * 1.1, pos.y - 1.25, pos.z + forward.z * 1.1)
        root.eulerAngles.y = camYaw + heading              // 地図の上（北）を世界の北へ
        meYaw.eulerAngles.y = -heading                      // 三角は向いている方へ
        if root.opacity < 1 {
            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0.4
            root.opacity = 1
            SCNTransaction.commit()
        }
    }

    /// 地図の画像を作り直す。15m以上動いたか、道なりの線が変わったときだけ（重いので）。
    func refresh(center me: CLLocation, route: MKPolyline?, peer: CLLocationCoordinate2D?, peerName: String) {
        let moved = center.map { $0.distance(from: me) } ?? .greatestFiniteMagnitude
        guard !working, moved > 15 || route !== routeRef,
              Date().timeIntervalSince(snapshotAt) > 2 else { return }
        working = true
        snapshotAt = Date()
        let options = MKMapSnapshotter.Options()
        options.region = MKCoordinateRegion(center: me.coordinate,
                                            latitudinalMeters: radius * 2, longitudinalMeters: radius * 2)
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
                (self.disc.geometry?.firstMaterial)?.diffuse.contents = image
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
