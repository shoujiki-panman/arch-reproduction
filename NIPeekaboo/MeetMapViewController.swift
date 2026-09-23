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

    private func fit(me: CLLocationCoordinate2D, peer: CLLocationCoordinate2D) {
        let rect = MKMapRect(a: MKMapPoint(me), b: MKMapPoint(peer))
        // 下のカードに隠れないよう、下側を厚めに空ける
        map.setVisibleMapRect(rect, edgePadding: .init(top: 90, left: 50, bottom: 260, right: 50), animated: false)
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

    func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
        guard annotation is PeerPoint else { return nil }
        let id = "peer"
        let view = mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKMarkerAnnotationView
            ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: id)
        view.annotation = annotation
        view.markerTintColor = MeetPalette.action
        view.glyphImage = UIImage(systemName: "person.fill")
        view.canShowCallout = true
        return view
    }
}

private extension MKMapRect {
    init(a: MKMapPoint, b: MKMapPoint) {
        self.init(x: min(a.x, b.x), y: min(a.y, b.y),
                  width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
}
