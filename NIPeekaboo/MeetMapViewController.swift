// 離れているあいだの地図。
//
// 電波（UWB）が届く前の数百mは、数字だけでは足りない。相手がどちら側にいて、
// 自分がどこにいるかは、地図で見るのがいちばん早い。
// 近づいて電波が届いたら、この画面は用済みになる（呼んだ側が閉じる）。
import UIKit
import MapKit

final class MeetMapViewController: UIViewController {

    /// 相手の点。名前と、いまの様子（一言）を札に出す。
    final class PeerPoint: NSObject, MKAnnotation {
        dynamic var coordinate: CLLocationCoordinate2D
        var title: String?
        var subtitle: String?
        init(coordinate: CLLocationCoordinate2D, title: String?) {
            self.coordinate = coordinate
            self.title = title
        }
    }

    /// 待ち合わせの目印。人ではないので、丸ではなく旗で描く。
    final class PinPoint: NSObject, MKAnnotation {
        dynamic var coordinate: CLLocationCoordinate2D
        var title: String?
        init(coordinate: CLLocationCoordinate2D, title: String?) {
            self.coordinate = coordinate
            self.title = title
        }
    }

    /// 名前と一言の札。参考にしたのは旅人が並ぶ地図の見せ方
    /// （名前を太く、様子を下に小さく、白い札で地図から浮かせる）。
    static func nameCard(_ name: String, mood: String?) -> UIView {
        let card = UIView()
        card.backgroundColor = .white
        card.layer.cornerRadius = 14
        card.layer.cornerCurve = .continuous
        card.layer.shadowColor = UIColor.black.cgColor
        card.layer.shadowOpacity = 0.18
        card.layer.shadowRadius = 6
        card.layer.shadowOffset = CGSize(width: 0, height: 2)

        let nameLabel = UILabel()
        nameLabel.text = name
        nameLabel.font = Type.font(15, .bold, .footnote)
        nameLabel.textColor = .black
        let stack = UIStackView(arrangedSubviews: [nameLabel])
        if let mood, !mood.isEmpty {
            let moodLabel = UILabel()
            moodLabel.text = mood
            moodLabel.font = Type.font(13, .regular, .caption1)
            moodLabel.textColor = UIColor(white: 0.42, alpha: 1)
            stack.addArrangedSubview(moodLabel)
        }
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 1
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -8),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
        ])
        card.frame = CGRect(origin: .zero, size: card.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize))
        return card
    }

    private let map = MKMapView()
    private let card = UIView()
    private let headline = UILabel()
    private let number = UILabel()
    private let detail = UILabel()
    private let closeButton = CapsuleButton(type: .system)

    private var peerName: String
    private let myName: String
    private var peerMood: String?
    private var myMood: String?
    private var peerFace: UIImage?
    private var myFace: UIImage?
    /// 待ち合わせの目印。2人の地図の同じ場所に立つ。
    private var pin: PinPoint?
    private var peer: PeerPoint?
    private var line: MKPolyline?          // 道なりの経路（取れないときは2点を結ぶ直線）
    private var lineIsRoute = false
    private var fitted = false
    /// 人が指で地図を動かしたか。動かしたあとは、こちらから向きを戻さない
    /// （見たい所を見ている最中に引き戻されるのがいちばん腹が立つ）。
    private(set) var userMoved = false
    /// 動かされたことを上の画面に知らせる（「2人が入るように戻す」を出すため）。
    var onUserMoved: (() -> Void)?
    /// 最後に取り直した時刻。歩くたびに画面が飛ばないための間合い。
    private var refitAt = Date.distantPast
    /// 経路を引き直した時刻と、そのときの相手の場所。呼びすぎないための覚え書き。
    private var routeAt = Date.distantPast
    private var routeFrom: CLLocationCoordinate2D?
    private var routeMinutes: Int?
    private var routeMetres: Double?
    /// いちばん新しい徒歩の経路。曲がり角の一覧を出すために持っておく。
    private(set) var currentRoute: MKRoute?
    /// 地図の店や駅が押された（札を出すのは上の画面の仕事）。
    /// 押した瞬間に名前と種類だけで一度呼び、詳しいこと（営業時間など）は届いたら onPlaceLoaded で。
    var onSelectPlace: ((MKMapItem) -> Void)?
    /// 先に渡した仮の場所と、届いた詳しい場所。
    var onPlaceLoaded: ((_ first: MKMapItem, _ full: MKMapItem) -> Void)?
    /// 指で地図を押した（true）・動かした（false）。板を下げたり、店の札を閉じたりする合図。
    var onMapTouched: ((_ tapped: Bool) -> Void)?
    /// 選んだ場所の印と、そこまでの道なりの線。
    private var placePin: MKPointAnnotation?
    /// 選んだ場所にいちばん近い駅の出口の印。
    private var exitPins: [ExitPoint] = []
    private var lastFeature: MKAnnotation?
    private var placeLine: MKPolyline?

    /// 画面の下地として埋め込むときは true。自前の帯と閉じるボタンを出さない
    /// （数字と操作は上に乗るホーム画面の側が持つ）。
    private let compact: Bool

    init(peerName: String, myName: String, compact: Bool = false) {
        self.peerName = peerName
        self.myName = myName
        self.compact = compact
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = MeetPalette.background

        map.translatesAutoresizingMaskIntoConstraints = false
        map.delegate = self
        map.showsUserLocation = true
        map.showsCompass = false
        followSystemAppearance()
        // 普通の地図として使う。店・駅・公園の印を出し、押せるようにする。
        // 以前は「地図は床」として印を全部消していたが、つないでいないと周りも
        // 見られない地図になっていた（本人 9/25「普通のマップや周辺見れるように」）。
        if #available(iOS 16.0, *) {
            map.preferredConfiguration = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .default)
            map.selectableMapFeatures = [.pointsOfInterest]
        }
        map.isRotateEnabled = true
        map.isPitchEnabled = true
        view.addSubview(map)
        // 地図を押したら、上の画面に知らせる（板を下げるため）。地図の操作は邪魔しない：
        // ほかのジェスチャと同時に通し、ダブルタップを待たない（待つと毎回0.3秒ほど遅れる）。
        let tap = UITapGestureRecognizer(target: self, action: #selector(mapTapped))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        map.addGestureRecognizer(tap)

        // 下のカード。数字を主役に、そのすぐ下に「何で測っているか」を書く。
        card.translatesAutoresizingMaskIntoConstraints = false
        card.backgroundColor = MeetPalette.surface
        card.layer.cornerRadius = 26
        card.layer.cornerCurve = .continuous
        view.addSubview(card)

        headline.isHidden = true
        number.font = Type.font(22, .bold, .title3)
        number.textColor = MeetPalette.primary
        number.adjustsFontSizeToFitWidth = true
        number.minimumScaleFactor = 0.6
        detail.font = Type.caption
        detail.textColor = MeetPalette.secondary
        detail.numberOfLines = 1
        detail.adjustsFontSizeToFitWidth = true
        detail.minimumScaleFactor = 0.8

        closeButton.configuration = .filled()
        closeButton.configuration?.title = "閉じる"
        closeButton.configuration?.baseBackgroundColor = MeetPalette.raised
        closeButton.configuration?.baseForegroundColor = MeetPalette.primary
        closeButton.configuration?.cornerStyle = .capsule
        closeButton.configuration?.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16)
        closeButton.setContentHuggingPriority(.required, for: .horizontal)
        closeButton.addTarget(self, action: #selector(close), for: .touchUpInside)

        // 参考にした地図は、下は小さな1枚だけだった。見出し・数字・説明・ボタンを
        // 縦に4つ積むのをやめて、1本の横並びにする。
        let icon = UIImageView(image: UIImage(systemName: "figure.walk"))
        icon.tintColor = MeetPalette.secondary
        icon.contentMode = .scaleAspectFit
        icon.setContentHuggingPriority(.required, for: .horizontal)

        let numbers = UIStackView(arrangedSubviews: [number, detail])
        numbers.axis = .vertical
        numbers.spacing = 1

        let stack = UIStackView(arrangedSubviews: [icon, numbers, closeButton])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        card.isHidden = compact
        NSLayoutConstraint.activate([
            map.topAnchor.constraint(equalTo: view.topAnchor),
            map.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            map.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            map.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            card.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            card.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            card.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),

            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
            icon.widthAnchor.constraint(equalToConstant: 22),
            icon.heightAnchor.constraint(equalToConstant: 22),
        ])
    }

    @objc private func close() { dismiss(animated: true) }

    /// 2人が入るように取り直す。床として出すときは、出た瞬間に一度呼ぶ。
    func refit() {
        fitted = false
        userMoved = false
    }

    /// 埋め込んで使うとき、相手が変わったら名前を差し替える（札だけ作り直す）。
    func rename(peer name: String) {
        guard name != peerName else { return }
        peerName = name
        refreshCards()
    }

    /// 印（写真）を貼り替える。地図の点や向きはそのまま。
    private func refreshFaces() {}

    /// 丸の中身を写真にする。写真が無ければこれまでの人の形。
    /// 丸の中身。写真があれば写真、無ければ名前の頭文字（「探す」やLife360と同じ）。
    /// 以前は人の形の記号で、2人とも同じ絵になり、どちらが誰か分からなかった。
    private func applyFace(_ image: UIImage?, to view: MKAnnotationView, name: String) {
        guard let dot = view.subviews.first(where: { $0.tag == Self.dotTag }) else { return }
        dot.subviews.forEach { $0.removeFromSuperview() }
        let face = FaceView(frame: dot.bounds.insetBy(dx: 3, dy: 3))
        face.set(name: name, face: image)
        dot.addSubview(face)
    }

    private static let dotTag = 8802

    /// 名前と一言の札だけを作り直す。地図の点や向きはそのまま。
    private func refreshCards() {
        guard let peer else { return }
        peer.title = peerName
        peer.subtitle = peerMood
        if let view = map.view(for: peer) as? MKMarkerAnnotationView {
            view.annotation = peer
            view.glyphText = peerName.first.map(String.init)
        }
    }

    /// 人の上に札を付ける（すでに付いていれば取り替える）。
    private func attachCard(to view: MKAnnotationView, name: String, mood: String?) {
        view.subviews.filter { $0.tag == Self.cardTag }.forEach { $0.removeFromSuperview() }
        let card = Self.nameCard(name, mood: mood)
        card.tag = Self.cardTag
        // 人の頭の上に、少し浮かせて置く。
        card.frame.origin = CGPoint(x: (view.bounds.width - card.frame.width) / 2, y: -card.frame.height - 8)
        view.addSubview(card)
        view.clipsToBounds = false
    }

    private static let cardTag = 8801

    /// 呼んだ側から呼ばれる。相手の居場所と、いまの見立てを渡す。
    func update(peerAt coordinate: CLLocationCoordinate2D?, meAt me: CLLocation?,
                metres: Double?, accuracy: Double?, byRadio: Bool,
                peerMood: String? = nil, myMood: String? = nil,
                peerFace: UIImage? = nil, myFace: UIImage? = nil,
                pin: (name: String, coordinate: CLLocationCoordinate2D)? = nil) {
        // 待ち合わせの目印。決まっていなければ何も立てない。
        if let pin {
            if let existing = self.pin, existing.title == pin.name {
                existing.coordinate = pin.coordinate
            } else {
                if let existing = self.pin { map.removeAnnotation(existing) }
                let point = PinPoint(coordinate: pin.coordinate, title: pin.name)
                map.addAnnotation(point)
                self.pin = point
            }
        } else if let existing = self.pin {
            map.removeAnnotation(existing)
            self.pin = nil
        }
        let moodChanged = peerMood != self.peerMood || myMood != self.myMood
        let faceChanged = peerFace !== self.peerFace || myFace !== self.myFace
        self.peerMood = peerMood
        self.myMood = myMood
        self.peerFace = peerFace
        self.myFace = myFace
        if moodChanged || faceChanged { refreshCards() }
        if faceChanged { refreshFaces() }
        if let coordinate {
            if let peer {
                peer.coordinate = coordinate
            } else {
                let p = PeerPoint(coordinate: coordinate, title: peerName)
                map.addAnnotation(p)
                peer = p
                // 相手が現れた瞬間は、指で動かしたあとでも2人が入るように合わせ直す
                // （9/28「地図を広げないと繋がらなかったり」：相手が画面の外に出たままだった）。
                fitted = false
                userMoved = false
                followHeading = false
            }
        } else if let existing = peer {
            // 相手がいなくなったら点も消す。終わったあとに札だけ残ると、
            // まだそこに居るように見える。
            map.removeAnnotation(existing)
            peer = nil
            if let line { map.removeOverlay(line) }
            line = nil
            lineIsRoute = false
        }
        lastStraight = metres
        lastAccuracy = accuracy
        lastByRadio = byRadio
        showNumbers()

        // 相手がまだ居ないとき。自分のまわりだけを見せる（何も映らない黒より、
        // いま立っている場所が出ているほうが、待つあいだの役に立つ）。
        if coordinate == nil, let me, !fitted {
            let camera = MKMapCamera(lookingAtCenter: me.coordinate,
                                     fromDistance: 700, pitch: 0, heading: 0)
            map.setCamera(camera, animated: false)
            // 1人のときは、自分の向いている方を上にして地図を回す（本人 9/28「自分の方向で地図も合わせて動いてほしい」）。
            // MapKit の向きモード（followWithHeading）は入るたびに2km四方ほどに引いてしまうので使わず、
            // 向きが届くたびにこちらで回す（案内中の地図と同じやり方）。指で動かせば止まる。
            // MapKit の向きモードは、入り方を変えても2km四方ほどに引いてしまった（9/28 シミュレータで2回）。
            followHeading = true
            fitted = true
            refitAt = Date()
        }

        // 2つの点を結ぶ線。どちら側にいるかは、線の向きでひと目でわかる。
        if let me, let coordinate {
            updateRoute(me: me.coordinate, peer: coordinate)
            // 両端がほとんど動いていなければ引き直さない（位置が届くたびに消して足すと、地図が重くなる）。
            let sameEnds = line.map { l in
                l.pointCount == 2
                    && MKMapPoint(me.coordinate).distance(to: l.points()[0]) < 1
                    && MKMapPoint(coordinate).distance(to: l.points()[1]) < 1
            } ?? false
            if !lineIsRoute, !sameEnds {
                if let line { map.removeOverlay(line) }
                let pts = [me.coordinate, coordinate]
                let l = MKPolyline(coordinates: pts, count: 2)
                map.addOverlay(l)
                line = l
            }
            if !fitted {
                fit(me: me.coordinate, peer: coordinate)
                fitted = true
                refitAt = Date()
            } else if !userMoved, map.userTrackingMode == .none, drifted(me: me.coordinate, peer: coordinate),
                      Date().timeIntervalSince(refitAt) > 5 {
                // 2人は歩くので、最初に決めた画面のままだと相手がすぐ外に出る。
                // 指で動かされていないあいだは、こちらで取り直す。
                fit(me: me.coordinate, peer: coordinate)
                refitAt = Date()
            }
        }
    }

    /// 道なりの経路を引く。直線距離は「道を無視した数字」なので、出せるならこちらを使う。
    /// 相手が100m以上動いたか、30秒経ったときだけ引き直す（呼びすぎないため）。
    private func updateRoute(me: CLLocationCoordinate2D, peer: CLLocationCoordinate2D) {
        let moved = routeFrom.map {
            CLLocation(latitude: $0.latitude, longitude: $0.longitude)
                .distance(from: CLLocation(latitude: peer.latitude, longitude: peer.longitude))
        } ?? .greatestFiniteMagnitude
        guard moved > 100 || Date().timeIntervalSince(routeAt) > 30 else { return }
        routeAt = Date()
        routeFrom = peer

        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: me))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: peer))
        request.transportType = .walking
        request.requestsAlternateRoutes = false
        MKDirections(request: request).calculate { [weak self] response, _ in
            guard let self, let route = response?.routes.first else { return }
            DispatchQueue.main.async {
                self.currentRoute = route
                self.routeMinutes = max(1, Int((route.expectedTravelTime / 60).rounded()))
                self.routeMetres = route.distance
                if let line = self.line { self.map.removeOverlay(line) }
                self.map.addOverlay(route.polyline)
                self.line = route.polyline
                self.lineIsRoute = true
                self.showNumbers()
            }
        }
    }

    private var lastStraight: Double?
    private var lastAccuracy: Double?
    private var lastByRadio = false

    /// 数字の出し方。道なりが取れていればそれを主役にし、直線は添えるだけにする。
    private func showNumbers() {
        guard let metres = lastStraight else {
            number.text = "\(peerName)を待っています"
            detail.text = "相手がアプリを開くと出ます"
            return
        }
        let straight = metres < 1000 ? "\(Int(metres.rounded()))m" : String(format: "%.1fkm", metres / 1000)
        if lastByRadio {
            number.text = "あと \(straight)"
            detail.text = "電波で測っています"
            return
        }
        if let minutes = routeMinutes, let rm = routeMetres {
            let along = rm < 1000 ? "\(Int(rm.rounded()))m" : String(format: "%.1fkm", rm / 1000)
            number.text = "あと約\(minutes)分・\(along)"
            detail.text = "道なり・誤差±\(Int((lastAccuracy ?? 0).rounded()))m"
        } else {
            number.text = "直線で \(straight)"
            detail.text = "道なりを調べています"
        }
    }

    /// 案内中。地図を自分の位置と向きに合わせて付いていかせる（地図アプリの案内と同じ）。
    ///
    /// MapKit の追いかけ（followWithHeading）は、途中でほかのカメラ操作が入ると
    /// 黙って外れ、「歩く方向に向かない」になっていた（本人 9/25）。案内中の見え方は
    /// こちらで毎回決める: 自分の少し先を、向いている方を上にして斜めに見る
    /// （Googleマップの徒歩案内と同じ）。
    func startFollowing() {
        navigating = true
        navPaused = false
        lastNavHeading = -1
        userMoved = true
        fitted = true
        map.setUserTrackingMode(.none, animated: false)
        refreshNavLook()
    }

    /// 案内をやめたら、2人が入る見え方に戻す。
    func stopFollowing() {
        navigating = false
        navPaused = false
        map.setUserTrackingMode(.none, animated: false)
        refreshNavLook()
        refit()
    }

    /// 地図だけは端末の「ライト／ダーク」に合わせる（Appleマップと同じ）。
    /// アプリは暗い色で固定しているが、昼の屋外で暗い地図は読みにくい。
    func followSystemAppearance() {
        // 固定しない。画面全体がライト／ダークに合わせて切り替わるので、地図もそれに付いていく。
        map.overrideUserInterfaceStyle = .unspecified
    }

    /// 地図そのもの（標準の現在地ボタン・コンパスをつなぐため）。
    var mapView: MKMapView { map }

    /// 案内中。指で地図を動かしたら、カメラは止める（「中央に戻す」で戻る）。
    private(set) var navigating = false
    private(set) var navPaused = false
    private var lastNavCamera = Date.distantPast
    private var lastNavHeading: CLLocationDirection = -1
    /// 案内中に指で動かされた（上の画面が「中央に戻す」を出すため）。
    var onNavPaused: (() -> Void)?

    func resumeNavCamera() {
        navPaused = false
        lastNavHeading = -1
    }

    /// 案内中のカメラ。heading は「上にしたい向き」（北から時計回りの度）。
    func navCamera(me: CLLocation, heading: CLLocationDirection) {
        guard navigating, !navPaused else { return }
        let turned = lastNavHeading < 0 || abs(Self.angleDiff(heading, lastNavHeading)) > 4
        guard turned || Date().timeIntervalSince(lastNavCamera) > 0.8 else { return }
        lastNavCamera = Date()
        lastNavHeading = heading
        let ahead = Self.offset(me.coordinate, bearing: heading, metres: 45)
        let camera = MKMapCamera(lookingAtCenter: ahead, fromDistance: 300, pitch: 55, heading: heading)
        map.setCamera(camera, animated: true)
    }

    static func angleDiff(_ a: Double, _ b: Double) -> Double {
        var r = (a - b).truncatingRemainder(dividingBy: 360)
        if r > 180 { r -= 360 }
        if r < -180 { r += 360 }
        return r
    }

    static func offset(_ c: CLLocationCoordinate2D, bearing: Double, metres: Double) -> CLLocationCoordinate2D {
        let rad = bearing * .pi / 180
        let dLat = metres * cos(rad) / 111_320
        let dLon = metres * sin(rad) / (111_320 * cos(c.latitude * .pi / 180))
        return CLLocationCoordinate2D(latitude: c.latitude + dLat, longitude: c.longitude + dLon)
    }

    private static let navArrowTag = 8803

    /// 案内中は、自分の印を顔の丸から向きの三角にする（地図が向いている方を上に
    /// 回るので、三角はいつも上＝進む向き）。道なりの線も太くする。
    private func refreshNavLook() {
        refreshMeLook()
        let overlays = map.overlays
        map.removeOverlays(overlays)
        map.addOverlays(overlays)
    }

    /// いま向いている方（北から時計回りの度）。分からなければ nil（三角ではなく点）。
    private var myHeading: CLLocationDirection?

    func setMyHeading(_ heading: CLLocationDirection?) {
        myHeading = heading
        refreshMeLook()
        turnWithHeading()
    }

    /// 1人のとき、向いている方を上にして回すか（指で動かしたら止める。開き直せばまた回る）。
    private var followHeading = false

    /// 向きが届くたびに一気に回すとカクカクする（本人 9/28「向きに合わせて動くのがカクカク」）。
    /// 目標の向きだけ受け取り、画面の書き換えごとに少しずつ近づける。追いついたら止まる（電池）。
    private var targetHeading: CLLocationDirection?
    private var turnLink: CADisplayLink?

    private func turnWithHeading() {
        guard followHeading, !userMoved, !navigating, peer == nil, let h = myHeading else {
            stopTurning()
            return
        }
        targetHeading = h
        guard turnLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(turnStep))
        link.add(to: .main, forMode: .common)
        turnLink = link
    }

    @objc private func turnStep() {
        guard followHeading, !userMoved, !navigating, peer == nil,
              let target = targetHeading, let me = map.userLocation.location else {
            stopTurning()
            return
        }
        let now = map.camera.heading
        let diff = Self.angleDiff(target, now)
        guard abs(diff) > 0.3 else {
            stopTurning()
            return
        }
        // 残りの2割ずつ近づける（最初は速く、終わりはゆっくり）。拡大・縮小はいまのまま。
        let camera = MKMapCamera(lookingAtCenter: me.coordinate,
                                 fromDistance: map.camera.centerCoordinateDistance,
                                 pitch: map.camera.pitch, heading: now + diff * 0.2)
        map.setCamera(camera, animated: false)
    }

    private func stopTurning() {
        turnLink?.invalidate()
        turnLink = nil
    }

    private func refreshMeLook() {
        if let view = map.view(for: map.userLocation) { applyMeLook(to: view) }
    }

    /// 三角は「向いている方 − 地図の向き」だけ回す。地図が回っても、三角は実際の向きを指す。
    private func applyMeLook(to view: MKAnnotationView) {
        guard let arrow = view.subviews.first(where: { $0.tag == Self.navArrowTag }) as? UIImageView else { return }
        let size = view.bounds.width
        if let h = myHeading {
            arrow.image = NavArrow.image(size: size)
            let angle = (h - map.camera.heading) * .pi / 180
            arrow.transform = CGAffineTransform(rotationAngle: CGFloat(angle))
        } else {
            arrow.image = NavArrow.dot(size: size)
            arrow.transform = .identity
        }
    }

    /// 選んだ場所に印を立て、自分とその場所が入るように見せる。nil で消す。
    func showPlace(_ item: MKMapItem?) {
        if let placePin { map.removeAnnotation(placePin) }
        placePin = nil
        guard let item else { return }
        let pin = MKPointAnnotation()
        pin.coordinate = item.placemark.coordinate
        pin.title = item.name
        map.addAnnotation(pin)
        placePin = pin
        var rect = MKMapRect.null
        for c in [item.placemark.coordinate] + (map.userLocation.location.map { [$0.coordinate] } ?? []) {
            let p = MKMapPoint(c)
            rect = rect.union(MKMapRect(x: p.x, y: p.y, width: 0, height: 0))
        }
        let flat = MKMapCamera(lookingAtCenter: map.centerCoordinate,
                               fromDistance: map.camera.centerCoordinateDistance, pitch: 0, heading: 0)
        map.setCamera(flat, animated: false)
        // 目の前の店（数十m）だと建物しか映らないほど寄ってしまう。最低でも300m四方は見せる。
        let minSide = MKMapPointsPerMeterAtLatitude(item.placemark.coordinate.latitude) * 300
        if rect.size.width < minSide, rect.size.height < minSide {
            rect = rect.insetBy(dx: -(minSide - rect.size.width) / 2, dy: -(minSide - rect.size.height) / 2)
        }
        map.setVisibleMapRect(rect, edgePadding: UIEdgeInsets(top: 140, left: 60, bottom: 380, right: 60),
                              animated: true)
        fitted = true
        userMoved = true
        onUserMoved?()
    }

    /// 駅の出口の印を立てる（空なら消す）。
    func showExits(_ exits: [StationExit]) {
        map.removeAnnotations(exitPins)
        exitPins = exits.map { e in
            let p = ExitPoint()
            p.coordinate = e.coordinate
            p.title = "\(e.ref)出口"
            p.subtitle = e.station
            return p
        }
        map.addAnnotations(exitPins)
    }

    /// 選んだ場所までの道なりの線。nil で消す。
    func showPlaceRoute(_ route: MKRoute?) {
        if let placeLine { map.removeOverlay(placeLine) }
        placeLine = route?.polyline
        if let placeLine { map.addOverlay(placeLine) }
    }

    /// 次の更新で経路を引き直す（まだ取れていないときに押された）。
    func refreshRouteSoon() { routeAt = .distantPast }

    /// 経路の線が全部入るように見せる。下半分は一覧が乗るので広く空ける。
    /// 自分で動かしたのと同じ扱いにして、こちらからは向きを戻さない（戻すのは矢印）。
    func fitRoute() {
        guard let route = currentRoute else { return }
        let flat = MKMapCamera(lookingAtCenter: map.centerCoordinate,
                               fromDistance: map.camera.centerCoordinateDistance,
                               pitch: 0, heading: 0)
        map.setCamera(flat, animated: false)
        map.setVisibleMapRect(route.polyline.boundingMapRect,
                              edgePadding: UIEdgeInsets(top: 130, left: 50, bottom: 440, right: 50),
                              animated: true)
        fitted = true
        userMoved = true
        onUserMoved?()
    }

    /// 2人（と目印）が画面に入っているか。端に寄った時点で外に出たとみなす。
    private func drifted(me: CLLocationCoordinate2D, peer: CLLocationCoordinate2D) -> Bool {
        let rect = map.visibleMapRect
        guard rect.size.width > 0 else { return false }
        let margin = rect.size.width * 0.12
        let inner = rect.insetBy(dx: margin, dy: rect.size.height * 0.12)
        var points = [MKMapPoint(me), MKMapPoint(peer)]
        if let pin { points.append(MKMapPoint(pin.coordinate)) }
        return points.contains { !inner.contains($0) }
    }

    /// 2人の真ん中から、相手の方を向いて斜めに見る。
    /// 地図を真上から見ると「地図アプリ」になる。見たいのは相手なので、低い角度で相手側を向く。
    private func fit(me: CLLocationCoordinate2D, peer: CLLocationCoordinate2D) {
        // 真ん中ではなく、自分寄り（3割ほど相手側）に置く。
        // そうすると自分は画面の下のほう、相手は奥に立ち、レースの画面のように見える。
        let t = 0.15
        let mid = CLLocationCoordinate2D(latitude: me.latitude + (peer.latitude - me.latitude) * t,
                                         longitude: me.longitude + (peer.longitude - me.longitude) * t)
        let metres = CLLocation(latitude: me.latitude, longitude: me.longitude)
            .distance(from: CLLocation(latitude: peer.latitude, longitude: peer.longitude))
        // 遠いときに斜めのままだと、奥に立つ相手が画面の外へ出る。
        // 300mを超えたら見栄えより「2人とも映っていること」を取る。
        guard metres <= 300 else {
            var rect = MKMapRect.null
            for c in [me, peer] + (pin.map { [$0.coordinate] } ?? []) {
                let point = MKMapPoint(c)
                rect = rect.union(MKMapRect(x: point.x, y: point.y, width: 0, height: 0))
            }
            // 下半分はボタンが乗っているので、その分だけ広く空ける。
            let padding = UIEdgeInsets(top: 150, left: 50, bottom: 300, right: 50)
            let flat = MKMapCamera(lookingAtCenter: map.centerCoordinate,
                                   fromDistance: map.camera.centerCoordinateDistance,
                                   pitch: 0, heading: 0)
            map.setCamera(flat, animated: false)
            map.setVisibleMapRect(rect, edgePadding: padding, animated: true)
            return
        }
        let camera = MKMapCamera(lookingAtCenter: mid,
                                 fromDistance: max(300, metres * 2.0),
                                 pitch: 45,
                                 heading: heading(from: me, to: peer))
        map.setCamera(camera, animated: true)
    }

    private func heading(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> CLLocationDirection {
        let rad = Double.pi / 180
        let y = sin((b.longitude - a.longitude) * rad) * cos(b.latitude * rad)
        let x = cos(a.latitude * rad) * sin(b.latitude * rad)
            - sin(a.latitude * rad) * cos(b.latitude * rad) * cos((b.longitude - a.longitude) * rad)
        return (atan2(y, x) / rad + 360).truncatingRemainder(dividingBy: 360)
    }
}

extension MeetMapViewController: MKMapViewDelegate {
    /// 指で動かされたのか、こちらが setCamera で動かしたのかは、地図が持っている
    /// ジェスチャの状態で分かる（アプリが動かしたときは、どれも動いていない）。
    func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
        let touched = mapView.subviews.first?.gestureRecognizers?.contains { recogniser in
            [.began, .changed, .ended].contains(recogniser.state)
        } ?? false
        guard touched else { return }
        onMapTouched?(false)
        if navigating {
            if !navPaused {
                navPaused = true
                onNavPaused?()
            }
            return
        }
        guard !userMoved else { return }
        userMoved = true
        fitted = true          // 以後、こちらからは向きを戻さない
        onUserMoved?()
    }

    /// 地図の店や駅が押された。場所の情報を取り寄せて、上の画面に渡す。
    func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
        if let annotation = view.annotation { selectedFeature(annotation, in: mapView) }
    }

    @available(iOS 16.0, *)
    func mapView(_ mapView: MKMapView, didSelect annotation: MKAnnotation) {
        selectedFeature(annotation, in: mapView)
    }

    private func selectedFeature(_ annotation: MKAnnotation, in mapView: MKMapView) {
        guard #available(iOS 16.0, *), let feature = annotation as? MKMapFeatureAnnotation else { return }
        // 同じ押下で2回呼ばれることがある（新旧2つの通知）。
        guard feature !== lastFeature else { return }
        lastFeature = feature
        #if DEBUG
        print("PLACE selected: \(feature.title ?? "-")")
        #endif
        let first = MKMapItem(placemark: MKPlacemark(coordinate: feature.coordinate))
        first.name = feature.title ?? "この場所"
        first.pointOfInterestCategory = feature.pointOfInterestCategory
        // 通信を待たずに、すぐ札を出す（待つと押してから札が出るまで間が空いて、もっさりする）。
        onSelectPlace?(first)
        MKMapItemRequest(mapFeatureAnnotation: feature).getMapItem { [weak self] item, _ in
            DispatchQueue.main.async {
                if let item { self?.onPlaceLoaded?(first, item) }
                mapView.deselectAnnotation(feature, animated: true)
                self?.lastFeature = nil
            }
        }
    }

    /// 地図が回ったら、自分の三角を向き直す（三角は実際の向きを指し続ける）。
    func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
        refreshMeLook()
    }

    func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
        if let placeLine, overlay === placeLine {
            let r = MKPolylineRenderer(overlay: overlay)
            r.strokeColor = MeetPalette.arrival
            r.lineWidth = navigating ? 10 : 5
            return r
        }
        let r = MKPolylineRenderer(overlay: overlay)
        r.strokeColor = MeetPalette.action.withAlphaComponent(navigating ? 0.95 : 0.8)
        r.lineWidth = navigating ? 10 : 3
        r.lineDashPattern = lineIsRoute ? nil : [6, 8]   // 道なりは実線、直線は点線
        return r
    }

    // ピンではなく「人が立っている」形にする。
    // 相手がどこかにいる、という感じは、記号よりも姿のほうが伝わる（マリオカートの選択画面のように）。
    func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
        // 駅の出口は iOS 標準のピン（電車の印・藍色）。「5a出口」と名前を出す。
        if annotation is ExitPoint {
            let view = (mapView.dequeueReusableAnnotationView(withIdentifier: "exit") as? MKMarkerAnnotationView)
                ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: "exit")
            view.annotation = annotation
            view.markerTintColor = .systemIndigo
            view.glyphImage = UIImage(systemName: "tram.fill")
            view.titleVisibility = .visible
            view.displayPriority = .required
            return view
        }
        // 自分も同じ姿で立たせる。青い点だと、自分だけ地図アプリのままになる
        // 自分は iOS 標準の青い点（向きの扇つき）。手描きの印はやめた（本人 9/25「デザインは自前しないで」）。
        if annotation is MKUserLocation { return nil }
        if annotation is PinPoint {
            let view = (mapView.dequeueReusableAnnotationView(withIdentifier: "pin") as? MKMarkerAnnotationView)
                ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: "pin")
            view.annotation = annotation
            view.markerTintColor = .systemGreen
            view.glyphImage = UIImage(systemName: "flag.fill")
            view.titleVisibility = .visible
            view.displayPriority = .required
            return view
        }
        guard annotation is PeerPoint else { return nil }
        // 相手も iOS 標準のピン（Appleマップと同じ見た目）。名前はピンの下、一言はその下。
        let view = (mapView.dequeueReusableAnnotationView(withIdentifier: "peer") as? MKMarkerAnnotationView)
            ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: "peer")
        view.annotation = annotation
        view.markerTintColor = .systemOrange
        view.glyphText = peerName.first.map(String.init)
        view.titleVisibility = .visible
        view.subtitleVisibility = .visible
        view.displayPriority = .required
        return view
    }
}

private extension MKMapRect {
    init(a: MKMapPoint, b: MKMapPoint) {
        self.init(x: min(a.x, b.x), y: min(a.y, b.y),
                  width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
}

extension MeetMapViewController: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}

extension MeetMapViewController {
    @objc fileprivate func mapTapped() { onMapTouched?(true) }
}

/// 駅の出口の印。
final class ExitPoint: MKPointAnnotation {}
