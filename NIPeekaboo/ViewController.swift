/*
 ここだよ — 人混みの最後の10m。
 待つ側と迎えに行く側が、同じダイヤルを見ながら合流する。

 UWB測距は NearbyInteraction、相手発見は MultipeerConnectivity、
 カメラ内の方向は ARKit カメラアシスト(iOS 16+)。
 土台は Apple の NIPeekaboo サンプル(LICENSE.txt 参照)。
*/

import UIKit
import ARKit
import SceneKit
import NearbyInteraction
import MultipeerConnectivity
import simd

// MARK: - Meet-up protocol (the waiting side -> the side coming to find them)

struct MeetRequest: Codable {
    enum Kind: String, Codable, CaseIterable {
        case here      // ここで待ってる
        case inside    // お店・建物の中
        case outside   // 外で待ってる

        var text: String {
            switch self {
            case .here: return "ここで待ってる"
            case .inside: return "お店・建物の中"
            case .outside: return "外で待ってる"
            }
        }
        var tip: String {
            switch self {
            case .here: return "相手はその場から動かない方が早く会えます"
            case .inside: return "入口を1つ決めて、そこで待ってもらいましょう"
            case .outside: return "人の流れの外側で待ってもらいましょう"
            }
        }
    }
    enum MarkerHint: String, Codable, CaseIterable {
        case wave, standing, seated
        var text: String {
            switch self {
            case .wave: return "手を振ってる"
            case .standing: return "立って待ってる"
            case .seated: return "座って待ってる"
            }
        }
    }
    var type: String = "meet"
    var kind: Kind
    var mode: MarkerHint
}

struct CancelMessage: Codable {
    var type: String = "cancel"
}

// Announced right after connecting, so each side knows which role the peer plays.
struct HelloMessage: Codable {
    var type: String = "hello"
    var role: String
}

// MARK: - The dial both sides look at

/// A ring that fills as the gap closes, with the direction arrow in the middle.
/// Distance is a shape you watch, not a number you read.
final class MeetDial: UIView {

    private let track = CAShapeLayer()
    private let bar = CAShapeLayer()
    private let arrow = UIImageView(image: UIImage(systemName: "location.north.fill"))
    private let valueLabel = UILabel()
    private let captionLabel = UILabel()

    /// The distance at which the ring is empty.
    var span: CGFloat = 20
    var lineWidth: CGFloat = 14 { didSet { track.lineWidth = lineWidth; bar.lineWidth = lineWidth } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear

        for layer in [track, bar] {
            layer.fillColor = UIColor.clear.cgColor
            layer.lineCap = .round
            layer.lineWidth = lineWidth
            self.layer.addSublayer(layer)
        }
        track.strokeColor = UIColor.white.withAlphaComponent(0.08).cgColor
        bar.strokeColor = UIColor.white.cgColor
        bar.strokeEnd = 0

        arrow.contentMode = .scaleAspectFit
        arrow.alpha = 0.22

        valueLabel.font = .systemFont(ofSize: 30, weight: .bold)
        valueLabel.textColor = .white
        valueLabel.textAlignment = .center

        captionLabel.font = .systemFont(ofSize: 12)
        captionLabel.textColor = UIColor.white.withAlphaComponent(0.5)
        captionLabel.textAlignment = .center
        captionLabel.numberOfLines = 2

        for v in [arrow, valueLabel, captionLabel] {
            addSubview(v)
            v.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            arrow.centerXAnchor.constraint(equalTo: centerXAnchor),
            arrow.bottomAnchor.constraint(equalTo: valueLabel.topAnchor, constant: -6),
            arrow.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.20),
            arrow.heightAnchor.constraint(equalTo: arrow.widthAnchor),

            valueLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            valueLabel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 8),

            captionLabel.topAnchor.constraint(equalTo: valueLabel.bottomAnchor, constant: 2),
            captionLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            captionLabel.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.74),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let side = min(bounds.width, bounds.height)
        let radius = side / 2 - lineWidth / 2
        let path = UIBezierPath(arcCenter: CGPoint(x: bounds.midX, y: bounds.midY),
                                radius: radius,
                                startAngle: -.pi / 2,
                                endAngle: 1.5 * .pi,
                                clockwise: true)
        track.path = path.cgPath
        bar.path = path.cgPath
        track.frame = bounds
        bar.frame = bounds
    }

    func set(distance: Float?, direction: simd_float3?, colour: UIColor, value: String, caption: String) {
        valueLabel.text = value
        captionLabel.text = caption
        arrow.tintColor = colour
        bar.strokeColor = colour.cgColor

        CATransaction.begin()
        CATransaction.setAnimationDuration(0.2)
        if let distance {
            let remaining = min(max(CGFloat(distance), 0), span) / span
            bar.strokeEnd = 1 - remaining
        } else {
            bar.strokeEnd = 0
        }
        CATransaction.commit()

        guard let direction else {
            UIView.animate(withDuration: 0.2) { self.arrow.alpha = 0.22 }
            return
        }
        let angle = atan2(direction.x, -direction.z)
        UIView.animate(withDuration: 0.18) {
            self.arrow.alpha = 1
            self.arrow.transform = CGAffineTransform(rotationAngle: CGFloat(angle))
        }
    }

    func reset() {
        bar.strokeEnd = 0
        arrow.alpha = 0.22
        arrow.transform = .identity
    }
}

final class MeetViewController: UIViewController {

    // MARK: - Role

    private enum Role { case supporter, requester }   // supporter = 迎えに行く / requester = 待つ
    private var role: Role = .requester

    // MARK: - Flow state

    private enum Phase { case searching, ready, guiding, arrived }
    private var phase: Phase = .searching { didSet { applyPhase() } }

    private var activeRequest: MeetRequest?
    private var requestSent = false

    private let arrivalThreshold: Float = 1.0
    private let nearThreshold: Float = 2.5

    // MARK: - Nearby Interaction state

    /// One NI session per connected peer, so the waiting side can see every
    /// nearby helper's distance at once and choose one.
    final class PeerLink {
        let peerID: MCPeerID
        var session: NISession?
        var peerToken: NIDiscoveryToken?
        var peerRole: String?
        var distance: Float?
        var direction: simd_float3?
        var world: simd_float4x4?
        var isDemo = false
        init(peerID: MCPeerID) { self.peerID = peerID }
    }

    private var mpc: MPCSession?
    private var links: [MCPeerID: PeerLink] = [:]
    private var sessionOwners: [ObjectIdentifier: MCPeerID] = [:]
    private var activePeerID: MCPeerID?
    private var selectedHelperID: MCPeerID?
    private var supportsUWB = true
    private var cameraAssistance = false

    private var latestDistance: Float?
    private var latestDirection: simd_float3?
    private var latestWorldTransform: simd_float4x4?

    private let impactGenerator = UIImpactFeedbackGenerator(style: .medium)

    // MARK: - Proximity feedback (colour + haptics tighten as the gap closes)

    private enum ProximityBand {
        case far, mid, near, arrived
        var interval: TimeInterval {
            switch self {
            case .far: return 1.2
            case .mid: return 0.75
            case .near: return 0.4
            case .arrived: return 0
            }
        }
        var intensity: CGFloat {
            switch self {
            case .far: return 0.35
            case .mid: return 0.6
            case .near: return 0.9
            case .arrived: return 1.0
            }
        }
        var colour: UIColor {
            switch self {
            case .far: return UIColor(red: 0.98, green: 0.66, blue: 0.25, alpha: 1)
            case .mid: return UIColor(red: 1.00, green: 0.78, blue: 0.35, alpha: 1)
            case .near, .arrived: return UIColor(red: 0.21, green: 0.82, blue: 0.54, alpha: 1)
            }
        }
    }
    private var currentBand: ProximityBand?
    private var hapticTimer: Timer?
    private let proximityGenerator = UIImpactFeedbackGenerator(style: .medium)
    private let arrivalGenerator = UINotificationFeedbackGenerator()

    // MARK: - Demo

    private var demoTimer: Timer?
    private var demoDistance: Float = 7.4
    private var isDemo = false

    // MARK: - AR

    private let sceneView = ARSCNView()
    private var arrowContainer = SCNNode()
    private var dotsContainer = SCNNode()
    private var circleNode = SCNNode()
    private var arrowMaterial: SCNMaterial?
    private var dotMaterials: [SCNMaterial] = []
    private var circleMaterial: SCNMaterial?
    private var arRunning = false

    // MARK: - Palette

    private let bgColour = UIColor(red: 0.06, green: 0.06, blue: 0.07, alpha: 1)
    private let cardColour = UIColor(red: 0.13, green: 0.13, blue: 0.15, alpha: 1)
    private let amber = UIColor(red: 1.00, green: 0.65, blue: 0.24, alpha: 1)
    private let mint = UIColor(red: 0.21, green: 0.82, blue: 0.54, alpha: 1)

    // MARK: - Views

    private let homeScreen = UIView()
    private let roleSwitch = UISegmentedControl(items: ["待つ", "迎えに行く"])
    private let demoButton = UIButton(type: .system)

    private let waiterPanel = UIView()
    private let waiterSelection = UIStackView()
    private var waiterSelectionCollapse: NSLayoutConstraint?
    private let waiterDial = MeetDial()
    private let sendButton = UIButton(type: .system)
    private let cancelButton = UIButton(type: .system)
    private let waiterStatus = UILabel()
    private var kindButtons: [UIButton] = []
    private var markerButtons: [UIButton] = []
    private let peerListStack = UIStackView()
    private let peerEmptyLabel = UILabel()
    private var peerRows: [MCPeerID: UIButton] = [:]
    private var peerOrder: [MCPeerID] = []
    private var selectedKind: MeetRequest.Kind = .here
    private var selectedMarker: MeetRequest.MarkerHint = .wave

    private let finderPanel = UIView()
    private let finderChips = UIStackView()
    private let finderKindChip = PaddedLabel()
    private let finderMarkerChip = PaddedLabel()
    private let finderDial = MeetDial()
    private let cameraButton = UIButton(type: .system)
    private let finderStatus = UILabel()
    private let finderTip = UILabel()

    private let arScreen = UIView()
    private let arDial = MeetDial()
    private let arDialBackdrop = UIView()
    private let arHint = PaddedLabel()
    private let arMarkerChip = PaddedLabel()
    private let arrivalOverlay = UIView()
    private let arrivalMarker = UILabel()

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = bgColour

        if #available(iOS 16.0, *) {
            supportsUWB = NISession.deviceCapabilities.supportsPreciseDistanceMeasurement
            cameraAssistance = NISession.deviceCapabilities.supportsCameraAssistance
        } else {
            supportsUWB = NISession.isSupported
        }

        buildARScreen()
        buildHome()
        applyPhase()
        refreshSelectionStyles()
        refreshPeerList()
        refreshDials()

        if supportsUWB {
            startup()
        } else {
            waiterStatus.text = "この端末はUWBに対応していません(デモのみ動きます)"
            finderStatus.text = "この端末はUWBに対応していません(デモのみ動きます)"
        }

        #if DEBUG
        // Launch arguments used to screenshot each state while checking layout.
        let args = CommandLine.arguments
        if args.contains("-previewFinder") {
            roleSwitch.selectedSegmentIndex = 1
            roleChanged()
        }
        if args.contains("-previewDemo") {
            DispatchQueue.main.async { self.demoTapped() }
        }
        if args.contains("-previewSent") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.sendTapped() }
        }
        if args.contains("-previewAR") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.startGuidance() }
        }
        if args.contains("-previewCaps") {
            // One-shot capability dump for the real device: the answer to
            // "can this iPhone return a direction at all in Japan".
            if #available(iOS 17.0, *) {
                let c = NISession.deviceCapabilities
                print("CAPS device=\(UIDevice.current.model) os=\(UIDevice.current.systemVersion) preciseDistance=\(c.supportsPreciseDistanceMeasurement) direction=\(c.supportsDirectionMeasurement) cameraAssist=\(c.supportsCameraAssistance) extendedDistance=\(c.supportsExtendedDistanceMeasurement)")
            } else if #available(iOS 16.0, *) {
                let c = NISession.deviceCapabilities
                print("CAPS os=\(UIDevice.current.systemVersion) preciseDistance=\(c.supportsPreciseDistanceMeasurement) direction=\(c.supportsDirectionMeasurement) cameraAssist=\(c.supportsCameraAssistance)")
            }
        }
        if args.contains("-previewMeasure") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                print("MEASURE rows=\(self.peerListStack.arrangedSubviews.count) listFrame=\(self.peerListStack.frame) selectionFrame=\(self.waiterSelection.frame) panelFrame=\(self.waiterPanel.frame) dialFrame=\(self.waiterDial.frame)")
                for (i, row) in self.peerListStack.arrangedSubviews.enumerated() {
                    print("MEASURE row\(i) frame=\(row.frame) hidden=\(row.isHidden)")
                }
            }
        }
        #endif
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    // MARK: - Nearby Interaction (extended from the Apple sample to several peers)

    private func startup() {
        startupMPC()
    }

    private func startupMPC() {
        if mpc == nil {
            #if targetEnvironment(simulator)
            mpc = MPCSession(service: "nisample",
                             identity: "com.example.apple-samplecode.simulator.peekaboo-nearbyinteraction",
                             maxPeers: 3)
            #else
            mpc = MPCSession(service: "nisample",
                             identity: "com.example.apple-samplecode.peekaboo-nearbyinteraction",
                             maxPeers: 3)
            #endif
            mpc?.peerConnectedHandler = { [weak self] peer in self?.connectedToPeer(peer: peer) }
            mpc?.peerDataHandler = { [weak self] data, peer in self?.dataReceivedHandler(data: data, peer: peer) }
            mpc?.peerDisconnectedHandler = { [weak self] peer in self?.disconnectedFromPeer(peer: peer) }
        }
        mpc?.invalidate()
        mpc?.start()
    }

    private func connectedToPeer(peer: MCPeerID) {
        guard links[peer] == nil else { return }
        let link = PeerLink(peerID: peer)
        let session = NISession()
        session.delegate = self
        link.session = session
        links[peer] = link
        sessionOwners[ObjectIdentifier(session)] = peer

        if let hello = try? JSONEncoder().encode(HelloMessage(role: role == .supporter ? "supporter" : "requester")) {
            mpc?.sendData(data: hello, peers: [peer], mode: .reliable)
        }
        if let token = session.discoveryToken,
           let data = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true) {
            mpc?.sendData(data: data, peers: [peer], mode: .reliable)
        }
        refreshPeerList()
    }

    private func disconnectedFromPeer(peer: MCPeerID) {
        if let session = links[peer]?.session {
            sessionOwners.removeValue(forKey: ObjectIdentifier(session))
            session.invalidate()
        }
        links.removeValue(forKey: peer)
        if activePeerID == peer {
            activePeerID = nil
            latestDistance = nil
            latestDirection = nil
            latestWorldTransform = nil
            if role == .supporter, !isDemo { finderStatus.text = "相手との接続が切れました。探し直しています…" }
        }
        if selectedHelperID == peer { selectedHelperID = nil }
        refreshPeerList()
        refreshDials()
    }

    private func runConfig(for link: PeerLink, cameraAssist: Bool = false) {
        guard let session = link.session, let token = link.peerToken else { return }
        let config = NINearbyPeerConfiguration(peerToken: token)
        if #available(iOS 16.0, *), cameraAssistance, cameraAssist {
            config.isCameraAssistanceEnabled = true
            startARIfNeeded()
            session.setARSession(sceneView.session)
        }
        session.run(config)
    }

    /// Ends ranging with a peer and starts a fresh session, so "終わったら共有も終わる"
    /// is real rather than a label.
    private func restartLink(_ link: PeerLink) {
        if let old = link.session {
            sessionOwners.removeValue(forKey: ObjectIdentifier(old))
            old.invalidate()
        }
        link.peerToken = nil
        link.distance = nil
        link.direction = nil
        link.world = nil

        let session = NISession()
        session.delegate = self
        link.session = session
        sessionOwners[ObjectIdentifier(session)] = link.peerID
        if let token = session.discoveryToken,
           let data = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true) {
            mpc?.sendData(data: data, peers: [link.peerID], mode: .reliable)
        }
    }

    private func dataReceivedHandler(data: Data, peer: MCPeerID) {
        guard let link = links[peer] else { return }

        if let token = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NIDiscoveryToken.self, from: data) {
            link.peerToken = token
            runConfig(for: link, cameraAssist: activePeerID == peer && phase == .guiding)
            return
        }
        if let hello = try? JSONDecoder().decode(HelloMessage.self, from: data), hello.type == "hello" {
            link.peerRole = hello.role
            refreshPeerList()
            return
        }
        if let request = try? JSONDecoder().decode(MeetRequest.self, from: data), request.type == "meet" {
            guard role == .supporter, activePeerID == nil || activePeerID == peer else { return }
            activePeerID = peer
            activeRequest = request
            latestDistance = link.distance
            applyIncomingRequest(request)
            return
        }
        if let msg = try? JSONDecoder().decode(CancelMessage.self, from: data), msg.type == "cancel" {
            guard role == .supporter, activePeerID == peer else { return }
            activeRequest = nil
            activePeerID = nil
            arrivalOverlay.isHidden = true
            phase = .searching
            finderChips.isHidden = true
            finderTip.isHidden = true
            finderStatus.text = "相手が合流をやめました"
            refreshDials()
        }
    }

    private func sendMeetRequest(_ request: MeetRequest, to peer: MCPeerID) {
        guard let data = try? JSONEncoder().encode(request) else { return }
        mpc?.sendData(data: data, peers: [peer], mode: .reliable)
        activeRequest = request
    }

    /// The finder's screen mirrors whatever the waiting side chose.
    private func applyIncomingRequest(_ request: MeetRequest) {
        finderKindChip.text = request.kind.text
        finderMarkerChip.text = request.mode.text
        arMarkerChip.text = request.mode.text
        arrivalMarker.text = request.mode.text
        finderTip.text = request.kind.tip
        finderChips.isHidden = false
        finderTip.isHidden = false
        finderStatus.text = nil
        if latestDistance != nil { phase = .ready }
        impactGenerator.impactOccurred()
        refreshDials()
    }

    // MARK: - Measurement funnel (real NI and demo both land here)

    private func updateMeasurement(distance: Float?, direction: simd_float3?, world: simd_float4x4?) {
        latestDistance = distance
        latestDirection = direction
        latestWorldTransform = world

        if distance != nil, phase == .searching, role == .requester || activeRequest != nil || isDemo {
            phase = .ready
        }
        refreshDials()

        if phase == .guiding {
            updateGuidance()
            if let d = distance, d < arrivalThreshold { arrive() }
        }
    }

    private func band(for distance: Float) -> ProximityBand {
        if distance < arrivalThreshold { return .arrived }
        if distance < nearThreshold { return .near }
        if distance < 5.0 { return .mid }
        return .far
    }

    private func formatMeters(_ d: Float) -> String {
        d >= 2 ? String(format: "%.0f m", d.rounded()) : String(format: "%.1f m", d)
    }

    /// Every dial on screen reads the same measurement.
    private func refreshDials() {
        let colour = latestDistance.map { band(for: $0).colour } ?? UIColor.white.withAlphaComponent(0.35)
        let idleColour = UIColor.white.withAlphaComponent(0.35)

        if role == .requester {
            waiterDial.isHidden = !requestSent
            if requestSent {
                let value = latestDistance.map { $0 < arrivalThreshold ? "合流" : formatMeters($0) } ?? "—"
                let caption: String
                if let d = latestDistance, d < arrivalThreshold {
                    caption = "顔を上げてください"
                } else if latestDirection == nil {
                    caption = "方向を測定中\n端末をゆっくり動かして"
                } else {
                    caption = "相手はこの方向"
                }
                waiterDial.set(distance: latestDistance, direction: latestDirection,
                               colour: colour, value: value, caption: caption)
            } else {
                waiterDial.set(distance: nil, direction: nil, colour: idleColour,
                               value: "—", caption: "「ここだよ」を送ると\n相手との距離が出ます")
            }
        } else {
            let waiting = activeRequest == nil
            let value = waiting ? "—" : (latestDistance.map { $0 < arrivalThreshold ? "合流" : formatMeters($0) } ?? "—")
            let caption: String
            if waiting {
                caption = "「ここだよ」を待っています"
            } else if let d = latestDistance, d < arrivalThreshold {
                caption = "顔を上げてください"
            } else if latestDirection == nil {
                caption = "方向を測定中\n端末をゆっくり動かして"
            } else {
                caption = "この方向にいます"
            }
            finderDial.set(distance: waiting ? nil : latestDistance,
                           direction: waiting ? nil : latestDirection,
                           colour: waiting ? idleColour : colour,
                           value: value, caption: caption)
            let ready = activeRequest != nil && latestDistance != nil
            cameraButton.isEnabled = ready
            cameraButton.alpha = ready ? 1 : 0.4
        }
    }

    // MARK: - Phase handling

    private func applyPhase() {
        let showAR = role == .supporter && (phase == .guiding || phase == .arrived)
        arScreen.isHidden = !showAR
        homeScreen.isHidden = showAR
        waiterPanel.isHidden = role != .requester
        finderPanel.isHidden = role != .supporter
        arrivalOverlay.isHidden = phase != .arrived
        if phase != .guiding { stopProximityFeedback() }
    }

    @objc private func roleChanged() {
        let next: Role = roleSwitch.selectedSegmentIndex == 0 ? .requester : .supporter
        guard next != role else { return }
        resetSession()
        role = next
        phase = .searching
        if supportsUWB { startup() }
        refreshPeerList()
        refreshDials()
    }

    /// Tears every link down so a role change starts from a clean state.
    private func resetSession() {
        stopProximityFeedback()
        if isDemo { stopDemo() }
        for link in links.values { link.session?.invalidate() }
        links.removeAll()
        sessionOwners.removeAll()
        peerRows.removeAll()
        peerOrder.removeAll()
        peerListStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        mpc?.invalidate()
        mpc = nil

        activePeerID = nil
        selectedHelperID = nil
        activeRequest = nil
        requestSent = false
        latestDistance = nil
        latestDirection = nil
        latestWorldTransform = nil

        sendButton.isHidden = false
        cancelButton.isHidden = true
        setWaiterSelection(hidden: false)
        waiterStatus.text = "場所と目印を選んで、迎えに来てもらう相手に送ります"
        finderChips.isHidden = true
        finderTip.isHidden = true
        finderStatus.text = nil
        arrivalOverlay.isHidden = true
        waiterDial.reset()
        finderDial.reset()
    }

    @objc private func startGuidance() {
        startARIfNeeded()
        if let id = activePeerID, let link = links[id] { runConfig(for: link, cameraAssist: true) }
        phase = .guiding
        updateGuidance()
    }

    @objc private func closeAR() {
        stopProximityFeedback()
        phase = latestDistance != nil ? .ready : .searching
    }

    private func arrive() {
        guard phase != .arrived else { return }
        phase = .arrived
        if isDemo { demoTimer?.invalidate() }
        arrivalGenerator.notificationOccurred(.success)
    }

    @objc private func finishMeet() {
        stopProximityFeedback()
        if isDemo { stopDemo() }
        if let id = activePeerID, let link = links[id], !link.isDemo { restartLink(link) }
        activePeerID = nil
        activeRequest = nil
        latestDistance = nil
        latestDirection = nil
        arrivalOverlay.isHidden = true
        finderChips.isHidden = true
        finderTip.isHidden = true
        finderStatus.text = nil
        phase = .searching
        refreshDials()
    }

    // MARK: - Demo

    @objc private func demoTapped() {
        if isDemo { stopDemo(); return }
        isDemo = true
        demoButton.setTitle("デモ停止", for: .normal)

        if role == .requester {
            for (name, distance) in [("会場スタッフのiPhone", Float(7.4)),
                                     ("となりの席のiPhone", Float(15.6)),
                                     ("受付のiPhone", Float(24.1))] {
                let peerID = MCPeerID(displayName: name)
                let link = PeerLink(peerID: peerID)
                link.isDemo = true
                link.peerRole = "supporter"
                link.distance = distance
                links[peerID] = link
            }
            waiterStatus.text = "デモ(シミュレーション)。距離は実測ではありません"
            refreshPeerList()
        } else {
            demoDistance = 7.4
            activeRequest = MeetRequest(kind: selectedKind, mode: selectedMarker)
            applyIncomingRequest(activeRequest!)
            finderStatus.text = "デモ(シミュレーション)。距離は実測ではありません"
        }

        demoTimer?.invalidate()
        demoTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            let azimuth: Float = 0.18 * sinf(Float(Date().timeIntervalSince1970) * 0.7)
            let direction = simd_float3(sinf(azimuth), 0, -cosf(azimuth))

            if self.role == .requester {
                for (peerID, link) in self.links where link.isDemo {
                    if self.requestSent, peerID == self.activePeerID {
                        link.distance = max(0.4, (link.distance ?? 7.4) - 0.11)
                        link.direction = direction
                        self.updateMeasurement(distance: link.distance, direction: direction, world: nil)
                    } else {
                        link.distance = max(1.0, (link.distance ?? 10) + Float.random(in: -0.2...0.2))
                    }
                }
                self.refreshPeerList()
            } else {
                if self.phase == .guiding {
                    self.demoDistance = max(0.4, self.demoDistance - 0.11 + Float.random(in: -0.02...0.02))
                }
                self.updateMeasurement(distance: self.demoDistance, direction: direction, world: nil)
            }
        }
    }

    private func stopDemo() {
        isDemo = false
        demoTimer?.invalidate()
        demoTimer = nil
        demoButton.setTitle("デモ", for: .normal)
        demoDistance = 7.4

        for (peerID, link) in links where link.isDemo {
            link.session?.invalidate()
            links.removeValue(forKey: peerID)
            if activePeerID == peerID { activePeerID = nil }
            if selectedHelperID == peerID { selectedHelperID = nil }
        }
        if role == .supporter {
            activeRequest = nil
            finderChips.isHidden = true
            finderTip.isHidden = true
        } else {
            requestSent = false
            setWaiterSelection(hidden: false)
            sendButton.isHidden = false
            cancelButton.isHidden = true
            waiterStatus.text = "場所と目印を選んで、迎えに来てもらう相手に送ります"
        }
        latestDistance = nil
        latestDirection = nil
        phase = .searching
        waiterDial.reset()
        finderDial.reset()
        refreshPeerList()
        refreshDials()
    }

    // MARK: - AR guidance rendering

    private func startARIfNeeded() {
        guard !arRunning else { return }
        #if !targetEnvironment(simulator)
        let config = ARWorldTrackingConfiguration()
        config.worldAlignment = .gravity
        sceneView.session.run(config)
        #endif
        arRunning = true
    }

    private func setARGuidesHidden(_ hidden: Bool) {
        arrowContainer.isHidden = hidden
        dotsContainer.isHidden = hidden
        circleNode.isHidden = hidden
    }

    private func updateGuidance() {
        guard phase == .guiding else { return }
        updateProximityFeedback(distance: latestDistance)

        guard let distance = latestDistance else {
            arHint.text = "端末をゆっくり動かしてください"
            arHint.isHidden = false
            arDial.set(distance: nil, direction: nil, colour: UIColor.white.withAlphaComponent(0.35),
                       value: "—", caption: "測定中")
            setARGuidesHidden(true)
            return
        }

        let colour = band(for: distance).colour
        arDial.set(distance: distance, direction: latestDirection, colour: colour,
                   value: distance < arrivalThreshold ? "合流" : formatMeters(distance),
                   caption: distance < nearThreshold ? "すぐそこ" : "")

        // Positioning source: AR world transform (best) > direction (good) > none.
        let cam = sceneView.pointOfView
        var horizontalDir: simd_float3?
        var peerWorldPos: simd_float3?

        if let world = latestWorldTransform {
            let p = simd_float3(world.columns.3.x, world.columns.3.y, world.columns.3.z)
            peerWorldPos = p
            if let camPos = cam?.simdWorldPosition {
                var v = p - camPos
                v.y = 0
                if simd_length(v) > 0.01 { horizontalDir = simd_normalize(v) }
            }
        } else if let dir = latestDirection, let camNode = cam {
            let worldDir = camNode.simdConvertVector(simd_float3(dir.x, dir.y, dir.z), to: nil)
            var v = worldDir
            v.y = 0
            if simd_length(v) > 0.01 { horizontalDir = simd_normalize(v) }
        }

        guard let camNode = cam, let dir = horizontalDir else {
            arHint.text = "端末をゆっくり動かしてください"
            arHint.isHidden = false
            setARGuidesHidden(true)
            return
        }
        arHint.text = distance < nearThreshold ? "画面から顔を上げて探してください" : nil
        arHint.isHidden = arHint.text == nil

        let camPos = camNode.simdWorldPosition
        let floorY = camPos.y - 1.25

        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0.18

        if distance < nearThreshold,
           let peerPos = peerWorldPos ?? optionalPeerPos(camPos: camPos, dir: dir, distance: distance) {
            arrowContainer.isHidden = true
            dotsContainer.isHidden = true
            circleNode.isHidden = false
            circleNode.simdPosition = simd_float3(peerPos.x, floorY, peerPos.z)
        } else {
            circleNode.isHidden = true
            arrowContainer.isHidden = false
            dotsContainer.isHidden = false

            let arrowPos = camPos + dir * 1.35
            arrowContainer.simdPosition = simd_float3(arrowPos.x, floorY + 0.15, arrowPos.z)
            let lookTarget = arrowContainer.simdPosition + dir
            arrowContainer.simdLook(at: lookTarget, up: simd_float3(0, 1, 0), localFront: simd_float3(0, 0, -1))

            let dotCount = dotsContainer.childNodes.count
            let usable = min(distance - 1.6, 4.5)
            for (i, dot) in dotsContainer.childNodes.enumerated() {
                let t = Float(i + 1) / Float(dotCount)
                if usable <= 0.4 { dot.isHidden = true; continue }
                dot.isHidden = false
                let dist: Float = 1.7 + t * usable
                let p = camPos + dir * dist
                dot.simdPosition = simd_float3(p.x, floorY + 0.01, p.z)
            }
        }
        SCNTransaction.commit()
    }

    private func optionalPeerPos(camPos: simd_float3, dir: simd_float3, distance: Float) -> simd_float3? {
        camPos + dir * distance
    }

    // MARK: - Proximity feedback

    private func updateProximityFeedback(distance: Float?) {
        guard phase == .guiding, let distance else { return }
        let next = band(for: distance)
        guard next != currentBand else { return }
        currentBand = next
        applyBandColour(next)

        hapticTimer?.invalidate()
        hapticTimer = nil
        guard next != .arrived else { return }
        proximityGenerator.prepare()
        proximityGenerator.impactOccurred(intensity: next.intensity)
        hapticTimer = Timer.scheduledTimer(withTimeInterval: next.interval, repeats: true) { [weak self] _ in
            guard let self, self.phase == .guiding else { return }
            self.proximityGenerator.impactOccurred(intensity: next.intensity)
        }
    }

    private func stopProximityFeedback() {
        hapticTimer?.invalidate()
        hapticTimer = nil
        currentBand = nil
    }

    private func applyBandColour(_ band: ProximityBand) {
        let colour = band.colour
        arrowMaterial?.diffuse.contents = colour.withAlphaComponent(0.95)
        arrowMaterial?.emission.contents = darker(colour, 0.5)
        for material in dotMaterials {
            material.diffuse.contents = colour.withAlphaComponent(0.85)
            material.emission.contents = darker(colour, 0.5)
        }
        circleMaterial?.diffuse.contents = colour.withAlphaComponent(0.8)
        circleMaterial?.emission.contents = darker(colour, 0.5)
    }

    private func darker(_ colour: UIColor, _ factor: CGFloat) -> UIColor {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        colour.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return UIColor(hue: h, saturation: s, brightness: b * factor, alpha: a)
    }

    // MARK: - Home (one screen, a switch instead of two separate flows)

    private func buildHome() {
        homeScreen.backgroundColor = bgColour
        view.addSubview(homeScreen)
        homeScreen.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            homeScreen.topAnchor.constraint(equalTo: view.topAnchor),
            homeScreen.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            homeScreen.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            homeScreen.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        let safe = homeScreen.safeAreaLayoutGuide

        let title = UILabel()
        title.text = "ここだよ"
        title.font = .systemFont(ofSize: 17, weight: .bold)
        title.textColor = .white

        demoButton.setTitle("デモ", for: .normal)
        demoButton.setTitleColor(UIColor.white.withAlphaComponent(0.45), for: .normal)
        demoButton.titleLabel?.font = .systemFont(ofSize: 13)
        demoButton.addTarget(self, action: #selector(demoTapped), for: .touchUpInside)

        roleSwitch.selectedSegmentIndex = 0
        roleSwitch.selectedSegmentTintColor = amber
        roleSwitch.backgroundColor = cardColour
        roleSwitch.setTitleTextAttributes([.foregroundColor: UIColor.white.withAlphaComponent(0.7),
                                           .font: UIFont.systemFont(ofSize: 15, weight: .semibold)], for: .normal)
        roleSwitch.setTitleTextAttributes([.foregroundColor: UIColor.black,
                                           .font: UIFont.systemFont(ofSize: 15, weight: .bold)], for: .selected)
        roleSwitch.addTarget(self, action: #selector(roleChanged), for: .valueChanged)

        for v in [title, demoButton, roleSwitch] {
            homeScreen.addSubview(v)
            v.translatesAutoresizingMaskIntoConstraints = false
        }

        buildWaiterPanel()
        buildFinderPanel()
        for panel in [waiterPanel, finderPanel] {
            homeScreen.addSubview(panel)
            panel.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                panel.topAnchor.constraint(equalTo: roleSwitch.bottomAnchor, constant: 18),
                panel.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
                panel.trailingAnchor.constraint(equalTo: safe.trailingAnchor),
                panel.bottomAnchor.constraint(equalTo: safe.bottomAnchor),
            ])
        }

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: safe.topAnchor, constant: 10),
            title.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 20),
            demoButton.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            demoButton.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -20),

            roleSwitch.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 14),
            roleSwitch.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 20),
            roleSwitch.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -20),
            roleSwitch.heightAnchor.constraint(equalToConstant: 40),
        ])
    }

    // MARK: - Waiting side

    private func buildWaiterPanel() {
        let kindRow = chipRow(titles: MeetRequest.Kind.allCases.map { $0.text },
                              action: #selector(kindTapped(_:)), store: &kindButtons)
        let markerRow = chipRow(titles: MeetRequest.MarkerHint.allCases.map { $0.text },
                                action: #selector(markerTapped(_:)), store: &markerButtons)

        peerListStack.axis = .vertical
        peerListStack.spacing = 1
        peerListStack.backgroundColor = UIColor.white.withAlphaComponent(0.06)
        peerListStack.layer.cornerRadius = 12
        peerListStack.clipsToBounds = true

        peerEmptyLabel.text = "近くで「迎えに行く」にしている人を探しています…"
        peerEmptyLabel.font = .systemFont(ofSize: 13)
        peerEmptyLabel.textColor = UIColor.white.withAlphaComponent(0.4)
        peerEmptyLabel.numberOfLines = 0

        waiterSelection.axis = .vertical
        waiterSelection.spacing = 8
        waiterSelection.addArrangedSubview(sectionLabel("いまどこにいる?"))
        waiterSelection.addArrangedSubview(kindRow)
        waiterSelection.setCustomSpacing(18, after: kindRow)
        waiterSelection.addArrangedSubview(sectionLabel("目印は?"))
        waiterSelection.addArrangedSubview(markerRow)
        waiterSelection.setCustomSpacing(18, after: markerRow)
        waiterSelection.addArrangedSubview(sectionLabel("迎えに来てくれる人"))
        waiterSelection.addArrangedSubview(peerListStack)
        waiterSelection.addArrangedSubview(peerEmptyLabel)

        sendButton.configuration = primaryConfig(title: "ここだよ と伝える",
                                                 image: "hand.wave.fill",
                                                 background: amber,
                                                 foreground: .black)
        sendButton.addTarget(self, action: #selector(sendTapped), for: .touchUpInside)

        var cancelConf = UIButton.Configuration.plain()
        cancelConf.title = "合流をやめる"
        cancelConf.baseForegroundColor = UIColor.white.withAlphaComponent(0.65)
        cancelButton.configuration = cancelConf
        cancelButton.isHidden = true
        cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)

        waiterStatus.text = "場所と目印を選んで、迎えに来てもらう相手に送ります"
        waiterStatus.font = .systemFont(ofSize: 12)
        waiterStatus.textColor = UIColor.white.withAlphaComponent(0.45)
        waiterStatus.textAlignment = .center
        waiterStatus.numberOfLines = 3

        for v in [waiterSelection, waiterDial, sendButton, cancelButton, waiterStatus] {
            waiterPanel.addSubview(v)
            v.translatesAutoresizingMaskIntoConstraints = false
        }

        // Hidden views still hold their space, so collapse the selection outright
        // once the request is out — otherwise it keeps pushing the dial down.
        let collapse = waiterSelection.heightAnchor.constraint(equalToConstant: 0)
        collapse.priority = .required
        waiterSelectionCollapse = collapse

        // The list keeps its natural height; the dial gives way instead of squashing it.
        waiterSelection.setContentCompressionResistancePriority(.required, for: .vertical)
        peerListStack.setContentCompressionResistancePriority(.required, for: .vertical)
        let dialCentre = waiterDial.centerYAnchor.constraint(equalTo: waiterPanel.centerYAnchor, constant: -10)
        dialCentre.priority = .defaultHigh
        dialCentre.isActive = true

        NSLayoutConstraint.activate([
            waiterSelection.topAnchor.constraint(equalTo: waiterPanel.topAnchor),
            waiterSelection.leadingAnchor.constraint(equalTo: waiterPanel.leadingAnchor, constant: 20),
            waiterSelection.trailingAnchor.constraint(equalTo: waiterPanel.trailingAnchor, constant: -20),

            waiterDial.centerXAnchor.constraint(equalTo: waiterPanel.centerXAnchor),
            waiterDial.topAnchor.constraint(greaterThanOrEqualTo: waiterSelection.bottomAnchor, constant: 16),
            waiterDial.widthAnchor.constraint(equalToConstant: 210),
            waiterDial.heightAnchor.constraint(equalToConstant: 210),

            sendButton.leadingAnchor.constraint(equalTo: waiterPanel.leadingAnchor, constant: 24),
            sendButton.trailingAnchor.constraint(equalTo: waiterPanel.trailingAnchor, constant: -24),
            sendButton.bottomAnchor.constraint(equalTo: waiterStatus.topAnchor, constant: -12),

            waiterStatus.leadingAnchor.constraint(equalTo: waiterPanel.leadingAnchor, constant: 24),
            waiterStatus.trailingAnchor.constraint(equalTo: waiterPanel.trailingAnchor, constant: -24),
            waiterStatus.bottomAnchor.constraint(equalTo: cancelButton.topAnchor, constant: -6),

            cancelButton.centerXAnchor.constraint(equalTo: waiterPanel.centerXAnchor),
            cancelButton.bottomAnchor.constraint(equalTo: waiterPanel.bottomAnchor, constant: -6),
        ])
    }

    // MARK: - Finding side

    private func buildFinderPanel() {
        finderChips.axis = .horizontal
        finderChips.spacing = 8
        finderChips.alignment = .center
        finderChips.isHidden = true
        style(chip: finderKindChip, background: amber.withAlphaComponent(0.9), text: .black)
        style(chip: finderMarkerChip, background: UIColor.white.withAlphaComponent(0.12), text: .white)
        finderKindChip.text = "ここで待ってる"
        finderMarkerChip.text = "手を振ってる"
        finderChips.addArrangedSubview(finderKindChip)
        finderChips.addArrangedSubview(finderMarkerChip)
        finderChips.addArrangedSubview(UIView())

        cameraButton.configuration = primaryConfig(title: "カメラで探す",
                                                   image: "camera.viewfinder",
                                                   background: mint,
                                                   foreground: .black)
        cameraButton.addTarget(self, action: #selector(startGuidance), for: .touchUpInside)
        cameraButton.isEnabled = false
        cameraButton.alpha = 0.4

        finderStatus.font = .systemFont(ofSize: 12)
        finderStatus.textColor = UIColor.white.withAlphaComponent(0.45)
        finderStatus.textAlignment = .center
        finderStatus.numberOfLines = 2

        finderTip.font = .systemFont(ofSize: 12)
        finderTip.textColor = UIColor.white.withAlphaComponent(0.45)
        finderTip.textAlignment = .center
        finderTip.numberOfLines = 2
        finderTip.isHidden = true

        for v in [finderChips, finderDial, cameraButton, finderTip, finderStatus] {
            finderPanel.addSubview(v)
            v.translatesAutoresizingMaskIntoConstraints = false
        }

        NSLayoutConstraint.activate([
            finderChips.topAnchor.constraint(equalTo: finderPanel.topAnchor, constant: 4),
            finderChips.leadingAnchor.constraint(equalTo: finderPanel.leadingAnchor, constant: 20),
            finderChips.trailingAnchor.constraint(equalTo: finderPanel.trailingAnchor, constant: -20),

            finderDial.centerXAnchor.constraint(equalTo: finderPanel.centerXAnchor),
            finderDial.centerYAnchor.constraint(equalTo: finderPanel.centerYAnchor, constant: -20),
            finderDial.widthAnchor.constraint(equalToConstant: 260),
            finderDial.heightAnchor.constraint(equalToConstant: 260),

            finderTip.leadingAnchor.constraint(equalTo: finderPanel.leadingAnchor, constant: 24),
            finderTip.trailingAnchor.constraint(equalTo: finderPanel.trailingAnchor, constant: -24),
            finderTip.bottomAnchor.constraint(equalTo: cameraButton.topAnchor, constant: -16),

            cameraButton.leadingAnchor.constraint(equalTo: finderPanel.leadingAnchor, constant: 24),
            cameraButton.trailingAnchor.constraint(equalTo: finderPanel.trailingAnchor, constant: -24),
            cameraButton.bottomAnchor.constraint(equalTo: finderStatus.topAnchor, constant: -12),

            finderStatus.leadingAnchor.constraint(equalTo: finderPanel.leadingAnchor, constant: 24),
            finderStatus.trailingAnchor.constraint(equalTo: finderPanel.trailingAnchor, constant: -24),
            finderStatus.bottomAnchor.constraint(equalTo: finderPanel.bottomAnchor, constant: -10),
        ])
    }

    // MARK: - AR screen

    private func buildARScreen() {
        arScreen.backgroundColor = .black
        arScreen.isHidden = true
        view.addSubview(arScreen)
        arScreen.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            arScreen.topAnchor.constraint(equalTo: view.topAnchor),
            arScreen.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            arScreen.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            arScreen.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        sceneView.automaticallyUpdatesLighting = true
        sceneView.scene = SCNScene()
        arScreen.addSubview(sceneView)
        sceneView.translatesAutoresizingMaskIntoConstraints = false
        buildARNodes()

        let safe = arScreen.safeAreaLayoutGuide

        let close = UIButton(type: .system)
        var closeConf = UIButton.Configuration.filled()
        closeConf.title = "閉じる"
        closeConf.baseBackgroundColor = UIColor.black.withAlphaComponent(0.5)
        closeConf.baseForegroundColor = .white
        closeConf.cornerStyle = .capsule
        closeConf.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16)
        close.configuration = closeConf
        close.addTarget(self, action: #selector(closeAR), for: .touchUpInside)

        style(chip: arMarkerChip, background: UIColor.black.withAlphaComponent(0.55), text: .white)
        arMarkerChip.text = "手を振ってる"

        // Camera video sits behind these, so both need their own ground.
        arHint.font = .systemFont(ofSize: 14, weight: .semibold)
        arHint.textColor = .white
        arHint.textAlignment = .center
        arHint.numberOfLines = 2
        arHint.insets = UIEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
        arHint.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        arHint.layer.cornerRadius = 12
        arHint.clipsToBounds = true

        arDialBackdrop.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        arDialBackdrop.layer.cornerRadius = 83
        arDial.lineWidth = 10

        for v in [close, arMarkerChip, arDialBackdrop, arHint, arDial] {
            arScreen.addSubview(v)
            v.translatesAutoresizingMaskIntoConstraints = false
        }

        buildArrivalOverlay()

        NSLayoutConstraint.activate([
            sceneView.topAnchor.constraint(equalTo: arScreen.topAnchor),
            sceneView.bottomAnchor.constraint(equalTo: arScreen.bottomAnchor),
            sceneView.leadingAnchor.constraint(equalTo: arScreen.leadingAnchor),
            sceneView.trailingAnchor.constraint(equalTo: arScreen.trailingAnchor),

            close.topAnchor.constraint(equalTo: safe.topAnchor, constant: 8),
            close.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 16),
            arMarkerChip.centerYAnchor.constraint(equalTo: close.centerYAnchor),
            arMarkerChip.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -16),

            arHint.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 24),
            arHint.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -24),
            arHint.bottomAnchor.constraint(equalTo: arDial.topAnchor, constant: -12),

            arDial.centerXAnchor.constraint(equalTo: arScreen.centerXAnchor),
            arDial.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -24),
            arDial.widthAnchor.constraint(equalToConstant: 150),
            arDial.heightAnchor.constraint(equalToConstant: 150),

            arDialBackdrop.centerXAnchor.constraint(equalTo: arDial.centerXAnchor),
            arDialBackdrop.centerYAnchor.constraint(equalTo: arDial.centerYAnchor),
            arDialBackdrop.widthAnchor.constraint(equalToConstant: 166),
            arDialBackdrop.heightAnchor.constraint(equalToConstant: 166),
        ])

        arScreen.sendSubviewToBack(sceneView)
        arScreen.bringSubviewToFront(close)
    }

    private func buildArrivalOverlay() {
        arrivalOverlay.backgroundColor = mint
        arrivalOverlay.isHidden = true
        arScreen.addSubview(arrivalOverlay)
        arrivalOverlay.translatesAutoresizingMaskIntoConstraints = false

        let headline = UILabel()
        headline.text = "見つけた"
        headline.font = .systemFont(ofSize: 40, weight: .heavy)
        headline.textColor = .black
        headline.textAlignment = .center

        let sub = UILabel()
        sub.text = "スマホをしまって顔を上げましょう"
        sub.font = .systemFont(ofSize: 15, weight: .semibold)
        sub.textColor = UIColor.black.withAlphaComponent(0.7)
        sub.textAlignment = .center

        let markerCaption = UILabel()
        markerCaption.text = "相手の目印"
        markerCaption.font = .systemFont(ofSize: 12)
        markerCaption.textColor = UIColor.black.withAlphaComponent(0.55)
        markerCaption.textAlignment = .center

        arrivalMarker.text = "手を振ってる"
        arrivalMarker.font = .systemFont(ofSize: 26, weight: .bold)
        arrivalMarker.textColor = .black
        arrivalMarker.textAlignment = .center

        let done = UIButton(type: .system)
        var doneConf = UIButton.Configuration.filled()
        doneConf.title = "合流を終える"
        doneConf.baseBackgroundColor = .black
        doneConf.baseForegroundColor = .white
        doneConf.cornerStyle = .capsule
        doneConf.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 32, bottom: 14, trailing: 32)
        done.configuration = doneConf
        done.addTarget(self, action: #selector(finishMeet), for: .touchUpInside)

        for v in [headline, sub, markerCaption, arrivalMarker, done] {
            arrivalOverlay.addSubview(v)
            v.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            arrivalOverlay.topAnchor.constraint(equalTo: arScreen.topAnchor),
            arrivalOverlay.bottomAnchor.constraint(equalTo: arScreen.bottomAnchor),
            arrivalOverlay.leadingAnchor.constraint(equalTo: arScreen.leadingAnchor),
            arrivalOverlay.trailingAnchor.constraint(equalTo: arScreen.trailingAnchor),

            headline.centerXAnchor.constraint(equalTo: arrivalOverlay.centerXAnchor),
            headline.centerYAnchor.constraint(equalTo: arrivalOverlay.centerYAnchor, constant: -60),
            sub.topAnchor.constraint(equalTo: headline.bottomAnchor, constant: 6),
            sub.centerXAnchor.constraint(equalTo: arrivalOverlay.centerXAnchor),

            markerCaption.topAnchor.constraint(equalTo: sub.bottomAnchor, constant: 40),
            markerCaption.centerXAnchor.constraint(equalTo: arrivalOverlay.centerXAnchor),
            arrivalMarker.topAnchor.constraint(equalTo: markerCaption.bottomAnchor, constant: 2),
            arrivalMarker.centerXAnchor.constraint(equalTo: arrivalOverlay.centerXAnchor),

            done.centerXAnchor.constraint(equalTo: arrivalOverlay.centerXAnchor),
            done.bottomAnchor.constraint(equalTo: arrivalOverlay.safeAreaLayoutGuide.bottomAnchor, constant: -28),
        ])
    }

    private func buildARNodes() {
        let root = sceneView.scene.rootNode

        let path = UIBezierPath()
        path.move(to: CGPoint(x: -0.10, y: 0))
        path.addLine(to: CGPoint(x: -0.10, y: 0.30))
        path.addLine(to: CGPoint(x: -0.26, y: 0.30))
        path.addLine(to: CGPoint(x: 0, y: 0.62))
        path.addLine(to: CGPoint(x: 0.26, y: 0.30))
        path.addLine(to: CGPoint(x: 0.10, y: 0.30))
        path.addLine(to: CGPoint(x: 0.10, y: 0))
        path.close()
        let shape = SCNShape(path: path, extrusionDepth: 0.10)
        let mat = SCNMaterial()
        mat.diffuse.contents = amber.withAlphaComponent(0.95)
        mat.emission.contents = darker(amber, 0.5)
        mat.lightingModel = .physicallyBased
        shape.materials = [mat]
        arrowMaterial = mat
        let arrowNode = SCNNode(geometry: shape)
        arrowNode.eulerAngles = SCNVector3(-Float.pi / 2 + 0.18, 0, 0)
        arrowNode.position = SCNVector3(0, 0, 0.3)
        arrowContainer = SCNNode()
        arrowContainer.addChildNode(arrowNode)
        arrowContainer.isHidden = true
        root.addChildNode(arrowContainer)

        dotsContainer = SCNNode()
        for _ in 0..<8 {
            let geom = SCNCylinder(radius: 0.05, height: 0.012)
            let dmat = SCNMaterial()
            dmat.diffuse.contents = amber.withAlphaComponent(0.85)
            dmat.emission.contents = darker(amber, 0.5)
            geom.materials = [dmat]
            dotMaterials.append(dmat)
            let dot = SCNNode(geometry: geom)
            dot.isHidden = true
            dotsContainer.addChildNode(dot)
        }
        dotsContainer.isHidden = true
        root.addChildNode(dotsContainer)

        let tube = SCNTube(innerRadius: 0.52, outerRadius: 0.60, height: 0.012)
        let cmat = SCNMaterial()
        cmat.diffuse.contents = mint.withAlphaComponent(0.8)
        cmat.emission.contents = darker(mint, 0.5)
        tube.materials = [cmat]
        circleMaterial = cmat
        circleNode = SCNNode(geometry: tube)
        circleNode.isHidden = true
        root.addChildNode(circleNode)
    }

    // MARK: - Selection + helper list

    @objc private func kindTapped(_ sender: UIButton) {
        let kinds = MeetRequest.Kind.allCases
        guard sender.tag < kinds.count else { return }
        selectedKind = kinds[sender.tag]
        impactGenerator.impactOccurred()
        refreshSelectionStyles()
    }

    @objc private func markerTapped(_ sender: UIButton) {
        let markers = MeetRequest.MarkerHint.allCases
        guard sender.tag < markers.count else { return }
        selectedMarker = markers[sender.tag]
        impactGenerator.impactOccurred()
        refreshSelectionStyles()
    }

    private func refreshSelectionStyles() {
        for (index, button) in kindButtons.enumerated() where index < MeetRequest.Kind.allCases.count {
            style(chipButton: button, selected: MeetRequest.Kind.allCases[index] == selectedKind)
        }
        for (index, button) in markerButtons.enumerated() where index < MeetRequest.MarkerHint.allCases.count {
            style(chipButton: button, selected: MeetRequest.MarkerHint.allCases[index] == selectedMarker)
        }
    }

    /// Rebuild rows only when the set changes, so live distances don't fight taps.
    private func refreshPeerList() {
        guard role == .requester else { return }

        // Ordered by name, not by distance: live distances jitter, and rows that
        // reshuffle under the thumb are impossible to tap.
        let helpers = links.values
            .filter { $0.peerRole == "supporter" || $0.isDemo }
            .sorted { $0.peerID.displayName < $1.peerID.displayName }
        let ids = helpers.map { $0.peerID }

        if Set(ids) != Set(peerOrder) {
            peerOrder = ids
            peerListStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
            peerRows.removeAll()
            for link in helpers {
                let row = peerRow(name: link.peerID.displayName)
                row.setContentCompressionResistancePriority(.required, for: .vertical)
                row.addTarget(self, action: #selector(peerTapped(_:)), for: .touchUpInside)
                peerRows[link.peerID] = row
                peerListStack.addArrangedSubview(row)
            }
        }

        if selectedHelperID == nil || !ids.contains(where: { $0 == selectedHelperID }) {
            // Default to the nearest one that has a measurement.
            selectedHelperID = helpers.min { ($0.distance ?? .greatestFiniteMagnitude) < ($1.distance ?? .greatestFiniteMagnitude) }?.peerID
        }

        for link in helpers {
            guard let row = peerRows[link.peerID] else { continue }
            row.configuration?.title = link.peerID.displayName
            row.configuration?.subtitle = link.distance.map { "あと \(formatMeters($0))" } ?? "測定中…"
            let selected = link.peerID == selectedHelperID
            row.configuration?.baseForegroundColor = selected ? .white : UIColor.white.withAlphaComponent(0.6)
            row.backgroundColor = selected ? amber.withAlphaComponent(0.22) : cardColour
        }

        peerListStack.isHidden = helpers.isEmpty
        peerEmptyLabel.isHidden = !helpers.isEmpty
        if !requestSent {
            sendButton.isEnabled = !helpers.isEmpty
            sendButton.alpha = helpers.isEmpty ? 0.4 : 1
        }
    }

    @objc private func peerTapped(_ sender: UIButton) {
        guard let peerID = peerRows.first(where: { $0.value === sender })?.key else { return }
        selectedHelperID = peerID
        impactGenerator.impactOccurred()
        refreshPeerList()
    }

    @objc private func sendTapped() {
        guard let target = selectedHelperID, let link = links[target] else {
            waiterStatus.text = "近くに「迎えに行く」の人が見つかりません"
            return
        }
        let request = MeetRequest(kind: selectedKind, mode: selectedMarker)
        requestSent = true
        activePeerID = target
        impactGenerator.impactOccurred()

        UIView.animate(withDuration: 0.25) {
            self.setWaiterSelection(hidden: true)
            self.sendButton.isHidden = true
            self.cancelButton.isHidden = false
            self.waiterPanel.layoutIfNeeded()
        }
        if link.isDemo {
            waiterStatus.text = "\(target.displayName) に伝えました(デモ)"
        } else {
            sendMeetRequest(request, to: target)
            waiterStatus.text = "\(target.displayName) に「ここだよ」を伝えました\n伝えている間だけ、この相手に距離が届きます"
        }
        updateMeasurement(distance: link.distance, direction: link.direction, world: nil)
    }

    @objc private func cancelTapped() {
        requestSent = false
        activeRequest = nil
        if let target = activePeerID, links[target]?.isDemo != true,
           let data = try? JSONEncoder().encode(CancelMessage()) {
            mpc?.sendData(data: data, peers: [target], mode: .reliable)
        }
        if let target = activePeerID, let link = links[target], !link.isDemo { restartLink(link) }
        activePeerID = nil
        latestDistance = nil
        latestDirection = nil
        UIView.animate(withDuration: 0.25) {
            self.setWaiterSelection(hidden: false)
            self.sendButton.isHidden = false
            self.cancelButton.isHidden = true
            self.waiterPanel.layoutIfNeeded()
        }
        waiterStatus.text = "場所と目印を選んで、迎えに来てもらう相手に送ります"
        waiterDial.reset()
        refreshDials()
    }

    // MARK: - Small builders

    private func setWaiterSelection(hidden: Bool) {
        waiterSelection.isHidden = hidden
        waiterSelectionCollapse?.isActive = hidden
    }

    private func sectionLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = UIColor.white.withAlphaComponent(0.45)
        return label
    }

    private func chipRow(titles: [String], action: Selector, store: inout [UIButton]) -> UIView {
        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 8
        scroll.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
        ])
        scroll.heightAnchor.constraint(equalToConstant: 40).isActive = true

        for (index, title) in titles.enumerated() {
            let button = UIButton(type: .system)
            var conf = UIButton.Configuration.plain()
            conf.title = title
            conf.contentInsets = NSDirectionalEdgeInsets(top: 9, leading: 16, bottom: 9, trailing: 16)
            conf.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in
                var a = attrs
                a.font = UIFont.systemFont(ofSize: 14, weight: .semibold)
                return a
            }
            button.configuration = conf
            button.tag = index
            button.layer.cornerRadius = 20
            button.layer.borderWidth = 1
            button.addTarget(self, action: action, for: .touchUpInside)
            store.append(button)
            stack.addArrangedSubview(button)
        }
        return scroll
    }

    private func style(chipButton button: UIButton, selected: Bool) {
        button.backgroundColor = selected ? amber : .clear
        button.layer.borderColor = (selected ? amber : UIColor.white.withAlphaComponent(0.25)).cgColor
        button.configuration?.baseForegroundColor = selected ? .black : UIColor.white.withAlphaComponent(0.75)
    }

    private func style(chip: PaddedLabel, background: UIColor, text: UIColor) {
        chip.backgroundColor = background
        chip.textColor = text
        chip.font = .systemFont(ofSize: 13, weight: .semibold)
        chip.insets = UIEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        chip.layer.cornerRadius = 14
        chip.clipsToBounds = true
    }

    private func peerRow(name: String) -> UIButton {
        let button = UIButton(type: .system)
        var conf = UIButton.Configuration.plain()
        conf.title = name
        conf.subtitle = "測定中…"
        conf.titleAlignment = .leading
        conf.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14)
        conf.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in
            var a = attrs
            a.font = UIFont.systemFont(ofSize: 15, weight: .semibold)
            return a
        }
        conf.subtitleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in
            var a = attrs
            a.font = UIFont.systemFont(ofSize: 12)
            return a
        }
        button.configuration = conf
        button.contentHorizontalAlignment = .leading
        button.backgroundColor = cardColour
        return button
    }

    private func primaryConfig(title: String, image: String, background: UIColor, foreground: UIColor) -> UIButton.Configuration {
        var conf = UIButton.Configuration.filled()
        conf.title = title
        conf.image = UIImage(systemName: image)
        conf.imagePadding = 10
        conf.baseBackgroundColor = background
        conf.baseForegroundColor = foreground
        conf.cornerStyle = .capsule
        conf.contentInsets = NSDirectionalEdgeInsets(top: 18, leading: 24, bottom: 18, trailing: 24)
        conf.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in
            var a = attrs
            a.font = UIFont.systemFont(ofSize: 17, weight: .bold)
            return a
        }
        return conf
    }
}

// MARK: - NISessionDelegate

extension MeetViewController: NISessionDelegate {

    func session(_ session: NISession, didUpdate nearbyObjects: [NINearbyObject]) {
        guard let peerID = sessionOwners[ObjectIdentifier(session)], let link = links[peerID] else { return }
        guard let token = link.peerToken,
              let object = nearbyObjects.first(where: { $0.discoveryToken == token }) else { return }

        link.distance = object.distance
        link.direction = object.direction
        if #available(iOS 16.0, *), cameraAssistance, peerID == activePeerID {
            link.world = session.worldTransform(for: object)
        }

        if peerID == activePeerID {
            updateMeasurement(distance: link.distance, direction: link.direction, world: link.world)
        } else {
            refreshPeerList()
        }
    }

    @available(iOS 16.0, *)
    func session(_ session: NISession, didUpdateAlgorithmConvergence convergence: NIAlgorithmConvergence, for object: NINearbyObject?) {
        if phase == .guiding { updateGuidance() }
    }

    func session(_ session: NISession, didRemove nearbyObjects: [NINearbyObject], reason: NINearbyObject.RemovalReason) {
        guard let peerID = sessionOwners[ObjectIdentifier(session)], let link = links[peerID] else { return }
        guard let token = link.peerToken, nearbyObjects.contains(where: { $0.discoveryToken == token }) else { return }

        switch reason {
        case .peerEnded:
            link.peerToken = nil
            link.distance = nil
            session.invalidate()
            refreshPeerList()
            refreshDials()
        case .timeout:
            if let config = session.configuration { session.run(config) }
        default:
            break
        }
    }

    func sessionWasSuspended(_ session: NISession) {}

    func sessionSuspensionEnded(_ session: NISession) {
        if let config = session.configuration { session.run(config) }
    }

    func session(_ session: NISession, didInvalidateWith error: Error) {
        if case NIError.userDidNotAllow = error {
            let alert = UIAlertController(title: "許可が必要です",
                                          message: "近くの人との距離を測る許可(Nearby Interaction)が必要です。設定を開いて許可してください。",
                                          preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "キャンセル", style: .cancel))
            alert.addAction(UIAlertAction(title: "設定を開く", style: .default) { _ in
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            })
            present(alert, animated: true)
            return
        }
        if let peerID = sessionOwners[ObjectIdentifier(session)] {
            sessionOwners.removeValue(forKey: ObjectIdentifier(session))
            links.removeValue(forKey: peerID)
            if activePeerID == peerID { activePeerID = nil }
            if selectedHelperID == peerID { selectedHelperID = nil }
            refreshPeerList()
        }
    }
}

// MARK: - Helpers

final class PaddedLabel: UILabel {
    var insets: UIEdgeInsets = .zero
    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: insets))
    }
    override var intrinsicContentSize: CGSize {
        let s = super.intrinsicContentSize
        return CGSize(width: s.width + insets.left + insets.right,
                      height: s.height + insets.top + insets.bottom)
    }
}
