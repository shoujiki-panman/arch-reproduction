// まわりを見る — 待っているあいだ、近づいているあいだの「ここ何がある？」。
//
// 合流アプリの空き時間は、たいてい相手を待つ時間。そこに出すものは
// 距離の数字ではなく、いまいる場所のまわりにある行き先のほうが役に立つ。
//
// 決めごと:
//  - 場所は地図（MapKit）が持っているものをそのまま出す。店の一覧を自前で持たない
//  - イベントの日時や名前は、地図が持っていないので作らない。
//    いまは「イベントがある場所（会場）」までを出す
//  - 押したら地図アプリに渡す。案内はそちらのほうが上手い
import Foundation
import UIKit
import MapKit

enum ExploreSpots {

    struct Spot {
        let name: String
        let label: String
        let metres: Double
        let item: MKMapItem
    }

    /// 待ち時間に行ける場所。「お店」全部は入れない
    /// （医療機器の卸まで「いま行けるところ」に並んで、役に立たなかった）。
    private static let places: [MKPointOfInterestCategory] = [.cafe, .bakery, .restaurant, .park]
    /// イベントが行われる場所。日時までは地図が持っていないので、会場までを出す。
    /// ライブハウスと展示会場は iOS 18 から地図に区分がある。古い端末では出ないだけ。
    private static var venues: [MKPointOfInterestCategory] {
        var list: [MKPointOfInterestCategory] = [.theater, .movieTheater, .museum, .stadium, .amusementPark]
        if #available(iOS 18.0, *) { list += [.musicVenue, .conventionCenter] }
        return list
    }

    private static var labels: [MKPointOfInterestCategory: String] {
        var map: [MKPointOfInterestCategory: String] = [
            .cafe: "カフェ", .bakery: "パン", .restaurant: "ごはん", .park: "公園",
            .theater: "劇場", .movieTheater: "映画", .museum: "美術館・博物館",
            .stadium: "スタジアム", .amusementPark: "遊園地",
        ]
        if #available(iOS 18.0, *) {
            map[.musicVenue] = "ライブ"
            map[.conventionCenter] = "イベント会場"
        }
        return map
    }

    /// いまいる場所のまわり800m。近い順に。
    static func around(_ centre: CLLocationCoordinate2D,
                       completion: @escaping (_ places: [Spot], _ venues: [Spot]) -> Void) {
        let request = MKLocalPointsOfInterestRequest(center: centre, radius: 800)
        request.pointOfInterestFilter = MKPointOfInterestFilter(including: places + venues)
        let here = CLLocation(latitude: centre.latitude, longitude: centre.longitude)
        MKLocalSearch(request: request).start { response, _ in
            var found: [(Spot, Bool)] = []
            for item in response?.mapItems ?? [] {
                guard let name = item.name, let location = item.placemark.location,
                      let category = item.pointOfInterestCategory else { continue }
                let spot = Spot(name: name, label: labels[category] ?? "スポット",
                                metres: here.distance(from: location), item: item)
                found.append((spot, venues.contains(category)))
            }
            let sorted = found.sorted { $0.0.metres < $1.0.metres }
            DispatchQueue.main.async {
                completion(Array(sorted.filter { !$0.1 }.map(\.0).prefix(8)),
                           Array(sorted.filter { $0.1 }.map(\.0).prefix(6)))
            }
        }
    }
}

/// まわりにある場所を並べるだけの画面。押すと地図アプリが開く。
final class ExploreViewController: UIViewController {

    private let centre: CLLocationCoordinate2D?
    private let rows = UIStackView()
    private let status = UILabel()

    init(centre: CLLocationCoordinate2D?) {
        self.centre = centre
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = MeetPalette.background

        let title = UILabel()
        title.font = Type.headline
        title.textColor = MeetPalette.primary
        title.text = "まわりを見る"

        let subtitle = UILabel()
        subtitle.font = Type.caption
        subtitle.textColor = MeetPalette.secondary
        subtitle.numberOfLines = 2
        subtitle.text = "いまいる場所から800mの中にあるもの"

        status.font = Type.caption
        status.textColor = MeetPalette.secondary
        status.numberOfLines = 2
        status.text = "探しています…"

        rows.axis = .vertical
        rows.spacing = 8

        var close = UIButton.Configuration.plain()
        close.title = "閉じる"
        close.baseForegroundColor = MeetPalette.secondary
        let closeButton = UIButton(type: .system)
        closeButton.configuration = close
        closeButton.addTarget(self, action: #selector(dismissSelf), for: .touchUpInside)

        let column = UIStackView(arrangedSubviews: [title, subtitle, status, rows, closeButton])
        column.axis = .vertical
        column.spacing = 12
        column.setCustomSpacing(4, after: title)
        column.setCustomSpacing(16, after: rows)

        // 数が多いと画面から出るので、中身ごと巻き取る。
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        column.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(column)
        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            column.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 24),
            column.leadingAnchor.constraint(equalTo: scroll.leadingAnchor, constant: 24),
            column.trailingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: -24),
            column.bottomAnchor.constraint(equalTo: scroll.bottomAnchor, constant: -24),
            column.widthAnchor.constraint(equalTo: scroll.widthAnchor, constant: -48),
        ])

        guard let centre else {
            status.text = "いまいる場所がまだ分かりません"
            return
        }
        ExploreSpots.around(centre) { [weak self] places, venues in
            self?.show(places: places, venues: venues)
        }
    }

    private func show(places: [ExploreSpots.Spot], venues: [ExploreSpots.Spot]) {
        rows.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard !places.isEmpty || !venues.isEmpty else {
            status.text = "まわりには見つかりませんでした"
            return
        }
        status.isHidden = true
        if !places.isEmpty {
            rows.addArrangedSubview(heading("いま行けるところ"))
            places.forEach { rows.addArrangedSubview(row(for: $0)) }
        }
        if !venues.isEmpty {
            rows.addArrangedSubview(heading("イベントがある場所"))
            venues.forEach { rows.addArrangedSubview(row(for: $0)) }
        }
        // 作っていないものを作ったように見せない。
        rows.addArrangedSubview(note("催し物の日付や名前は、地図が持っていないので出していません"))
    }

    private func heading(_ text: String) -> UILabel {
        let label = UILabel()
        label.font = Type.captionStrong
        label.textColor = MeetPalette.secondary
        label.text = text
        return label
    }

    private func note(_ text: String) -> UILabel {
        let label = UILabel()
        label.font = Type.caption
        label.textColor = MeetPalette.secondary
        label.numberOfLines = 3
        label.text = text
        return label
    }

    private func row(for spot: ExploreSpots.Spot) -> UIButton {
        let button = UIButton(type: .system)
        var conf = UIButton.Configuration.filled()
        conf.title = spot.name
        conf.subtitle = "\(spot.label)・\(Int(spot.metres.rounded()))m"
        conf.image = UIImage(systemName: "mappin.circle.fill")
        conf.imagePadding = 12
        conf.baseBackgroundColor = MeetPalette.surface
        conf.baseForegroundColor = MeetPalette.primary
        conf.cornerStyle = .large
        conf.titleAlignment = .leading
        conf.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16)
        conf.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in
            var a = attrs
            a.font = Type.button
            return a
        }
        conf.subtitleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in
            var a = attrs
            a.font = Type.caption
            a.foregroundColor = MeetPalette.secondary
            return a
        }
        button.configuration = conf
        button.contentHorizontalAlignment = .leading
        button.addAction(UIAction { _ in
            spot.item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking])
        }, for: .touchUpInside)
        return button
    }

    @objc private func dismissSelf() { dismiss(animated: true) }
}

// MARK: - 中間で待ち合わせ

/// 2人の真ん中あたりで、待ち合わせに使える場所。
///
/// 「どこにする？」の電話がいちばん多い。片方の地図では決められないが、
/// 2人の居場所を持っているこのアプリなら、真ん中を先に出せる。
enum MidpointSpots {

    struct Spot {
        let name: String
        let label: String
        let coordinate: CLLocationCoordinate2D
        /// 自分から／相手からの直線距離（m）。どちらかに寄っていないかを見るための数字。
        let fromMe: Double
        let fromPeer: Double
    }

    /// 待ち合わせに使える場所だけ。飲食店を全部入れると選べなくなるので、
    /// 目印になるもの（駅・公園）を先に置く。
    private static let categories: [MKPointOfInterestCategory] = [.publicTransport, .park, .cafe, .restaurant]

    private static let labels: [MKPointOfInterestCategory: String] = [
        .publicTransport: "駅・バス停", .park: "公園", .cafe: "カフェ", .restaurant: "ごはん",
    ]

    /// 2点の真ん中を出して、そのまわりを見る。
    static func between(_ me: CLLocationCoordinate2D, _ peer: CLLocationCoordinate2D,
                        only: [MKPointOfInterestCategory]? = nil,
                        completion: @escaping ([Spot]) -> Void) {
        let centre = CLLocationCoordinate2D(latitude: (me.latitude + peer.latitude) / 2,
                                            longitude: (me.longitude + peer.longitude) / 2)
        let apart = CLLocation(latitude: me.latitude, longitude: me.longitude)
            .distance(from: CLLocation(latitude: peer.latitude, longitude: peer.longitude))
        // 2人が離れているほど、真ん中の探す輪も広げる。
        // 真ん中が公園や川の上だと、狭い輪では何も出ない（皇居の中で実際に0件だった）。
        // 見つからなければ3倍に広げて取り直す。
        let radius = min(4_000, max(600, apart / 3))
        search(centre: centre, radius: radius, me: me, peer: peer, only: only) { first in
            guard first.isEmpty else {
                completion(first)
                return
            }
            search(centre: centre, radius: min(20_000, radius * 3), me: me, peer: peer, only: only,
                   completion: completion)
        }
    }

    private static func search(centre: CLLocationCoordinate2D, radius: Double,
                               me: CLLocationCoordinate2D, peer: CLLocationCoordinate2D,
                               only: [MKPointOfInterestCategory]? = nil,
                               completion: @escaping ([Spot]) -> Void) {
        let request = MKLocalPointsOfInterestRequest(center: centre, radius: radius)
        request.pointOfInterestFilter = MKPointOfInterestFilter(including: only ?? categories)
        let mine = CLLocation(latitude: me.latitude, longitude: me.longitude)
        let theirs = CLLocation(latitude: peer.latitude, longitude: peer.longitude)
        MKLocalSearch(request: request).start { response, _ in
            let found: [Spot] = (response?.mapItems ?? []).compactMap { item in
                guard let name = item.name, let location = item.placemark.location,
                      let category = item.pointOfInterestCategory else { return nil }
                return Spot(name: name, label: labels[category] ?? "目印",
                            coordinate: location.coordinate,
                            fromMe: mine.distance(from: location),
                            fromPeer: theirs.distance(from: location))
            }
            // 「どちらかに寄っていない」順。2人の差が小さいものを上に。
            let fair = found.sorted { abs($0.fromMe - $0.fromPeer) < abs($1.fromMe - $1.fromPeer) }
            DispatchQueue.main.async { completion(Array(fair.prefix(6))) }
        }
    }
}

/// 真ん中の候補を並べる画面。押したら両方の地図に目印が立つ。
final class MidpointViewController: UIViewController {

    private let partner: String
    private let me: CLLocationCoordinate2D
    private let peer: CLLocationCoordinate2D
    private let onPick: (MidpointSpots.Spot) -> Void
    private let onClear: (() -> Void)?
    private let rows = UIStackView()
    private let status = UILabel()

    init(partner: String, me: CLLocationCoordinate2D, peer: CLLocationCoordinate2D,
         hasPin: Bool, onPick: @escaping (MidpointSpots.Spot) -> Void, onClear: (() -> Void)?) {
        self.partner = partner
        self.me = me
        self.peer = peer
        self.onPick = onPick
        self.onClear = hasPin ? onClear : nil
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = MeetPalette.background

        let title = UILabel()
        title.font = Type.headline
        title.textColor = MeetPalette.primary
        title.text = "中間で待ち合わせ"

        let subtitle = UILabel()
        subtitle.font = Type.caption
        subtitle.textColor = MeetPalette.secondary
        subtitle.numberOfLines = 2
        subtitle.text = "あなたと\(partner)の真ん中あたり。押すと両方の地図に目印が立ちます"

        status.font = Type.caption
        status.textColor = MeetPalette.secondary
        status.numberOfLines = 2
        status.text = "探しています…"

        rows.axis = .vertical
        rows.spacing = 8

        let column = UIStackView(arrangedSubviews: [title, subtitle, status, rows])
        column.axis = .vertical
        column.spacing = 12
        column.setCustomSpacing(4, after: title)

        if onClear != nil {
            var conf = UIButton.Configuration.plain()
            conf.title = "目印を消す"
            conf.baseForegroundColor = MeetPalette.drift
            let clear = UIButton(type: .system)
            clear.configuration = conf
            clear.addAction(UIAction { [weak self] _ in
                self?.onClear?()
                self?.dismiss(animated: true)
            }, for: .touchUpInside)
            column.addArrangedSubview(clear)
        }

        var close = UIButton.Configuration.plain()
        close.title = "やめる"
        close.baseForegroundColor = MeetPalette.secondary
        let closeButton = UIButton(type: .system)
        closeButton.configuration = close
        closeButton.addTarget(self, action: #selector(dismissSelf), for: .touchUpInside)
        column.addArrangedSubview(closeButton)

        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        column.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(column)
        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            column.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 24),
            column.leadingAnchor.constraint(equalTo: scroll.leadingAnchor, constant: 24),
            column.trailingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: -24),
            column.bottomAnchor.constraint(equalTo: scroll.bottomAnchor, constant: -24),
            column.widthAnchor.constraint(equalTo: scroll.widthAnchor, constant: -48),
        ])

        MidpointSpots.between(me, peer) { [weak self] spots in self?.show(spots) }
    }

    private func show(_ spots: [MidpointSpots.Spot]) {
        guard !spots.isEmpty else {
            status.text = "真ん中には見つかりませんでした"
            return
        }
        status.isHidden = true
        for spot in spots {
            let button = UIButton(type: .system)
            var conf = UIButton.Configuration.filled()
            conf.title = spot.name
            conf.subtitle = "\(spot.label)・あなたから\(metres(spot.fromMe))／\(partner)から\(metres(spot.fromPeer))"
            conf.image = UIImage(systemName: "mappin.and.ellipse")
            conf.imagePadding = 12
            conf.baseBackgroundColor = MeetPalette.surface
            conf.baseForegroundColor = MeetPalette.primary
            conf.cornerStyle = .large
            conf.titleAlignment = .leading
            conf.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16)
            conf.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in
                var a = attrs
                a.font = Type.button
                return a
            }
            conf.subtitleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in
                var a = attrs
                a.font = Type.caption
                a.foregroundColor = MeetPalette.secondary
                return a
            }
            button.configuration = conf
            button.contentHorizontalAlignment = .leading
            button.addAction(UIAction { [weak self] _ in
                self?.onPick(spot)
                self?.dismiss(animated: true)
            }, for: .touchUpInside)
            rows.addArrangedSubview(button)
        }
    }

    private func metres(_ value: Double) -> String {
        value < 1000 ? "\(Int(value.rounded()))m" : String(format: "%.1fkm", value / 1000)
    }

    @objc private func dismissSelf() { dismiss(animated: true) }
}
