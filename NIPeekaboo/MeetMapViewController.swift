// 離れているあいだの地図。
//
// 電波（UWB）が届く前の数百mは、数字だけでは足りない。相手がどちら側にいて、
// 自分がどこにいるかは、地図で見るのがいちばん早い。
// 近づいて電波が届いたら、この画面は用済みになる（呼んだ側が閉じる）。
import UIKit
import MapKit

final class MeetMapViewController: UIViewController {

    /// 相手の点。名前は吹き出しに出す。
    final class PeerPoint: NSObject, MKAnnotation {
        dynamic var coordinate: CLLocationCoordinate2D
        var title: String?
        var subtitle: String?
        init(coordinate: CLLocationCoordinate2D, title: String?) {
            self.coordinate = coordinate
            self.title = title
        }
    }

    private let map = MKMapView()
    private let card = UIView()
    private let headline = UILabel()
    private let number = UILabel()
    private let detail = UILabel()
    private let closeButton = CapsuleButton(type: .system)

    private let peerName: String
    private var peer: PeerPoint?
    private var line: MKPolyline?
    private var fitted = false

    init(peerName: String) {
        self.peerName = peerName
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
        card.layer.cornerRadius = 28
        card.layer.cornerCurve = .continuous
        view.addSubview(card)

        headline.font = Type.caption
        headline.textColor = MeetPalette.secondary
        number.font = Type.display
        number.textColor = MeetPalette.primary
        number.adjustsFontSizeToFitWidth = true
        number.minimumScaleFactor = 0.6
        detail.font = Type.caption
        detail.textColor = MeetPalette.secondary
        detail.numberOfLines = 2

        closeButton.configuration = .filled()
        closeButton.configuration?.title = "閉じる"
        closeButton.configuration?.baseBackgroundColor = MeetPalette.surface
        closeButton.configuration?.baseForegroundColor = MeetPalette.primary
        closeButton.addTarget(self, action: #selector(close), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [headline, number, detail, closeButton])
        stack.axis = .vertical
        stack.spacing = 8
        stack.setCustomSpacing(16, after: detail)
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        NSLayoutConstraint.activate([
            map.topAnchor.constraint(equalTo: view.topAnchor),
            map.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            map.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            map.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            card.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            card.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            card.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),

            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -20),
        ])
    }

    @objc private func close() { dismiss(animated: true) }

    /// 呼んだ側から呼ばれる。相手の居場所と、いまの見立てを渡す。
    func update(peerAt coordinate: CLLocationCoordinate2D?, meAt me: CLLocation?,
                metres: Double?, accuracy: Double?, byRadio: Bool) {
        if let coordinate {
            if let peer {
                peer.coordinate = coordinate
            } else {
                let p = PeerPoint(coordinate: coordinate, title: peerName)
                map.addAnnotation(p)
                peer = p
            }
        }
        if let metres {
            let minutes = max(1, Int((metres / 80).rounded()))
            let text = metres < 1000 ? "\(Int(metres.rounded()))m" : String(format: "%.1fkm", metres / 1000)
            headline.text = byRadio ? "電波で測っています" : "地図で見ています"
            number.text = "あと約\(minutes)分・\(text)"
            detail.text = byRadio ? "近くにいます。画面より周りを見てください"
                                  : "誤差±\(Int((accuracy ?? 0).rounded()))m。近づくと電波で測ります"
        } else {
            headline.text = "\(peerName)を待っています"
            number.text = "—"
            detail.text = "相手がアプリを開くと、ここに出ます"
        }

        // 2つの点を結ぶ線。どちら側にいるかは、線の向きでひと目でわかる。
        if let me, let coordinate {
            if let line { map.removeOverlay(line) }
            let pts = [me.coordinate, coordinate]
            let l = MKPolyline(coordinates: pts, count: 2)
            map.addOverlay(l)
            line = l
            if !fitted {
                fit(me: me.coordinate, peer: coordinate)
                fitted = true
            }
        }
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
    func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
        let r = MKPolylineRenderer(overlay: overlay)
        r.strokeColor = MeetPalette.action.withAlphaComponent(0.8)
        r.lineWidth = 3
        r.lineDashPattern = [6, 8]
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
            dot.backgroundColor = MeetPalette.primary
            dot.layer.cornerRadius = size / 2
            dot.layer.borderWidth = 3
            dot.layer.borderColor = UIColor.white.cgColor
            let figure = UIImageView(image: UIImage(systemName: "figure.stand"))
            figure.tintColor = MeetPalette.background
            figure.contentMode = .scaleAspectFit
            figure.frame = dot.bounds.insetBy(dx: 15, dy: 15)
            dot.addSubview(figure)
            view.addSubview(dot)
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
        view.frame = CGRect(x: 0, y: 0, width: size, height: size + 22)
        view.centerOffset = CGPoint(x: 0, y: -(size / 2 + 8))

        let avatar = UIView(frame: CGRect(x: 0, y: 0, width: size, height: size))
        avatar.backgroundColor = MeetPalette.action
        avatar.layer.cornerRadius = size / 2
        avatar.layer.borderWidth = 3
        avatar.layer.borderColor = UIColor.white.cgColor
        avatar.layer.shadowColor = UIColor.black.cgColor
        avatar.layer.shadowOpacity = 0.4
        avatar.layer.shadowRadius = 6
        avatar.layer.shadowOffset = CGSize(width: 0, height: 3)

        let figure = UIImageView(image: UIImage(systemName: "figure.walk"))
        figure.tintColor = .black
        figure.contentMode = .scaleAspectFit
        figure.frame = avatar.bounds.insetBy(dx: 16, dy: 16)
        avatar.addSubview(figure)
        view.addSubview(avatar)

        let label = PaddedLabel()
        label.text = point.title
        label.font = Type.font(15, .semibold, .footnote)
        label.textColor = MeetPalette.primary
        label.backgroundColor = MeetPalette.surface
        label.layer.cornerRadius = 10
        label.layer.masksToBounds = true
        label.sizeToFit()
        label.frame = CGRect(x: (size - label.frame.width) / 2, y: size + 2,
                             width: label.frame.width, height: 20)
        view.addSubview(label)
        return view
    }
}

private extension MKMapRect {
    init(a: MKMapPoint, b: MKMapPoint) {
        self.init(x: min(a.x, b.x), y: min(a.y, b.y),
                  width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
}
