// おつかい — 相手が店の前にいる、その時間だけ意味を持つ機能。
//
// 買い物アプリを足したのではない。「ついでに買ってきて」が成立するのは、
// 相手がいまどこにいるかを知っている側だけで、それはこのアプリが既に持っている。
//
// 決めごと:
//  - 店は「相手の居場所」から探す。こちらで店を検索させない（起点は相手の現在地）
//  - 遠いときは中継（RemoteMeet）で届く。近ければMPCでも届く。同じ中身を両方に投げる
//  - 届いたかは「買えた」の返事でしか分からない。返事が来るまで数回だけ送り直す
import Foundation
import UIKit
import MapKit

// MARK: - やりとりする中身

/// 買わずに近づいたら知らせる（10/3 本人「買わずに近づいたら通知して欲しい」）。
/// 頼まれた側には「まだです」、頼んだ側には「まだ買わずに近づいています」。どちらも端末の中で決める。
enum ErrandReminder {
    /// これより近づいたら知らせる。まだ途中の店に寄れる距離にしておく。
    static let metres: Double = 1000

    /// 知らせるか。頼んだとき既に近かったら鳴らさない（頼んだ直後に「まだです」と言わない）。
    /// いったん1.2倍より遠くにいたことを見てから（armed）、決めた距離に入ったときに1回だけ。
    /// 返すのは（いま知らせるか, 次の armed）。
    static func step(left: Int, metres distance: Double?, armed: Bool, reminded: Bool) -> (remind: Bool, armed: Bool) {
        guard let distance else { return (false, armed) }
        let nowArmed = armed || distance > metres * 1.2
        guard left > 0, !reminded, nowArmed, distance <= metres else { return (false, nowArmed) }
        return (true, nowArmed)
    }
}

/// 買ってきてほしい物リスト。
struct ErrandMessage: Codable {
    var type: String = "errand"
    /// 送り直しと返事を結びつけるための番号。
    var id: String
    /// 送った人の名前（相手の画面に出る）。
    var from: String
    /// 相手のそばにあった店の名前。見つからなければ空。
    var place: String
    var items: [String]
    var at: Double = Date().timeIntervalSince1970 * 1000

    var placeText: String { place.isEmpty ? "近くのお店" : place }
}

/// 頼まれた側の返事。買えた物と、終わったかどうか。
/// これが返ってきた時点で「届いた」ことも同時に分かる。
struct ErrandStatusMessage: Codable {
    var type: String = "errandStatus"
    var id: String
    var got: [String]
    var done: Bool
}

// MARK: - 相手のそばの店

/// 相手の居場所のまわりにある店。MapKit が持っている地図の店をそのまま使う
/// （店の一覧を自前で持たない）。
enum NearbyStore {

    struct Found: Equatable {
        let name: String
        /// 相手からの距離（m）。遠い店を「そこにいる」と言わないための値。
        let metres: Double
    }

    /// 買い物を頼める店。地図に「コンビニ」という区分は無いので、食料品店・
    /// パン屋・薬局を主にし、それ以外の店（Store）は本当にすぐそばの時だけ拾う。
    /// 服屋や美容室まで同じ扱いにすると、街なかでは常に何かが当たってしまう。
    private static let mainCategories: [MKPointOfInterestCategory] = [.foodMarket, .bakery, .pharmacy]

    /// 相手の居場所から半径200mを見て、近い順に店を返す。
    /// 主な店は150mまで、それ以外の店は60mまで（道の反対側までが限度）。
    /// ここで1つに決めないのは、どの店で買うかを決めるのは人だから
    /// （いちばん近いのが薬局で、頼みたいのは隣のスーパー、ということがある）。
    static func around(_ centre: CLLocationCoordinate2D, completion: @escaping ([Found]) -> Void) {
        let request = MKLocalPointsOfInterestRequest(center: centre, radius: 200)
        request.pointOfInterestFilter = MKPointOfInterestFilter(including: mainCategories + [.store])
        let here = CLLocation(latitude: centre.latitude, longitude: centre.longitude)
        MKLocalSearch(request: request).start { response, _ in
            let all = (response?.mapItems ?? []).compactMap { item -> (Found, Bool)? in
                guard let name = item.name, let location = item.placemark.location else { return nil }
                let main = item.pointOfInterestCategory.map(mainCategories.contains) ?? false
                return (Found(name: name, metres: here.distance(from: location)), main)
            }
            // 食べ物・薬の店を先に、それ以外はその後ろ。新宿のような街では
            // 60m以内に質屋も時計屋も入ってくるので、順番で押しのける。
            let kept = all.filter { ($0.1 && $0.0.metres <= 150) || $0.0.metres <= 60 }
                .sorted { ($0.1 ? 0 : 1, $0.0.metres) < ($1.1 ? 0 : 1, $1.0.metres) }
                .map { $0.0 }
            // 同じ名前の店が複数の区分で返ることがある。名前で一度だけ。
            var seen = Set<String>()
            let unique = kept.filter { seen.insert($0.name).inserted }
            DispatchQueue.main.async { completion(Array(unique.prefix(4))) }
        }
    }
}

// MARK: - 頼む側の画面

/// 頼む物を選ぶだけの画面。文字を打たずに終われることを優先する
/// （片手で、歩きながら開くことが多い）。
final class ErrandComposeViewController: UIViewController {

    private static let presets = ["牛乳", "卵", "パン", "お米", "飲みもの", "お菓子", "ティッシュ", "洗剤"]

    private let partner: String
    /// 相手のそばにあった店（近い順）。いちばん近い店を最初に選んでおくが、
    /// 決めるのは人。押して変えられる。
    private let places: [NearbyStore.Found]
    /// いま選んでいる店。-1 は「店を決めない」。
    private var placeIndex: Int
    private var chosen: [String] = []
    private var extras: [String] = []
    private let placeChips = WrappingRow()
    private let where_ = UILabel()
    private let chips = WrappingRow()
    private let sendButton = CapsuleButton(type: .system)
    private let onSend: (String, [String]) -> Void

    /// 選んでいる店の名前。決めていなければ空。
    private var place: String { places.indices.contains(placeIndex) ? places[placeIndex].name : "" }

    init(partner: String, places: [NearbyStore.Found], preset: [String] = [],
         onSend: @escaping (String, [String]) -> Void) {
        self.partner = partner
        self.places = places
        self.placeIndex = places.isEmpty ? -1 : 0
        self.onSend = onSend
        super.init(nibName: nil, bundle: nil)
        // AIに頼むの「直す」から来たとき、読み取った品物を選んだ状態で開く。
        chosen = preset
        extras = preset.filter { !Self.presets.contains($0) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = MeetPalette.background

        let title = UILabel()
        title.font = Type.headline
        title.textColor = MeetPalette.primary
        title.numberOfLines = 2
        title.text = "\(partner)に買ってきてもらう"

        where_.font = Type.caption
        where_.textColor = MeetPalette.secondary
        where_.numberOfLines = 2

        placeChips.spacing = 8
        placeChips.lineSpacing = 8
        rebuildPlaces()

        let itemsTitle = UILabel()
        itemsTitle.font = Type.caption
        itemsTitle.textColor = MeetPalette.secondary
        itemsTitle.text = "頼む物"

        chips.spacing = 8
        chips.lineSpacing = 8
        rebuildChips()

        var other = UIButton.Configuration.plain()
        other.title = "ほかの物を足す"
        other.image = UIImage(systemName: "plus.circle")
        other.imagePadding = 6
        other.baseForegroundColor = MeetPalette.action
        other.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0)
        let otherButton = UIButton(type: .system)
        otherButton.configuration = other
        otherButton.contentHorizontalAlignment = .leading
        otherButton.addTarget(self, action: #selector(addOther), for: .touchUpInside)

        sendButton.addTarget(self, action: #selector(send), for: .touchUpInside)
        refreshSendButton()

        var cancel = UIButton.Configuration.plain()
        cancel.title = "やめる"
        cancel.baseForegroundColor = MeetPalette.secondary
        let cancelButton = UIButton(type: .system)
        cancelButton.configuration = cancel
        cancelButton.addTarget(self, action: #selector(close), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [title, where_, placeChips, itemsTitle, chips,
                                                   otherButton, sendButton, cancelButton])
        stack.axis = .vertical
        stack.spacing = 12
        stack.setCustomSpacing(4, after: title)
        stack.setCustomSpacing(8, after: where_)
        stack.setCustomSpacing(18, after: placeChips)
        stack.setCustomSpacing(6, after: itemsTitle)
        stack.setCustomSpacing(18, after: chips)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
        ])
    }

    /// お店の札。近い順に並べ、いちばん近い店を最初に選んでおく。
    /// 最後の「決めない」は、地図が拾った店がどれも違うときの逃げ道。
    private func rebuildPlaces() {
        placeChips.subviews.forEach { $0.removeFromSuperview() }
        placeChips.isHidden = places.isEmpty
        for (index, found) in places.enumerated() {
            placeChips.addSubview(placeChip(title: found.name,
                                            detail: "\(Int(found.metres.rounded()))m",
                                            selected: index == placeIndex,
                                            action: { [weak self] in self?.choosePlace(index) }))
        }
        if !places.isEmpty {
            placeChips.addSubview(placeChip(title: "決めない", detail: nil, selected: placeIndex < 0,
                                            action: { [weak self] in self?.choosePlace(-1) }))
        }
        placeChips.setNeedsLayout()
        refreshWhere()
    }

    private func placeChip(title: String, detail: String?, selected: Bool,
                           action: @escaping () -> Void) -> UIButton {
        let button = CapsuleButton(type: .system)
        var conf = UIButton.Configuration.filled()
        conf.title = detail.map { "\(title)・\($0)" } ?? title
        conf.image = selected ? UIImage(systemName: "checkmark") : nil
        conf.imagePadding = 6
        conf.baseBackgroundColor = selected ? MeetPalette.primary : MeetPalette.raised
        conf.baseForegroundColor = selected ? MeetPalette.background : MeetPalette.primary
        conf.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16)
        conf.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in
            var a = attrs
            a.font = Type.chip
            return a
        }
        button.configuration = conf
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return button
    }

    private func choosePlace(_ index: Int) {
        placeIndex = index
        UISelectionFeedbackGenerator().selectionChanged()
        rebuildPlaces()
    }

    private func refreshWhere() {
        if places.isEmpty {
            where_.text = "相手のいる場所の近くのお店"
        } else if place.isEmpty {
            where_.text = "お店は決めません"
        } else {
            where_.text = "\(partner)は「\(place)」のそば。違うお店なら押して変えられます"
        }
    }

    private func rebuildChips() {
        chips.subviews.forEach { $0.removeFromSuperview() }
        for item in Self.presets + extras {
            let selected = chosen.contains(item)
            let button = CapsuleButton(type: .system)
            var conf = UIButton.Configuration.filled()
            conf.title = item
            conf.image = selected ? UIImage(systemName: "checkmark") : nil
            conf.imagePadding = 6
            conf.baseBackgroundColor = selected ? MeetPalette.action : MeetPalette.raised
            conf.baseForegroundColor = selected ? MeetPalette.onAction : MeetPalette.primary
            conf.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16)
            conf.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in
                var a = attrs
                a.font = Type.chip
                return a
            }
            button.configuration = conf
            button.addAction(UIAction { [weak self] _ in self?.toggle(item) }, for: .touchUpInside)
            chips.addSubview(button)
        }
        chips.setNeedsLayout()
    }

    private func toggle(_ item: String) {
        if let index = chosen.firstIndex(of: item) { chosen.remove(at: index) } else { chosen.append(item) }
        UISelectionFeedbackGenerator().selectionChanged()
        rebuildChips()
        refreshSendButton()
    }

    private func refreshSendButton() {
        var conf = UIButton.Configuration.filled()
        conf.title = chosen.isEmpty ? "頼む物を選んでください" : "\(chosen.count)個 頼む"
        conf.image = UIImage(systemName: "cart.fill")
        conf.imagePadding = 10
        conf.baseBackgroundColor = chosen.isEmpty ? MeetPalette.raised : MeetPalette.action
        conf.baseForegroundColor = chosen.isEmpty ? MeetPalette.secondary : MeetPalette.onAction
        conf.cornerStyle = .capsule
        conf.contentInsets = NSDirectionalEdgeInsets(top: 16, leading: 24, bottom: 16, trailing: 24)
        conf.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in
            var a = attrs
            a.font = Type.appName
            return a
        }
        sendButton.configuration = conf
        sendButton.isEnabled = !chosen.isEmpty
    }

    @objc private func addOther() {
        let alert = UIAlertController(title: "買ってきてほしい物", message: nil, preferredStyle: .alert)
        alert.addTextField { $0.placeholder = "例: 納豆" }
        alert.addAction(UIAlertAction(title: "やめる", style: .cancel))
        alert.addAction(UIAlertAction(title: "足す", style: .default) { [weak self] _ in
            guard let self else { return }
            let text = cleanName(alert.textFields?.first?.text ?? "")
            guard !text.isEmpty, !Self.presets.contains(text), !self.extras.contains(text) else { return }
            self.extras.append(text)
            self.chosen.append(text)
            self.rebuildChips()
            self.refreshSendButton()
        })
        present(alert, animated: true)
    }

    @objc private func send() {
        guard !chosen.isEmpty else { return }
        onSend(place, chosen)
        dismiss(animated: true)
    }

    @objc private func close() { dismiss(animated: true) }
}

// MARK: - 頼まれた側の画面

/// 届いたリスト。買えた物を押すだけで、頼んだ側の画面がその場で変わる。
final class ErrandListViewController: UIViewController {

    private let errand: ErrandMessage
    private var got: [String]
    private let rows = UIStackView()
    private let onChange: ([String], Bool) -> Void

    init(errand: ErrandMessage, got: [String], onChange: @escaping ([String], Bool) -> Void) {
        self.errand = errand
        self.got = got
        self.onChange = onChange
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = MeetPalette.background

        let title = UILabel()
        title.font = Type.headline
        title.textColor = MeetPalette.primary
        title.numberOfLines = 2
        title.text = "\(errand.from)からのおつかい"

        let place = UILabel()
        place.font = Type.caption
        place.textColor = MeetPalette.secondary
        place.numberOfLines = 2
        place.text = "\(errand.placeText)にいるあいだに頼まれました"

        rows.axis = .vertical
        rows.spacing = 8
        rebuildRows()

        let done = CapsuleButton(type: .system)
        var conf = UIButton.Configuration.filled()
        conf.title = "終わりにする"
        conf.image = UIImage(systemName: "checkmark.circle.fill")
        conf.imagePadding = 10
        conf.baseBackgroundColor = MeetPalette.action
        conf.baseForegroundColor = MeetPalette.onAction
        conf.cornerStyle = .capsule
        conf.contentInsets = NSDirectionalEdgeInsets(top: 16, leading: 24, bottom: 16, trailing: 24)
        conf.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in
            var a = attrs
            a.font = Type.appName
            return a
        }
        done.configuration = conf
        done.addTarget(self, action: #selector(finish), for: .touchUpInside)

        var later = UIButton.Configuration.plain()
        later.title = "あとで見る"
        later.baseForegroundColor = MeetPalette.secondary
        let laterButton = UIButton(type: .system)
        laterButton.configuration = later
        laterButton.addTarget(self, action: #selector(close), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [title, place, rows, done, laterButton])
        stack.axis = .vertical
        stack.spacing = 12
        stack.setCustomSpacing(4, after: title)
        stack.setCustomSpacing(18, after: rows)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
        ])
    }

    private func rebuildRows() {
        rows.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for item in errand.items {
            let bought = got.contains(item)
            let button = UIButton(type: .system)
            var conf = UIButton.Configuration.filled()
            conf.title = item
            conf.image = UIImage(systemName: bought ? "checkmark.circle.fill" : "circle")
            conf.imagePadding = 12
            conf.baseBackgroundColor = bought ? MeetPalette.raised : MeetPalette.surface
            conf.baseForegroundColor = bought ? MeetPalette.secondary : MeetPalette.primary
            conf.cornerStyle = .large
            conf.contentInsets = NSDirectionalEdgeInsets(top: 16, leading: 18, bottom: 16, trailing: 18)
            conf.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in
                var a = attrs
                a.font = Type.headline
                return a
            }
            button.configuration = conf
            button.contentHorizontalAlignment = .leading
            button.addAction(UIAction { [weak self] _ in self?.toggle(item) }, for: .touchUpInside)
            rows.addArrangedSubview(button)
        }
    }

    private func toggle(_ item: String) {
        if let index = got.firstIndex(of: item) { got.remove(at: index) } else { got.append(item) }
        UISelectionFeedbackGenerator().selectionChanged()
        rebuildRows()
        // 押した瞬間に相手の画面へ返す。買い物の途中で「まだ？」と聞かれないように。
        onChange(got, false)
    }

    @objc private func finish() {
        onChange(got, true)
        dismiss(animated: true)
    }

    @objc private func close() {
        onChange(got, false)
        dismiss(animated: true)
    }
}
