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
        map.pointOfInterestFilter = .excludingAll
        map.overrideUserInterfaceStyle = .dark
        // 地図は主役ではなく床。色を抑えて、人が目立つようにする
        if #available(iOS 16.0, *) {
            let config = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
            config.pointOfInterestFilter = .excludingAll
            map.preferredConfiguration = config
        }
        map.isRotateEnabled = true
        map.isPitchEnabled = true
        view.addSubview(map)

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
    private func refreshFaces() {
        if let peer, let view = map.view(for: peer) { applyFace(peerFace, to: view, fallback: "figure.walk") }
        if let view = map.view(for: map.userLocation) { applyFace(myFace, to: view, fallback: "figure.stand") }
    }

    /// 丸の中身を写真にする。写真が無ければこれまでの人の形。
    private func applyFace(_ image: UIImage?, to view: MKAnnotationView, fallback symbol: String) {
        guard let dot = view.subviews.first(where: { $0.tag == Self.dotTag }) else { return }
        dot.subviews.forEach { $0.removeFromSuperview() }
        let inner = UIImageView(frame: dot.bounds)
        if let image {
            inner.image = image
            inner.contentMode = .scaleAspectFill
            inner.layer.cornerRadius = dot.bounds.width / 2
            inner.clipsToBounds = true
        } else {
            inner.image = UIImage(systemName: symbol)
            inner.tintColor = MeetPalette.background
            inner.contentMode = .scaleAspectFit
            inner.frame = dot.bounds.insetBy(dx: dot.bounds.width * 0.23, dy: dot.bounds.width * 0.23)
        }
        dot.addSubview(inner)
    }

    private static let dotTag = 8802

    /// 名前と一言の札だけを作り直す。地図の点や向きはそのまま。
    private func refreshCards() {
        if let peer, let view = map.view(for: peer) { attachCard(to: view, name: peerName, mood: peerMood) }
        if let view = map.view(for: map.userLocation) { attachCard(to: view, name: myName, mood: myMood) }
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
            }
        }
        lastStraight = metres
        lastAccuracy = accuracy
        lastByRadio = byRadio
        showNumbers()

        // 2つの点を結ぶ線。どちら側にいるかは、線の向きでひと目でわかる。
        if let me, let coordinate {
            updateRoute(me: me.coordinate, peer: coordinate)
            if !lineIsRoute {
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
            } else if !userMoved, drifted(me: me.coordinate, peer: coordinate),
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
        guard touched, !userMoved else { return }
        userMoved = true
        fitted = true          // 以後、こちらからは向きを戻さない
        onUserMoved?()
    }

    func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
        let r = MKPolylineRenderer(overlay: overlay)
        r.strokeColor = MeetPalette.action.withAlphaComponent(0.8)
        r.lineWidth = 3
        r.lineDashPattern = lineIsRoute ? nil : [6, 8]   // 道なりは実線、直線は点線
        return r
    }

    // ピンではなく「人が立っている」形にする。
    // 相手がどこかにいる、という感じは、記号よりも姿のほうが伝わる（マリオカートの選択画面のように）。
    func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
        // 自分も同じ姿で立たせる。青い点だと、自分だけ地図アプリのままになる
        if annotation is MKUserLocation {
            let id = "me"
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: id)
                ?? MKAnnotationView(annotation: annotation, reuseIdentifier: id)
            view.annotation = annotation
            view.subviews.forEach { $0.removeFromSuperview() }
            let size: CGFloat = 64
            view.frame = CGRect(x: 0, y: 0, width: size, height: size)
            view.centerOffset = CGPoint(x: 0, y: -size / 2)
            let dot = UIView(frame: view.bounds)
            dot.tag = Self.dotTag
            dot.backgroundColor = MeetPalette.primary
            dot.layer.cornerRadius = size / 2
            dot.layer.borderWidth = 3
            dot.layer.borderColor = UIColor.white.cgColor
            dot.clipsToBounds = true
            view.addSubview(dot)
            applyFace(myFace, to: view, fallback: "figure.stand")
            attachCard(to: view, name: myName, mood: myMood)
            return view
        }
        if let flag = annotation as? PinPoint {
            let id = "pin"
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: id)
                ?? MKAnnotationView(annotation: annotation, reuseIdentifier: id)
            view.annotation = annotation
            view.canShowCallout = false
            view.subviews.forEach { $0.removeFromSuperview() }
            let size: CGFloat = 46
            view.frame = CGRect(x: 0, y: 0, width: size, height: size)
            view.centerOffset = CGPoint(x: 0, y: -size / 2)
            let disc = UIView(frame: view.bounds)
            disc.backgroundColor = MeetPalette.ink
            disc.layer.cornerRadius = size / 2
            disc.layer.borderWidth = 3
            disc.layer.borderColor = UIColor.white.cgColor
            let symbol = UIImageView(image: UIImage(systemName: "flag.fill"))
            symbol.tintColor = .black
            symbol.contentMode = .scaleAspectFit
            symbol.frame = disc.bounds.insetBy(dx: 12, dy: 12)
            disc.addSubview(symbol)
            view.addSubview(disc)
            let card = Self.nameCard(flag.title ?? "待ち合わせ", mood: nil)
            card.frame.origin = CGPoint(x: (size - card.frame.width) / 2, y: -card.frame.height - 6)
            view.addSubview(card)
            view.clipsToBounds = false
            return view
        }
        guard let point = annotation as? PeerPoint else { return nil }
        let id = "peer"
        let view = mapView.dequeueReusableAnnotationView(withIdentifier: id)
            ?? MKAnnotationView(annotation: annotation, reuseIdentifier: id)
        view.annotation = annotation
        view.canShowCallout = false
        view.subviews.forEach { $0.removeFromSuperview() }

        let size: CGFloat = 72
        view.frame = CGRect(x: 0, y: 0, width: size, height: size)
        view.centerOffset = CGPoint(x: 0, y: -(size / 2 + 8))

        let avatar = UIView(frame: CGRect(x: 0, y: 0, width: size, height: size))
        avatar.tag = Self.dotTag
        avatar.backgroundColor = MeetPalette.action
        avatar.layer.cornerRadius = size / 2
        avatar.layer.borderWidth = 3
        avatar.layer.borderColor = UIColor.white.cgColor
        avatar.clipsToBounds = true
        view.addSubview(avatar)
        // 影は切り抜きに消されるので、丸の外側（台）に付ける。
        view.layer.shadowColor = UIColor.black.cgColor
        view.layer.shadowOpacity = 0.4
        view.layer.shadowRadius = 6
        view.layer.shadowOffset = CGSize(width: 0, height: 3)
        applyFace(peerFace, to: view, fallback: "figure.walk")

        attachCard(to: view, name: peerName, mood: peerMood)
        return view
    }
}

private extension MKMapRect {
    init(a: MKMapPoint, b: MKMapPoint) {
        self.init(x: min(a.x, b.x), y: min(a.y, b.y),
                  width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
}
