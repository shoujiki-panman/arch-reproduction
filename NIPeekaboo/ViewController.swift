/*
 Arch reproduction — built on Apple's NIPeekaboo sample (see LICENSE.txt).
 Reproduces the UI/UX of the "Arch" support app demo:
   1. Notification screen: help request, live distance, action accordions
   2. AR guidance: camera view + 3D blue arrow + dotted path + "あと◯m"
   3. Arrival: "到着しました / スマホをしまって声をかけましょう"
 UWB ranging via NearbyInteraction with ARKit camera assistance (iOS 16+).
 A demo mode (デモモード button) simulates a peer so the full flow can be
 shown on a single device.
*/

import UIKit
import ARKit
import SceneKit
import CoreLocation
import NearbyInteraction
import MultipeerConnectivity
import simd

// MARK: - Help message protocol (requester -> supporter over MPC)

struct HelpMessage: Codable {
    enum Kind: String, Codable, CaseIterable {
        case accompany   // 体調が悪いので付き添ってほしい
        case heat        // 熱中症かも・飲み物がほしい
        case lost        // 道に迷った・案内してほしい

        var text: String {
            switch self {
            case .accompany: return "体調が悪いので付き添ってほしい"
            case .heat: return "熱中症かも・飲み物を買ってきてほしい"
            case .lost: return "道に迷った・案内してほしい"
            }
        }
        var actionPoints: String {
            switch self {
            case .accompany:
                return "やること\n・安全な場所へ誘導して座らせる\n・症状と希望を本人に確認する\n・改善しない場合は #7119 に相談する"
            case .heat:
                return "やること\n・涼しい場所へ移動して体を冷やす\n・水分と塩分を取らせる(近くの自販機を確認)\n・意識がはっきりしない場合は 119 に通報する"
            case .lost:
                return "やること\n・行き先を本人に確認する\n・一緒に案内するか道順を伝える\n・不安が強い場合は近くの係員に引き継ぐ"
            }
        }
    }
    enum CommMode: String, Codable, CaseIterable {
        case voice, sign, writing
        var text: String {
            switch self {
            case .voice: return "声で伝えて"
            case .sign: return "手話で伝えて"
            case .writing: return "筆談で伝えて"
            }
        }
    }
    var type: String = "help"
    var kind: Kind
    var mode: CommMode
}

struct CancelMessage: Codable {
    var type: String = "cancel"
}

// Announced right after connecting, so each side knows which role the peer plays.
struct HelloMessage: Codable {
    var type: String = "hello"
    var role: String
}

final class ArchViewController: UIViewController {

    // MARK: - Role

    private enum Role { case supporter, requester }
    private var role: Role = .supporter

    // MARK: - Flow state

    private enum Phase {
        case searching        // no peer yet
        case ready            // peer connected, distance flowing
        case guiding          // AR screen visible
        case arrived
    }
    private var phase: Phase = .searching { didSet { applyPhase() } }

    // Active help request (supporter: received; requester: sent).
    private var activeHelp: HelpMessage?
    private var pendingHelpToSend: HelpMessage?

    private let arrivalThreshold: Float = 1.0
    private let nearThreshold: Float = 2.5

    // MARK: - Nearby Interaction state

    // One NI session per connected peer, so the requester can see every nearby
    // supporter's distance at the same time and choose one.
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
    private var selectedSupporterID: MCPeerID?
    private var supportsUWB = true
    private var cameraAssistance = false

    private var latestDistance: Float?
    private var latestDirection: simd_float3?
    private var latestWorldTransform: simd_float4x4?
    private var converged = false

    private let impactGenerator = UIImpactFeedbackGenerator(style: .medium)
    private var didArriveHapticFired = false

    // Find My-style proximity feedback: the closer you get, the faster and
    // stronger the pulse, and the colour shifts from blue to green.
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
        var color: UIColor {
            switch self {
            case .far: return UIColor(red: 0.20, green: 0.45, blue: 0.95, alpha: 1)
            case .mid: return UIColor(red: 0.25, green: 0.62, blue: 0.98, alpha: 1)
            case .near, .arrived: return UIColor(red: 0.20, green: 0.80, blue: 0.50, alpha: 1)
            }
        }
    }
    private var currentBand: ProximityBand?
    private var hapticTimer: Timer?
    private let proximityGenerator = UIImpactFeedbackGenerator(style: .medium)
    private let arrivalGenerator = UINotificationFeedbackGenerator()
    private var arrowMaterial: SCNMaterial?
    private var dotMaterials: [SCNMaterial] = []
    private var circleMaterial: SCNMaterial?

    // MARK: - Demo mode

    private var demoTimer: Timer?
    private var demoDistance: Float = 7.4
    private var isDemo = false

    // MARK: - AR

    private let sceneView = ARSCNView()
    private var arrowContainer = SCNNode()
    private var dotsContainer = SCNNode()
    private var circleNode = SCNNode()
    private var arRunning = false

    // MARK: - Palette

    private let bgColor = UIColor(red: 0.05, green: 0.05, blue: 0.07, alpha: 1.0)
    private let cardColor = UIColor(red: 0.11, green: 0.12, blue: 0.14, alpha: 1.0)
    private let accentBlue = UIColor(red: 0.20, green: 0.45, blue: 0.95, alpha: 1.0)
    private let navyCard = UIColor(red: 0.09, green: 0.14, blue: 0.28, alpha: 1.0)
    private let pinkCard = UIColor(red: 0.98, green: 0.88, blue: 0.90, alpha: 1.0)
    private let alertRed = UIColor(red: 0.86, green: 0.16, blue: 0.22, alpha: 1.0)

    // MARK: - Location + open data

    private let locationManager = CLLocationManager()
    private var lastLocation: CLLocation?
    private let resourcesLabel = UILabel()
    private var resourcesFetched = false

    // MARK: - Role select / requester screens

    private let roleScreen = UIView()
    private let requesterScreen = UIView()
    private var selectedKind: HelpMessage.Kind = .accompany
    private var selectedMode: HelpMessage.CommMode = .voice
    private var kindButtons: [UIButton] = []
    private var modeButtons: [UIButton] = []
    private let supporterListStack = UIStackView()
    private let supporterEmptyLabel = UILabel()
    private var supporterRows: [MCPeerID: UIButton] = [:]
    private var supporterOrder: [MCPeerID] = []
    private let requesterDemoButton = UIButton(type: .system)
    private let requesterStatusLabel = UILabel()
    private let requesterDistanceLabel = UILabel()
    private let sendHelpButton = UIButton(type: .system)
    private let cancelHelpButton = UIButton(type: .system)

    // Supporter views that change with the received help.
    private var helpTextLabels: [UILabel] = []
    private var modeChipLabels: [UILabel] = []
    private let requestLabel = UILabel()
    private var pointsBodyLabels: [UILabel] = []

    // Supporter views revealed only once a help request arrives (or demo starts).
    private var supporterActiveViews: [UIView] = []

    // MARK: - Notification screen views

    private let notificationScreen = UIView()
    private let bellRing = UIView()
    private let distanceLabel = UILabel()
    private let distanceCaption = UILabel()
    private let statusLabel = UILabel()
    private let startButton = UIButton(type: .system)
    private let demoButton = UIButton(type: .system)
    private let unsupportedNote = UILabel()

    // MARK: - AR screen views

    private let arScreen = UIView()
    private let arHintLabel = UILabel()
    private let arSubHintLabel = UILabel()
    private let arDistancePill = UILabel()
    private let arrivalOverlay = UIView()

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = bgColor

        if #available(iOS 16.0, *) {
            supportsUWB = NISession.deviceCapabilities.supportsPreciseDistanceMeasurement
            cameraAssistance = NISession.deviceCapabilities.supportsCameraAssistance
        } else {
            supportsUWB = NISession.isSupported
        }

        buildARScreen()
        buildNotificationScreen()
        buildRequesterScreen()
        buildRoleScreen()
        applyPhase()

        // Wait for a role choice before starting NI/MPC.
        roleScreen.isHidden = false
        view.bringSubviewToFront(roleScreen)
    }

    private func beginSession() {
        if supportsUWB {
            startup()
        } else {
            statusLabel.text = "この端末はUWB非対応です"
            requesterStatusLabel.text = "この端末はUWB非対応です"
            unsupportedNote.isHidden = false
        }
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    // MARK: - NI startup (mirrors the Apple sample, extended to multiple peers)

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

        // Say which side we are, then hand over this session's own token.
        if let hello = try? JSONEncoder().encode(HelloMessage(role: role == .supporter ? "supporter" : "requester")) {
            mpc?.sendData(data: hello, peers: [peer], mode: .reliable)
        }
        if let token = session.discoveryToken,
           let data = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true) {
            mpc?.sendData(data: data, peers: [peer], mode: .reliable)
        }
        refreshSupporterList()
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
            if role == .supporter, !isDemo { statusLabel.text = "相手との接続が切れました。再探索中…" }
        }
        if selectedSupporterID == peer { selectedSupporterID = nil }
        refreshSupporterList()
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

    private func dataReceivedHandler(data: Data, peer: MCPeerID) {
        guard let link = links[peer] else { return }

        // Envelope: an archived NIDiscoveryToken, or one of the JSON app messages.
        if let token = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NIDiscoveryToken.self, from: data) {
            link.peerToken = token
            runConfig(for: link, cameraAssist: activePeerID == peer && phase == .guiding)
            return
        }
        if let hello = try? JSONDecoder().decode(HelloMessage.self, from: data), hello.type == "hello" {
            link.peerRole = hello.role
            refreshSupporterList()
            return
        }
        if let help = try? JSONDecoder().decode(HelpMessage.self, from: data), help.type == "help" {
            guard role == .supporter, activePeerID == nil || activePeerID == peer else { return }
            activePeerID = peer
            activeHelp = help
            latestDistance = link.distance
            applyHelp(help)
            return
        }
        if let msg = try? JSONDecoder().decode(CancelMessage.self, from: data), msg.type == "cancel" {
            guard role == .supporter, activePeerID == peer else { return }
            activeHelp = nil
            activePeerID = nil
            arrivalOverlay.isHidden = true
            setSupporterActive(false)
            phase = .searching
            statusLabel.text = "求援は取り下げられました"
        }
    }

    private func sendHelp(_ help: HelpMessage, to peer: MCPeerID) {
        guard let data = try? JSONEncoder().encode(help) else { return }
        mpc?.sendData(data: data, peers: [peer], mode: .reliable)
        pendingHelpToSend = nil
        activeHelp = help
    }

    // Update every supporter-side surface that mirrors the request.
    private func applyHelp(_ help: HelpMessage) {
        let twoLine = help.kind.text.replacingOccurrences(of: "ので", with: "ので\n")
        for label in helpTextLabels {
            label.text = label.numberOfLines == 2 ? twoLine : help.kind.text
        }
        for chip in modeChipLabels { chip.text = help.mode.text }
        requestLabel.text = "近くに[\(help.kind.text)]を\n求めている求援者がいます"
        pointsBodyLabels.forEach { $0.text = help.kind.actionPoints }
        setSupporterActive(true)
        if latestDistance != nil { phase = .ready }
        impactGenerator.impactOccurred()
    }

    // MARK: - Measurement funnel (real NI and demo both land here)

    private func updateMeasurement(distance: Float?, direction: simd_float3?, world: simd_float4x4?) {
        latestDistance = distance
        latestDirection = direction
        latestWorldTransform = world

        if let d = distance {
            distanceLabel.text = formatMeters(d)
            if role == .requester && helpSent {
                requesterDistanceLabel.text = d < arrivalThreshold
                    ? "サポーターが到着しました\nスマホから顔を上げてください"
                    : "サポーターが向かっています  あと \(formatMeters(d))"
            }
            // The supporter stays in the waiting state until a request arrives.
            if phase == .searching, role == .requester || activeHelp != nil || isDemo {
                phase = .ready
            }
        }

        switch phase {
        case .guiding:
            updateGuidance()
        case .arrived:
            break
        default:
            break
        }

        if (phase == .guiding), let d = distance, d < arrivalThreshold {
            arrive()
        }
    }

    private func formatMeters(_ d: Float) -> String {
        d >= 2 ? String(format: "%.0f m", d.rounded()) : String(format: "%.1f m", d)
    }

    // MARK: - Phase handling

    private func applyPhase() {
        if role == .requester {
            notificationScreen.isHidden = true
            arScreen.isHidden = true
            requesterScreen.isHidden = false
            return
        }
        requesterScreen.isHidden = true
        switch phase {
        case .searching:
            notificationScreen.isHidden = false
            arScreen.isHidden = true
            startButton.isEnabled = false
            startButton.alpha = 0.45
            distanceLabel.text = "— m"
        case .ready:
            notificationScreen.isHidden = false
            arScreen.isHidden = true
            startButton.isEnabled = true
            startButton.alpha = 1.0
            statusLabel.text = nil
        case .guiding:
            notificationScreen.isHidden = true
            arScreen.isHidden = false
            arrivalOverlay.isHidden = true
            didArriveHapticFired = false
        case .arrived:
            arrivalOverlay.isHidden = false
            setARGuidesHidden(true)
            arDistancePill.isHidden = true
            if !didArriveHapticFired {
                impactGenerator.impactOccurred()
                didArriveHapticFired = true
            }
        }
    }

    @objc private func startGuidanceTapped() {
        startARIfNeeded()
        if let id = activePeerID, let link = links[id] { runConfig(for: link, cameraAssist: true) }
        phase = .guiding
        updateGuidance()
    }

    @objc private func closeARTapped() {
        stopProximityFeedback()
        phase = isDemo || latestDistance != nil ? .ready : .searching
        if isDemo { stopDemo() }
    }

    private func arrive() {
        phase = .arrived
        if isDemo { demoTimer?.invalidate() }
    }

    // Done supporting: back to the waiting state, ready for the next request.
    @objc private func finishSupportTapped() {
        stopProximityFeedback()
        if isDemo { stopDemo() }
        activeHelp = nil
        arrivalOverlay.isHidden = true
        setSupporterActive(false)
        phase = .searching
    }

    // MARK: - Demo mode

    @objc private func demoTapped() {
        if isDemo { stopDemo(); return }
        if role == .requester { startRequesterDemo(); return }
        isDemo = true
        demoDistance = 7.4
        setSupporterActive(true)
        demoButton.setTitle("デモ停止", for: .normal)
        statusLabel.text = "デモモード(シミュレーション)"
        demoTimer?.invalidate()
        demoTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.phase == .guiding || self.phase == .ready || self.phase == .searching {
                if self.phase == .guiding {
                    self.demoDistance = max(0.4, self.demoDistance - 0.11 + Float.random(in: -0.02...0.02))
                }
                let az: Float = 0.18 * sinf(Float(Date().timeIntervalSince1970) * 0.7)
                let dir = simd_float3(sinf(az), 0, -cosf(az))
                self.updateMeasurement(distance: self.demoDistance, direction: dir, world: nil)
            }
        }
    }

    // Requester demo: three simulated supporters at different distances, so the
    // list and the choice can be shown on a single device.
    private func startRequesterDemo() {
        isDemo = true
        requesterDemoButton.setTitle("デモ停止", for: .normal)
        requesterStatusLabel.text = "デモモード(シミュレーション)\n距離は実測ではありません"
        let demoPeers: [(String, Float)] = [("会場スタッフのiPhone", 7.4), ("となりの席のiPhone", 15.6), ("受付のiPhone", 24.1)]
        for (name, distance) in demoPeers {
            let peerID = MCPeerID(displayName: name)
            let link = PeerLink(peerID: peerID)
            link.isDemo = true
            link.peerRole = "supporter"
            link.distance = distance
            links[peerID] = link
        }
        refreshSupporterList()
        demoTimer?.invalidate()
        demoTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            for (peerID, link) in self.links where link.isDemo {
                if self.helpSent, peerID == self.activePeerID {
                    link.distance = max(0.4, (link.distance ?? 7.4) - 0.11)
                    let azimuth: Float = 0.18 * sinf(Float(Date().timeIntervalSince1970) * 0.7)
                    link.direction = simd_float3(sinf(azimuth), 0, -cosf(azimuth))
                    self.updateMeasurement(distance: link.distance, direction: link.direction, world: nil)
                } else {
                    link.distance = max(1.0, (link.distance ?? 10) + Float.random(in: -0.2...0.2))
                }
            }
            self.refreshSupporterList()
        }
    }

    private func stopDemo() {
        isDemo = false
        demoTimer?.invalidate()
        demoTimer = nil
        demoButton.setTitle("デモモード", for: .normal)
        requesterDemoButton.setTitle("デモモード", for: .normal)
        demoDistance = 7.4

        for (peerID, link) in links where link.isDemo {
            link.session?.invalidate()
            links.removeValue(forKey: peerID)
            if activePeerID == peerID { activePeerID = nil }
            if selectedSupporterID == peerID { selectedSupporterID = nil }
        }
        refreshSupporterList()

        if role == .requester { return }
        if activeHelp == nil { setSupporterActive(false) }
        if supportsUWB {
            statusLabel.text = activePeerID == nil ? "近くの求援者を待ち受けています…" : nil
            if activePeerID == nil { phase = .searching }
        } else {
            phase = .searching
            statusLabel.text = "この端末はUWB非対応です"
        }
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
            arHintLabel.text = "近くにいます"
            arSubHintLabel.text = "端末をゆっくり動かしてください"
            arDistancePill.isHidden = true
            setARGuidesHidden(true)
            return
        }

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
            // Direction is in camera coordinates; bring it to world space.
            let worldDir = camNode.simdConvertVector(simd_float3(dir.x, dir.y, dir.z), to: nil)
            var v = worldDir
            v.y = 0
            if simd_length(v) > 0.01 { horizontalDir = simd_normalize(v) }
        }

        if distance < nearThreshold {
            arHintLabel.text = nil
            arSubHintLabel.text = nil
            arDistancePill.isHidden = false
            arDistancePill.text = distance < 1.6 ? "すぐそこ" : "あと\(max(1, Int(distance.rounded())))m"
        } else {
            arDistancePill.isHidden = false
            arDistancePill.text = "あと\(Int(distance.rounded()))m"
            arHintLabel.text = nil
            arSubHintLabel.text = nil
        }

        guard let camNode = cam, let dir = horizontalDir else {
            // No usable direction yet: keep the calibration hint.
            arHintLabel.text = "近くにいます(約 \(formatMeters(distance)))"
            arSubHintLabel.text = "端末をゆっくり動かしてください"
            setARGuidesHidden(true)
            return
        }

        let camPos = camNode.simdWorldPosition
        let floorY = camPos.y - 1.25

        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0.18

        if distance < nearThreshold, let peerPos = peerWorldPos ?? optionalPeerPos(camPos: camPos, dir: dir, distance: distance) {
            // Close: draw the circle at the peer's feet.
            arrowContainer.isHidden = true
            dotsContainer.isHidden = true
            circleNode.isHidden = false
            circleNode.simdPosition = simd_float3(peerPos.x, floorY, peerPos.z)
        } else {
            // Far: arrow ahead of the camera pointing at the peer + dotted path.
            circleNode.isHidden = true
            arrowContainer.isHidden = false
            dotsContainer.isHidden = false

            let arrowPos = camPos + dir * 1.35
            arrowContainer.simdPosition = simd_float3(arrowPos.x, floorY + 0.15, arrowPos.z)
            let lookTarget = arrowContainer.simdPosition + dir
            arrowContainer.simdLook(at: lookTarget, up: simd_float3(0, 1, 0), localFront: simd_float3(0, 0, -1))

            // Dots from just past the arrow toward the peer.
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

    // MARK: - Proximity feedback

    private func updateProximityFeedback(distance: Float?) {
        guard phase == .guiding, let distance else { return }
        let band: ProximityBand
        if distance < arrivalThreshold { band = .arrived }
        else if distance < nearThreshold { band = .near }
        else if distance < 5.0 { band = .mid }
        else { band = .far }
        guard band != currentBand else { return }
        currentBand = band
        applyBandColour(band)

        hapticTimer?.invalidate()
        hapticTimer = nil
        guard band != .arrived else {
            arrivalGenerator.notificationOccurred(.success)
            return
        }
        proximityGenerator.prepare()
        proximityGenerator.impactOccurred(intensity: band.intensity)
        hapticTimer = Timer.scheduledTimer(withTimeInterval: band.interval, repeats: true) { [weak self] _ in
            guard let self, self.phase == .guiding else { return }
            self.proximityGenerator.impactOccurred(intensity: band.intensity)
        }
    }

    private func stopProximityFeedback() {
        hapticTimer?.invalidate()
        hapticTimer = nil
        currentBand = nil
    }

    private func applyBandColour(_ band: ProximityBand) {
        let colour = band.color
        arDistancePill.backgroundColor = colour.withAlphaComponent(0.85)
        arrowMaterial?.diffuse.contents = colour.withAlphaComponent(0.95)
        arrowMaterial?.emission.contents = darker(colour, 0.5)
        for material in dotMaterials {
            material.diffuse.contents = colour.withAlphaComponent(0.85)
            material.emission.contents = darker(colour, 0.5)
        }
        circleMaterial?.diffuse.contents = colour.withAlphaComponent(0.8)
        circleMaterial?.emission.contents = darker(colour, 0.5)
    }

    private func darker(_ color: UIColor, _ factor: CGFloat) -> UIColor {
        var h: CGFloat = 0, sat: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getHue(&h, saturation: &sat, brightness: &b, alpha: &a)
        return UIColor(hue: h, saturation: sat, brightness: b * factor, alpha: a)
    }

    private func optionalPeerPos(camPos: simd_float3, dir: simd_float3, distance: Float) -> simd_float3? {
        camPos + dir * distance
    }

    // MARK: - UI construction: notification screen

    private func buildNotificationScreen() {
        notificationScreen.backgroundColor = bgColor
        view.addSubview(notificationScreen)
        notificationScreen.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            notificationScreen.topAnchor.constraint(equalTo: view.topAnchor),
            notificationScreen.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            notificationScreen.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            notificationScreen.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        let safe = notificationScreen.safeAreaLayoutGuide

        // Back chevron (fixed, outside the scrolling area).
        let back = UIButton(type: .system)
        back.setImage(UIImage(systemName: "chevron.left"), for: .normal)
        back.tintColor = .white
        back.backgroundColor = cardColor
        back.layer.cornerRadius = 22
        back.addTarget(self, action: #selector(backToRoleSelect), for: .touchUpInside)
        notificationScreen.addSubview(back)
        back.translatesAutoresizingMaskIntoConstraints = false

        // Everything below the header scrolls.
        let scroll = UIScrollView()
        scroll.showsVerticalScrollIndicator = true
        scroll.alwaysBounceVertical = true
        notificationScreen.addSubview(scroll)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let content = UIView()
        scroll.addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false

        // "サポーター" chip.
        let roleChip = chip(text: "サポーター", textColor: .white, bg: accentBlue)
        content.addSubview(roleChip)

        // Help card.
        let helpCard = UIView()
        helpCard.backgroundColor = cardColor
        helpCard.layer.cornerRadius = 14
        content.addSubview(helpCard)
        helpCard.translatesAutoresizingMaskIntoConstraints = false

        let helpChip = chip(text: "ヘルプ", textColor: .white, bg: accentBlue.withAlphaComponent(0.85), small: true)
        let helpText = UILabel()
        helpText.text = "体調が悪いので\n付き添ってほしい"
        helpText.textColor = .white
        helpText.numberOfLines = 2
        helpText.font = .systemFont(ofSize: 17, weight: .semibold)
        helpTextLabels.append(helpText)
        let signChip = outlineChip(text: "手話で伝えて")
        modeChipLabels.append(signChip)
        for v in [helpChip, helpText, signChip] {
            helpCard.addSubview(v)
            v.translatesAutoresizingMaskIntoConstraints = false
        }

        // Bell.
        let bellCircle = UIView()
        bellCircle.backgroundColor = cardColor
        bellCircle.layer.cornerRadius = 41
        let bell = UIImageView(image: UIImage(systemName: "bell.fill"))
        bell.tintColor = alertRed
        bell.contentMode = .scaleAspectFit
        bellRing.layer.borderColor = accentBlue.withAlphaComponent(0.5).cgColor
        bellRing.layer.borderWidth = 1.5
        bellRing.layer.cornerRadius = 64
        for v in [bellRing, bellCircle, bell] {
            content.addSubview(v)
            v.translatesAutoresizingMaskIntoConstraints = false
        }

        // Texts.
        requestLabel.text = "近くに[体調が悪いので付き添って\nほしい]を求めている求援者がいます"
        requestLabel.textColor = .white
        requestLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        requestLabel.numberOfLines = 2
        requestLabel.textAlignment = .center

        distanceLabel.text = "— m"
        distanceLabel.textColor = .white
        distanceLabel.font = .systemFont(ofSize: 38, weight: .bold)
        distanceLabel.textAlignment = .center

        distanceCaption.text = "相手までの距離"
        distanceCaption.textColor = UIColor.white.withAlphaComponent(0.55)
        distanceCaption.font = .systemFont(ofSize: 12)
        distanceCaption.textAlignment = .center

        statusLabel.textColor = UIColor.white.withAlphaComponent(0.6)
        statusLabel.font = .systemFont(ofSize: 13)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 2

        for v in [requestLabel, distanceLabel, distanceCaption, statusLabel] {
            content.addSubview(v)
            v.translatesAutoresizingMaskIntoConstraints = false
        }

        // Start button.
        var conf = UIButton.Configuration.filled()
        conf.title = "ARで誘導を開始"
        conf.image = UIImage(systemName: "viewfinder")
        conf.imagePadding = 8
        conf.baseBackgroundColor = accentBlue
        conf.baseForegroundColor = .white
        conf.cornerStyle = .capsule
        conf.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 24, bottom: 14, trailing: 24)
        startButton.configuration = conf
        startButton.addTarget(self, action: #selector(startGuidanceTapped), for: .touchUpInside)
        content.addSubview(startButton)
        startButton.translatesAutoresizingMaskIntoConstraints = false

        // Accordions.
        let pointsCard = accordionCard(icon: "doc.text", title: "対応のポイント", bg: navyCard,
                                       tint: .white,
                                       body: HelpMessage.Kind.accompany.actionPoints)
        if let b = lastAccordionBody { pointsBodyLabels.append(b) }
        let contactCard = contactAccordion()
        for v in [pointsCard, contactCard] {
            content.addSubview(v)
            v.translatesAutoresizingMaskIntoConstraints = false
        }

        // Demo mode + unsupported note.
        demoButton.setTitle("デモモード", for: .normal)
        demoButton.setTitleColor(UIColor.white.withAlphaComponent(0.45), for: .normal)
        demoButton.titleLabel?.font = .systemFont(ofSize: 13)
        demoButton.addTarget(self, action: #selector(demoTapped), for: .touchUpInside)
        notificationScreen.addSubview(demoButton)
        demoButton.translatesAutoresizingMaskIntoConstraints = false

        unsupportedNote.text = "UWB非対応端末のため、実測はできません(デモモードのみ)"
        unsupportedNote.textColor = UIColor.white.withAlphaComponent(0.4)
        unsupportedNote.font = .systemFont(ofSize: 11)
        unsupportedNote.textAlignment = .center
        unsupportedNote.isHidden = true
        notificationScreen.addSubview(unsupportedNote)
        unsupportedNote.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            back.topAnchor.constraint(equalTo: safe.topAnchor, constant: 8),
            back.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 16),
            back.widthAnchor.constraint(equalToConstant: 44),
            back.heightAnchor.constraint(equalToConstant: 44),

            scroll.topAnchor.constraint(equalTo: back.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: notificationScreen.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: notificationScreen.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: demoButton.topAnchor, constant: -4),

            content.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            content.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            content.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),

            roleChip.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
            roleChip.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),

            helpCard.topAnchor.constraint(equalTo: roleChip.bottomAnchor, constant: 10),
            helpCard.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            helpCard.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),

            helpChip.topAnchor.constraint(equalTo: helpCard.topAnchor, constant: 12),
            helpChip.leadingAnchor.constraint(equalTo: helpCard.leadingAnchor, constant: 12),
            helpText.centerYAnchor.constraint(equalTo: helpChip.centerYAnchor),
            helpText.leadingAnchor.constraint(equalTo: helpChip.trailingAnchor, constant: 10),
            signChip.topAnchor.constraint(equalTo: helpText.bottomAnchor, constant: 10),
            signChip.leadingAnchor.constraint(equalTo: helpCard.leadingAnchor, constant: 12),
            signChip.bottomAnchor.constraint(equalTo: helpCard.bottomAnchor, constant: -12),

            bellRing.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            bellRing.topAnchor.constraint(equalTo: helpCard.bottomAnchor, constant: 14),
            bellRing.widthAnchor.constraint(equalToConstant: 128),
            bellRing.heightAnchor.constraint(equalToConstant: 128),
            bellCircle.centerXAnchor.constraint(equalTo: bellRing.centerXAnchor),
            bellCircle.centerYAnchor.constraint(equalTo: bellRing.centerYAnchor),
            bellCircle.widthAnchor.constraint(equalToConstant: 82),
            bellCircle.heightAnchor.constraint(equalToConstant: 82),
            bell.centerXAnchor.constraint(equalTo: bellCircle.centerXAnchor),
            bell.centerYAnchor.constraint(equalTo: bellCircle.centerYAnchor),
            bell.widthAnchor.constraint(equalToConstant: 36),
            bell.heightAnchor.constraint(equalToConstant: 36),

            requestLabel.topAnchor.constraint(equalTo: bellRing.bottomAnchor, constant: 12),
            requestLabel.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            requestLabel.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: 16),

            distanceLabel.topAnchor.constraint(equalTo: requestLabel.bottomAnchor, constant: 10),
            distanceLabel.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            distanceCaption.topAnchor.constraint(equalTo: distanceLabel.bottomAnchor, constant: 2),
            distanceCaption.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            statusLabel.topAnchor.constraint(equalTo: distanceCaption.bottomAnchor, constant: 6),
            statusLabel.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: 16),

            startButton.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 14),
            startButton.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            startButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),

            pointsCard.topAnchor.constraint(equalTo: startButton.bottomAnchor, constant: 16),
            pointsCard.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            pointsCard.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),

            contactCard.topAnchor.constraint(equalTo: pointsCard.bottomAnchor, constant: 10),
            contactCard.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            contactCard.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            contactCard.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),

            demoButton.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -4),
            demoButton.centerXAnchor.constraint(equalTo: notificationScreen.centerXAnchor),
            unsupportedNote.bottomAnchor.constraint(equalTo: demoButton.topAnchor, constant: -2),
            unsupportedNote.centerXAnchor.constraint(equalTo: notificationScreen.centerXAnchor),
        ])

        // Pulse the ring.
        UIView.animate(withDuration: 1.4, delay: 0, options: [.repeat, .autoreverse, .curveEaseInOut]) {
            self.bellRing.transform = CGAffineTransform(scaleX: 1.06, y: 1.06)
            self.bellRing.alpha = 0.5
        }

        // Until a help request arrives, the supporter screen only waits.
        supporterActiveViews = [helpCard, requestLabel, distanceLabel, distanceCaption, startButton, pointsCard, contactCard]
        setSupporterActive(false)
    }

    // Waiting state: bell + status only. Active state: the full Arch notification.
    private func setSupporterActive(_ active: Bool) {
        supporterActiveViews.forEach { $0.isHidden = !active }
        statusLabel.text = active ? nil : "近くの求援者を待ち受けています…"
    }

    // MARK: - UI construction: AR screen

    private func buildARScreen() {
        arScreen.backgroundColor = .black
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

        // Top bar.
        let closeButton = UIButton(type: .system)
        var cconf = UIButton.Configuration.filled()
        cconf.title = "閉じる"
        cconf.baseBackgroundColor = UIColor.black.withAlphaComponent(0.55)
        cconf.baseForegroundColor = .white
        cconf.cornerStyle = .capsule
        cconf.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16)
        closeButton.configuration = cconf
        closeButton.addTarget(self, action: #selector(closeARTapped), for: .touchUpInside)

        let title = UILabel()
        title.text = "AR誘導"
        title.textColor = .white
        title.font = .systemFont(ofSize: 16, weight: .semibold)

        // Help banner.
        let banner = UIView()
        banner.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        banner.layer.cornerRadius = 10
        let bChip = chip(text: "ヘルプ", textColor: .white, bg: accentBlue.withAlphaComponent(0.85), small: true)
        let bText = UILabel()
        bText.text = "体調が悪いので付き添ってほしい"
        bText.textColor = .white
        bText.font = .systemFont(ofSize: 13, weight: .semibold)
        helpTextLabels.append(bText)
        let bSign = UILabel()
        bSign.text = "手話で伝えて"
        bSign.textColor = accentBlue.withAlphaComponent(0.9)
        bSign.font = .systemFont(ofSize: 11)
        modeChipLabels.append(bSign)

        // Center hints.
        arHintLabel.textColor = .white
        arHintLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        arHintLabel.textAlignment = .center
        arHintLabel.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        arHintLabel.layer.cornerRadius = 8
        arHintLabel.clipsToBounds = true
        arSubHintLabel.textColor = UIColor.white.withAlphaComponent(0.7)
        arSubHintLabel.font = .systemFont(ofSize: 12)
        arSubHintLabel.textAlignment = .center

        // Distance pill.
        arDistancePill.textColor = .white
        arDistancePill.font = .systemFont(ofSize: 26, weight: .bold)
        arDistancePill.textAlignment = .center
        arDistancePill.backgroundColor = UIColor.black.withAlphaComponent(0.72)
        arDistancePill.layer.cornerRadius = 12
        arDistancePill.clipsToBounds = true
        arDistancePill.isHidden = true

        // Bottom accordions (collapsed look).
        let pointsBar = accordionCard(icon: "doc.text", title: "対応のポイント", bg: navyCard, tint: .white,
                                      body: HelpMessage.Kind.accompany.actionPoints, expanded: false)
        if let b = lastAccordionBody { pointsBodyLabels.append(b) }
        let contactBar = contactAccordion(expanded: false)

        for v in [closeButton, title, banner, arHintLabel, arSubHintLabel, arDistancePill, pointsBar, contactBar] {
            arScreen.addSubview(v)
            v.translatesAutoresizingMaskIntoConstraints = false
        }
        for v in [bChip, bText, bSign] {
            banner.addSubview(v)
            v.translatesAutoresizingMaskIntoConstraints = false
        }

        buildArrivalOverlay()

        NSLayoutConstraint.activate([
            closeButton.topAnchor.constraint(equalTo: safe.topAnchor, constant: 8),
            closeButton.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 16),
            title.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            title.centerXAnchor.constraint(equalTo: arScreen.centerXAnchor),

            banner.topAnchor.constraint(equalTo: closeButton.bottomAnchor, constant: 10),
            banner.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 12),
            banner.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -12),
            bChip.topAnchor.constraint(equalTo: banner.topAnchor, constant: 8),
            bChip.leadingAnchor.constraint(equalTo: banner.leadingAnchor, constant: 10),
            bText.centerYAnchor.constraint(equalTo: bChip.centerYAnchor),
            bText.leadingAnchor.constraint(equalTo: bChip.trailingAnchor, constant: 8),
            bSign.topAnchor.constraint(equalTo: bChip.bottomAnchor, constant: 4),
            bSign.leadingAnchor.constraint(equalTo: banner.leadingAnchor, constant: 10),
            bSign.bottomAnchor.constraint(equalTo: banner.bottomAnchor, constant: -8),

            sceneView.topAnchor.constraint(equalTo: arScreen.topAnchor),
            sceneView.bottomAnchor.constraint(equalTo: arScreen.bottomAnchor),
            sceneView.leadingAnchor.constraint(equalTo: arScreen.leadingAnchor),
            sceneView.trailingAnchor.constraint(equalTo: arScreen.trailingAnchor),

            arHintLabel.centerXAnchor.constraint(equalTo: arScreen.centerXAnchor),
            arHintLabel.centerYAnchor.constraint(equalTo: arScreen.centerYAnchor, constant: 40),
            arHintLabel.heightAnchor.constraint(equalToConstant: 36),
            arHintLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 200),
            arSubHintLabel.topAnchor.constraint(equalTo: arHintLabel.bottomAnchor, constant: 6),
            arSubHintLabel.centerXAnchor.constraint(equalTo: arScreen.centerXAnchor),

            arDistancePill.centerXAnchor.constraint(equalTo: arScreen.centerXAnchor),
            arDistancePill.bottomAnchor.constraint(equalTo: pointsBar.topAnchor, constant: -14),
            arDistancePill.widthAnchor.constraint(greaterThanOrEqualToConstant: 150),
            arDistancePill.heightAnchor.constraint(equalToConstant: 48),

            pointsBar.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 12),
            pointsBar.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -12),
            pointsBar.bottomAnchor.constraint(equalTo: contactBar.topAnchor, constant: -8),
            contactBar.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 12),
            contactBar.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -12),
            contactBar.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -8),
        ])

        // The scene view must sit behind every overlay; controls stay tappable
        // even while the arrival overlay is up.
        arScreen.sendSubviewToBack(sceneView)
        arScreen.bringSubviewToFront(closeButton)
        arScreen.bringSubviewToFront(title)
        arScreen.bringSubviewToFront(pointsBar)
        arScreen.bringSubviewToFront(contactBar)
    }

    private func buildArrivalOverlay() {
        arrivalOverlay.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        arrivalOverlay.isHidden = true
        arScreen.addSubview(arrivalOverlay)
        arrivalOverlay.translatesAutoresizingMaskIntoConstraints = false

        let checkCircle = UIView()
        checkCircle.backgroundColor = accentBlue
        checkCircle.layer.cornerRadius = 40
        let check = UIImageView(image: UIImage(systemName: "checkmark"))
        check.tintColor = .white
        check.contentMode = .scaleAspectFit

        let arrived = UILabel()
        arrived.text = "到着しました"
        arrived.textColor = .white
        arrived.font = .systemFont(ofSize: 28, weight: .bold)
        arrived.textAlignment = .center

        let putAway = UILabel()
        putAway.text = "スマホをしまって声をかけましょう"
        putAway.textColor = accentBlue.withAlphaComponent(0.95)
        putAway.font = .systemFont(ofSize: 15, weight: .semibold)
        putAway.textAlignment = .center

        let tip = UILabel()
        tip.text = "安全な場所で休めるようにし、症状と希望\nを本人に確認する"
        tip.textColor = .white
        tip.font = .systemFont(ofSize: 13)
        tip.numberOfLines = 2
        tip.textAlignment = .center
        tip.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        tip.layer.cornerRadius = 10
        tip.clipsToBounds = true

        let doneButton = UIButton(type: .system)
        var dconf = UIButton.Configuration.filled()
        dconf.title = "対応を終える"
        dconf.baseBackgroundColor = accentBlue
        dconf.baseForegroundColor = .white
        dconf.cornerStyle = .capsule
        dconf.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 32, bottom: 12, trailing: 32)
        doneButton.configuration = dconf
        doneButton.addTarget(self, action: #selector(finishSupportTapped), for: .touchUpInside)

        for v in [checkCircle, check, arrived, putAway, tip, doneButton] {
            arrivalOverlay.addSubview(v)
            v.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            doneButton.topAnchor.constraint(equalTo: tip.bottomAnchor, constant: 28),
            doneButton.centerXAnchor.constraint(equalTo: arrivalOverlay.centerXAnchor),
        ])

        NSLayoutConstraint.activate([
            arrivalOverlay.topAnchor.constraint(equalTo: arScreen.topAnchor),
            arrivalOverlay.bottomAnchor.constraint(equalTo: arScreen.bottomAnchor),
            arrivalOverlay.leadingAnchor.constraint(equalTo: arScreen.leadingAnchor),
            arrivalOverlay.trailingAnchor.constraint(equalTo: arScreen.trailingAnchor),

            checkCircle.centerXAnchor.constraint(equalTo: arrivalOverlay.centerXAnchor),
            checkCircle.centerYAnchor.constraint(equalTo: arrivalOverlay.centerYAnchor, constant: -80),
            checkCircle.widthAnchor.constraint(equalToConstant: 80),
            checkCircle.heightAnchor.constraint(equalToConstant: 80),
            check.centerXAnchor.constraint(equalTo: checkCircle.centerXAnchor),
            check.centerYAnchor.constraint(equalTo: checkCircle.centerYAnchor),
            check.widthAnchor.constraint(equalToConstant: 36),
            check.heightAnchor.constraint(equalToConstant: 36),

            arrived.topAnchor.constraint(equalTo: checkCircle.bottomAnchor, constant: 16),
            arrived.centerXAnchor.constraint(equalTo: arrivalOverlay.centerXAnchor),
            putAway.topAnchor.constraint(equalTo: arrived.bottomAnchor, constant: 8),
            putAway.centerXAnchor.constraint(equalTo: arrivalOverlay.centerXAnchor),
            tip.topAnchor.constraint(equalTo: putAway.bottomAnchor, constant: 18),
            tip.centerXAnchor.constraint(equalTo: arrivalOverlay.centerXAnchor),
            tip.widthAnchor.constraint(greaterThanOrEqualToConstant: 280),
            tip.heightAnchor.constraint(equalToConstant: 58),
        ])
    }

    // MARK: - AR nodes

    private func buildARNodes() {
        let root = sceneView.scene.rootNode

        // Blue 3D arrow: extruded 2D arrow path, laid flat.
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
        mat.diffuse.contents = UIColor(red: 0.35, green: 0.55, blue: 0.95, alpha: 0.95)
        mat.emission.contents = UIColor(red: 0.10, green: 0.25, blue: 0.65, alpha: 1)
        mat.lightingModel = .physicallyBased
        shape.materials = [mat]
        arrowMaterial = mat
        let arrowNode = SCNNode(geometry: shape)
        // Path +Y (tip) maps to -Z (container front) after this rotation.
        arrowNode.eulerAngles = SCNVector3(-Float.pi / 2 + 0.18, 0, 0)
        arrowNode.position = SCNVector3(0, 0, 0.3)
        arrowContainer = SCNNode()
        arrowContainer.addChildNode(arrowNode)
        arrowContainer.isHidden = true
        root.addChildNode(arrowContainer)

        // Dotted path.
        dotsContainer = SCNNode()
        for _ in 0..<8 {
            let dotGeom = SCNCylinder(radius: 0.05, height: 0.012)
            let dmat = SCNMaterial()
            dmat.diffuse.contents = UIColor(red: 0.55, green: 0.70, blue: 1.0, alpha: 0.85)
            dmat.emission.contents = UIColor(red: 0.2, green: 0.35, blue: 0.8, alpha: 1)
            dotGeom.materials = [dmat]
            dotMaterials.append(dmat)
            let dot = SCNNode(geometry: dotGeom)
            dot.isHidden = true
            dotsContainer.addChildNode(dot)
        }
        dotsContainer.isHidden = true
        root.addChildNode(dotsContainer)

        // Peer circle.
        let tube = SCNTube(innerRadius: 0.52, outerRadius: 0.60, height: 0.012)
        let cmat = SCNMaterial()
        cmat.diffuse.contents = UIColor(red: 0.35, green: 0.55, blue: 0.95, alpha: 0.8)
        cmat.emission.contents = UIColor(red: 0.15, green: 0.3, blue: 0.7, alpha: 1)
        tube.materials = [cmat]
        circleMaterial = cmat
        circleNode = SCNNode(geometry: tube)
        circleNode.isHidden = true
        root.addChildNode(circleNode)
    }

    // MARK: - Role select screen

    private func buildRoleScreen() {
        roleScreen.backgroundColor = bgColor
        roleScreen.isHidden = true
        view.addSubview(roleScreen)
        roleScreen.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            roleScreen.topAnchor.constraint(equalTo: view.topAnchor),
            roleScreen.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            roleScreen.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            roleScreen.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        let title = UILabel()
        title.text = "Arch再現"
        title.textColor = .white
        title.font = .systemFont(ofSize: 24, weight: .bold)
        title.textAlignment = .center

        let subtitle = UILabel()
        subtitle.text = "困っている人と、近くにいる助けられる人を\n結びつける支援アプリ(再現)"
        subtitle.textColor = UIColor.white.withAlphaComponent(0.6)
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.numberOfLines = 2
        subtitle.textAlignment = .center

        let requesterButton = roleButton(title: "助けを求める", subtitle: "求援者として発報します", bg: alertRed)
        requesterButton.addTarget(self, action: #selector(chooseRequester), for: .touchUpInside)
        let supporterButton = roleButton(title: "サポーターになる", subtitle: "近くの求援を待ち受けます", bg: accentBlue)
        supporterButton.addTarget(self, action: #selector(chooseSupporter), for: .touchUpInside)

        for v in [title, subtitle, requesterButton, supporterButton] {
            roleScreen.addSubview(v)
            v.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            title.centerXAnchor.constraint(equalTo: roleScreen.centerXAnchor),
            title.topAnchor.constraint(equalTo: roleScreen.safeAreaLayoutGuide.topAnchor, constant: 80),
            subtitle.centerXAnchor.constraint(equalTo: roleScreen.centerXAnchor),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 10),

            requesterButton.centerXAnchor.constraint(equalTo: roleScreen.centerXAnchor),
            requesterButton.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 60),
            requesterButton.leadingAnchor.constraint(equalTo: roleScreen.leadingAnchor, constant: 32),
            requesterButton.trailingAnchor.constraint(equalTo: roleScreen.trailingAnchor, constant: -32),
            requesterButton.heightAnchor.constraint(equalToConstant: 88),

            supporterButton.centerXAnchor.constraint(equalTo: roleScreen.centerXAnchor),
            supporterButton.topAnchor.constraint(equalTo: requesterButton.bottomAnchor, constant: 16),
            supporterButton.leadingAnchor.constraint(equalTo: requesterButton.leadingAnchor),
            supporterButton.trailingAnchor.constraint(equalTo: requesterButton.trailingAnchor),
            supporterButton.heightAnchor.constraint(equalToConstant: 88),
        ])
    }

    private func roleButton(title: String, subtitle: String, bg: UIColor) -> UIButton {
        let button = UIButton(type: .system)
        var conf = UIButton.Configuration.filled()
        conf.title = title
        conf.subtitle = subtitle
        conf.baseBackgroundColor = bg
        conf.baseForegroundColor = .white
        conf.cornerStyle = .large
        conf.titleAlignment = .center
        conf.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in
            var a = attrs
            a.font = UIFont.systemFont(ofSize: 20, weight: .bold)
            return a
        }
        button.configuration = conf
        return button
    }

    @objc private func backToRoleSelect() {
        stopProximityFeedback()
        // Tear down the whole session so the next role starts clean.
        if isDemo { stopDemo() }
        demoTimer?.invalidate()
        helpSent = false
        pendingHelpToSend = nil
        activeHelp = nil
        sendHelpButton.isHidden = false
        cancelHelpButton.isHidden = true
        requesterDistanceLabel.text = nil
        requesterStatusLabel.text = "内容を選んで、助けを求めてください"
        setSelectionEnabled(true)

        for link in links.values { link.session?.invalidate() }
        links.removeAll()
        sessionOwners.removeAll()
        supporterRows.removeAll()
        supporterOrder.removeAll()
        activePeerID = nil
        selectedSupporterID = nil
        mpc?.invalidate()
        mpc = nil
        latestDistance = nil
        latestDirection = nil
        latestWorldTransform = nil

        phase = .searching
        setSupporterActive(false)
        notificationScreen.isHidden = true
        requesterScreen.isHidden = true
        arScreen.isHidden = true
        roleScreen.isHidden = false
        view.bringSubviewToFront(roleScreen)
    }

    @objc private func chooseRequester() {
        role = .requester
        roleScreen.isHidden = true
        applyPhase()
        beginSession()
    }

    @objc private func chooseSupporter() {
        role = .supporter
        roleScreen.isHidden = true
        applyPhase()
        beginSession()
    }

    // MARK: - Requester screen (not shown in the original video — same design language)

    private var helpSent = false
    private var selectionContainer = UIStackView()

    private func buildRequesterScreen() {
        requesterScreen.backgroundColor = bgColor
        requesterScreen.isHidden = true
        view.addSubview(requesterScreen)
        requesterScreen.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            requesterScreen.topAnchor.constraint(equalTo: view.topAnchor),
            requesterScreen.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            requesterScreen.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            requesterScreen.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        let safe = requesterScreen.safeAreaLayoutGuide

        // Fixed header.
        let back = UIButton(type: .system)
        back.setImage(UIImage(systemName: "chevron.left"), for: .normal)
        back.tintColor = .white
        back.backgroundColor = cardColor
        back.layer.cornerRadius = 22
        back.addTarget(self, action: #selector(backToRoleSelect), for: .touchUpInside)
        requesterScreen.addSubview(back)
        back.translatesAutoresizingMaskIntoConstraints = false

        // Fixed footer.
        var xconf = UIButton.Configuration.plain()
        xconf.title = "もう大丈夫(取り下げる)"
        xconf.baseForegroundColor = UIColor.white.withAlphaComponent(0.7)
        cancelHelpButton.configuration = xconf
        cancelHelpButton.isHidden = true
        cancelHelpButton.addTarget(self, action: #selector(cancelHelpTapped), for: .touchUpInside)
        requesterScreen.addSubview(cancelHelpButton)
        cancelHelpButton.translatesAutoresizingMaskIntoConstraints = false

        requesterDemoButton.setTitle("デモモード", for: .normal)
        requesterDemoButton.setTitleColor(UIColor.white.withAlphaComponent(0.45), for: .normal)
        requesterDemoButton.titleLabel?.font = .systemFont(ofSize: 13)
        requesterDemoButton.addTarget(self, action: #selector(demoTapped), for: .touchUpInside)
        requesterScreen.addSubview(requesterDemoButton)
        requesterDemoButton.translatesAutoresizingMaskIntoConstraints = false

        // Scrolling body.
        let scroll = UIScrollView()
        scroll.alwaysBounceVertical = true
        requesterScreen.addSubview(scroll)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let content = UIView()
        scroll.addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false

        let roleChip = chip(text: "求援者", textColor: .white, bg: alertRed)
        content.addSubview(roleChip)

        // Section 1: what is wrong.
        let kindTitle = sectionLabel("どうしましたか?")
        kindButtons = HelpMessage.Kind.allCases.enumerated().map { index, kind in
            let button = selectableCard(title: kind.text)
            button.tag = index
            button.addTarget(self, action: #selector(kindTapped(_:)), for: .touchUpInside)
            return button
        }
        let kindStack = UIStackView(arrangedSubviews: kindButtons)
        kindStack.axis = .vertical
        kindStack.spacing = 10
        kindStack.distribution = .fillEqually

        // Section 2: how the requester wants to be spoken to.
        let modeTitle = sectionLabel("伝え方の希望")
        modeButtons = HelpMessage.CommMode.allCases.enumerated().map { index, mode in
            let button = selectableChip(title: mode.text)
            button.tag = index
            button.addTarget(self, action: #selector(modeTapped(_:)), for: .touchUpInside)
            return button
        }
        let modeStack = UIStackView(arrangedSubviews: modeButtons)
        modeStack.axis = .horizontal
        modeStack.spacing = 8
        modeStack.distribution = .fillEqually

        // Section 3: which nearby supporter to ask.
        let supporterTitle = sectionLabel("近くのサポーター")
        supporterListStack.axis = .vertical
        supporterListStack.spacing = 8
        supporterEmptyLabel.text = "近くのサポーターを探しています…"
        supporterEmptyLabel.textColor = UIColor.white.withAlphaComponent(0.45)
        supporterEmptyLabel.font = .systemFont(ofSize: 13)
        supporterEmptyLabel.numberOfLines = 0

        selectionContainer = UIStackView(arrangedSubviews: [kindTitle, kindStack, modeTitle, modeStack,
                                                            supporterTitle, supporterListStack, supporterEmptyLabel])
        selectionContainer.axis = .vertical
        selectionContainer.spacing = 10
        selectionContainer.setCustomSpacing(18, after: kindStack)
        selectionContainer.setCustomSpacing(18, after: modeStack)
        content.addSubview(selectionContainer)
        selectionContainer.translatesAutoresizingMaskIntoConstraints = false

        // Send button.
        var hconf = UIButton.Configuration.filled()
        hconf.title = "助けを求める"
        hconf.image = UIImage(systemName: "bell.fill")
        hconf.imagePadding = 10
        hconf.baseBackgroundColor = alertRed
        hconf.baseForegroundColor = .white
        hconf.cornerStyle = .capsule
        hconf.contentInsets = NSDirectionalEdgeInsets(top: 20, leading: 24, bottom: 20, trailing: 24)
        sendHelpButton.configuration = hconf
        sendHelpButton.addTarget(self, action: #selector(sendHelpTapped), for: .touchUpInside)

        requesterStatusLabel.text = "内容を選んで、助けを求めてください"
        requesterStatusLabel.textColor = UIColor.white.withAlphaComponent(0.6)
        requesterStatusLabel.font = .systemFont(ofSize: 13)
        requesterStatusLabel.textAlignment = .center
        requesterStatusLabel.numberOfLines = 2

        requesterDistanceLabel.text = nil
        requesterDistanceLabel.textColor = .white
        requesterDistanceLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        requesterDistanceLabel.textAlignment = .center
        requesterDistanceLabel.numberOfLines = 2

        for v in [sendHelpButton, requesterStatusLabel, requesterDistanceLabel] {
            content.addSubview(v)
            v.translatesAutoresizingMaskIntoConstraints = false
        }

        NSLayoutConstraint.activate([
            back.topAnchor.constraint(equalTo: safe.topAnchor, constant: 8),
            back.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 16),
            back.widthAnchor.constraint(equalToConstant: 44),
            back.heightAnchor.constraint(equalToConstant: 44),

            requesterDemoButton.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -4),
            requesterDemoButton.centerXAnchor.constraint(equalTo: requesterScreen.centerXAnchor),
            cancelHelpButton.bottomAnchor.constraint(equalTo: requesterDemoButton.topAnchor, constant: -2),
            cancelHelpButton.centerXAnchor.constraint(equalTo: requesterScreen.centerXAnchor),

            scroll.topAnchor.constraint(equalTo: back.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: requesterScreen.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: requesterScreen.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: cancelHelpButton.topAnchor, constant: -8),

            content.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            content.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            content.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),

            roleChip.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
            roleChip.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),

            selectionContainer.topAnchor.constraint(equalTo: roleChip.bottomAnchor, constant: 16),
            selectionContainer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            selectionContainer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),

            sendHelpButton.topAnchor.constraint(equalTo: selectionContainer.bottomAnchor, constant: 26),
            sendHelpButton.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 32),
            sendHelpButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -32),

            requesterStatusLabel.topAnchor.constraint(equalTo: sendHelpButton.bottomAnchor, constant: 14),
            requesterStatusLabel.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            requesterStatusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: 16),

            requesterDistanceLabel.topAnchor.constraint(equalTo: requesterStatusLabel.bottomAnchor, constant: 14),
            requesterDistanceLabel.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            requesterDistanceLabel.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: 16),
            requesterDistanceLabel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])

        refreshSelectionStyles()
        refreshSupporterList()
    }

    private func sectionLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.textColor = UIColor.white.withAlphaComponent(0.55)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        return label
    }

    private func selectableCard(title: String) -> UIButton {
        let button = UIButton(type: .system)
        var conf = UIButton.Configuration.plain()
        conf.title = title
        conf.baseForegroundColor = .white
        conf.titleAlignment = .leading
        conf.contentInsets = NSDirectionalEdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16)
        conf.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in
            var a = attrs
            a.font = UIFont.systemFont(ofSize: 16, weight: .semibold)
            return a
        }
        button.configuration = conf
        button.contentHorizontalAlignment = .leading
        button.titleLabel?.numberOfLines = 2
        button.backgroundColor = cardColor
        button.layer.cornerRadius = 14
        button.layer.borderWidth = 2
        button.layer.borderColor = UIColor.clear.cgColor
        return button
    }

    private func selectableChip(title: String) -> UIButton {
        let button = UIButton(type: .system)
        var conf = UIButton.Configuration.plain()
        conf.title = title
        conf.baseForegroundColor = .white
        conf.contentInsets = NSDirectionalEdgeInsets(top: 9, leading: 8, bottom: 9, trailing: 8)
        conf.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in
            var a = attrs
            a.font = UIFont.systemFont(ofSize: 13)
            return a
        }
        button.configuration = conf
        button.layer.cornerRadius = 16
        button.layer.borderWidth = 1
        return button
    }

    @objc private func kindTapped(_ sender: UIButton) {
        let kinds = HelpMessage.Kind.allCases
        guard sender.tag < kinds.count else { return }
        selectedKind = kinds[sender.tag]
        impactGenerator.impactOccurred()
        refreshSelectionStyles()
    }

    @objc private func modeTapped(_ sender: UIButton) {
        let modes = HelpMessage.CommMode.allCases
        guard sender.tag < modes.count else { return }
        selectedMode = modes[sender.tag]
        refreshSelectionStyles()
    }

    // Rebuild only when the set of supporters changes; otherwise just refresh
    // the distances, so tapping a row doesn't fight with live NI updates.
    private func refreshSupporterList() {
        guard role == .requester else { return }

        let supporters = links.values
            .filter { $0.peerRole == "supporter" || $0.isDemo }
            .sorted { ($0.distance ?? .greatestFiniteMagnitude, $0.peerID.displayName)
                    < ($1.distance ?? .greatestFiniteMagnitude, $1.peerID.displayName) }
        let ids = supporters.map { $0.peerID }

        if ids != supporterOrder {
            supporterOrder = ids
            supporterListStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
            supporterRows.removeAll()
            for link in supporters {
                let row = selectableCard(title: link.peerID.displayName)
                row.addTarget(self, action: #selector(supporterTapped(_:)), for: .touchUpInside)
                supporterRows[link.peerID] = row
                supporterListStack.addArrangedSubview(row)
            }
        }

        if selectedSupporterID == nil || !ids.contains(where: { $0 == selectedSupporterID }) {
            selectedSupporterID = ids.first
        }

        for link in supporters {
            guard let row = supporterRows[link.peerID] else { continue }
            row.configuration?.title = link.peerID.displayName
            row.configuration?.subtitle = link.distance.map { "距離 \(formatMeters($0))" } ?? "距離を測定中…"
            let selected = link.peerID == selectedSupporterID
            row.layer.borderColor = (selected ? accentBlue : UIColor.clear).cgColor
            row.backgroundColor = selected ? accentBlue.withAlphaComponent(0.18) : cardColor
        }

        supporterListStack.isHidden = supporters.isEmpty
        supporterEmptyLabel.isHidden = !supporters.isEmpty
        if !helpSent {
            sendHelpButton.isEnabled = !supporters.isEmpty
            sendHelpButton.alpha = supporters.isEmpty ? 0.45 : 1.0
        }
    }

    @objc private func supporterTapped(_ sender: UIButton) {
        guard let peerID = supporterRows.first(where: { $0.value === sender })?.key else { return }
        selectedSupporterID = peerID
        impactGenerator.impactOccurred()
        refreshSupporterList()
    }

    private func refreshSelectionStyles() {
        let kinds = HelpMessage.Kind.allCases
        for (index, button) in kindButtons.enumerated() {
            let selected = index < kinds.count && kinds[index] == selectedKind
            button.layer.borderColor = (selected ? accentBlue : UIColor.clear).cgColor
            button.backgroundColor = selected ? accentBlue.withAlphaComponent(0.18) : cardColor
        }
        let modes = HelpMessage.CommMode.allCases
        for (index, button) in modeButtons.enumerated() {
            let selected = index < modes.count && modes[index] == selectedMode
            button.backgroundColor = selected ? accentBlue : .clear
            button.layer.borderColor = (selected ? accentBlue : UIColor.white.withAlphaComponent(0.35)).cgColor
            button.configuration?.baseForegroundColor = selected ? .white : UIColor.white.withAlphaComponent(0.75)
        }
    }

    // Selection is locked while a request is out, so the supporter's view can't drift.
    private func setSelectionEnabled(_ enabled: Bool) {
        selectionContainer.isUserInteractionEnabled = enabled
        selectionContainer.alpha = enabled ? 1.0 : 0.5
    }

    @objc private func sendHelpTapped() {
        guard let target = selectedSupporterID, let link = links[target] else {
            requesterStatusLabel.text = "近くにサポーターが見つかりません"
            return
        }
        let help = HelpMessage(kind: selectedKind, mode: selectedMode)
        helpSent = true
        activePeerID = target
        sendHelpButton.isHidden = true
        cancelHelpButton.isHidden = false
        setSelectionEnabled(false)
        impactGenerator.impactOccurred()
        if link.isDemo {
            requesterStatusLabel.text = "\(target.displayName) に伝えました(デモ)"
        } else {
            sendHelp(help, to: target)
            requesterStatusLabel.text = "\(target.displayName) に伝えました"
        }
        updateMeasurement(distance: link.distance, direction: link.direction, world: nil)
    }

    @objc private func cancelHelpTapped() {
        helpSent = false
        pendingHelpToSend = nil
        activeHelp = nil
        if let target = activePeerID, links[target]?.isDemo != true,
           let data = try? JSONEncoder().encode(CancelMessage()) {
            mpc?.sendData(data: data, peers: [target], mode: .reliable)
        }
        activePeerID = nil
        sendHelpButton.isHidden = false
        cancelHelpButton.isHidden = true
        setSelectionEnabled(true)
        requesterDistanceLabel.text = nil
        requesterStatusLabel.text = "内容を選んで、助けを求めてください"
    }

    // MARK: - Small view factories

    private var lastAccordionBody: UILabel?

    private func chip(text: String, textColor: UIColor, bg: UIColor, small: Bool = false) -> UILabel {
        let label = PaddedLabel()
        label.text = text
        label.textColor = textColor
        label.backgroundColor = bg
        label.font = .systemFont(ofSize: small ? 11 : 13, weight: .semibold)
        label.layer.cornerRadius = small ? 9 : 12
        label.clipsToBounds = true
        label.insets = UIEdgeInsets(top: small ? 3 : 5, left: small ? 8 : 12, bottom: small ? 3 : 5, right: small ? 8 : 12)
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    private func outlineChip(text: String) -> UILabel {
        let label = PaddedLabel()
        label.text = text
        label.textColor = UIColor.white.withAlphaComponent(0.85)
        label.font = .systemFont(ofSize: 12)
        label.layer.cornerRadius = 12
        label.layer.borderWidth = 1
        label.layer.borderColor = UIColor.white.withAlphaComponent(0.35).cgColor
        label.clipsToBounds = true
        label.insets = UIEdgeInsets(top: 5, left: 12, bottom: 5, right: 12)
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    private func accordionCard(icon: String, title: String, bg: UIColor, tint: UIColor, body: String?, expanded: Bool = true) -> UIView {
        var bodyView: UIView?
        lastAccordionBody = nil
        if let body {
            let bodyLabel = UILabel()
            lastAccordionBody = bodyLabel
            bodyLabel.text = body
            bodyLabel.textColor = tint.withAlphaComponent(0.85)
            bodyLabel.font = .systemFont(ofSize: 12)
            bodyLabel.numberOfLines = 0
            bodyView = bodyLabel
        }
        return AccordionView(icon: icon, title: title, bg: bg, tint: tint, bodyView: bodyView, expanded: expanded)
    }

    private func contactAccordion(expanded: Bool = true) -> UIView {
        let tint = UIColor(red: 0.75, green: 0.15, blue: 0.25, alpha: 1)

        let row = UIView()
        row.backgroundColor = .white
        row.layer.cornerRadius = 10
        let num = UILabel()
        num.text = "#7119 救急相談センター"
        num.textColor = .black
        num.font = .systemFont(ofSize: 14, weight: .semibold)
        let org = UILabel()
        org.text = "総務省消防庁 救急安心センター事業"
        org.textColor = UIColor.black.withAlphaComponent(0.5)
        org.font = .systemFont(ofSize: 11)
        let call = UIButton(type: .system)
        call.setImage(UIImage(systemName: "phone.fill"), for: .normal)
        call.tintColor = .white
        call.backgroundColor = alertRed
        call.layer.cornerRadius = 20
        // Confirm before dialing — a mis-tap during a demo must not place a real call.
        call.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            let alert = UIAlertController(
                title: "#7119 に発信しますか?",
                message: "救急相談センター(総務省消防庁 救急安心センター事業)に電話をかけます。",
                preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "キャンセル", style: .cancel))
            alert.addAction(UIAlertAction(title: "発信する", style: .destructive) { _ in
                if let url = URL(string: "tel://%237119") { UIApplication.shared.open(url) }
            })
            self.present(alert, animated: true)
        }, for: .touchUpInside)

        for v in [num, org, call] {
            row.addSubview(v)
            v.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 60),
            num.topAnchor.constraint(equalTo: row.topAnchor, constant: 12),
            num.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 12),
            org.topAnchor.constraint(equalTo: num.bottomAnchor, constant: 2),
            org.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 12),
            call.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            call.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -10),
            call.widthAnchor.constraint(equalToConstant: 40),
            call.heightAnchor.constraint(equalToConstant: 40),
        ])
        return AccordionView(icon: "phone.fill", title: "引継ぎ連絡先", bg: pinkCard, tint: tint, bodyView: row, expanded: expanded)
    }
}

// MARK: - Tappable accordion card

private final class AccordionView: UIView, UIGestureRecognizerDelegate {
    private let chevron = UIImageView(image: UIImage(systemName: "chevron.down"))
    private let stack = UIStackView()
    private(set) var bodyView: UIView?

    init(icon: String, title: String, bg: UIColor, tint: UIColor, bodyView: UIView?, expanded: Bool) {
        super.init(frame: .zero)
        backgroundColor = bg
        layer.cornerRadius = 12
        clipsToBounds = true

        stack.axis = .vertical
        stack.spacing = 10
        stack.isLayoutMarginsRelativeArrangement = true
        stack.layoutMargins = UIEdgeInsets(top: 13, left: 14, bottom: 13, right: 14)
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        let iconView = UIImageView(image: UIImage(systemName: icon))
        iconView.tintColor = tint
        iconView.contentMode = .scaleAspectFit
        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.textColor = tint
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        chevron.tintColor = tint.withAlphaComponent(0.7)
        chevron.contentMode = .scaleAspectFit
        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let header = UIStackView(arrangedSubviews: [iconView, titleLabel, spacer, chevron])
        header.axis = .horizontal
        header.alignment = .center
        header.spacing = 10
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),
            chevron.widthAnchor.constraint(equalToConstant: 14),
            chevron.heightAnchor.constraint(equalToConstant: 14),
        ])
        stack.addArrangedSubview(header)

        if let bodyView {
            self.bodyView = bodyView
            stack.addArrangedSubview(bodyView)
            bodyView.isHidden = !expanded
            chevron.transform = expanded ? CGAffineTransform(rotationAngle: .pi) : .identity
        }

        let tap = UITapGestureRecognizer(target: self, action: #selector(toggle))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        addGestureRecognizer(tap)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func toggle() {
        guard let bodyView else { return }
        UIView.animate(withDuration: 0.25) {
            bodyView.isHidden.toggle()
            self.chevron.transform = bodyView.isHidden ? .identity : CGAffineTransform(rotationAngle: .pi)
            self.superview?.layoutIfNeeded()
        }
    }

    // Don't let the toggle swallow taps on inner buttons (e.g. the call button).
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        var v: UIView? = touch.view
        while let cur = v {
            if cur is UIControl { return false }
            v = cur.superview
        }
        return true
    }
}

// MARK: - NISessionDelegate

extension ArchViewController: NISessionDelegate {

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
            refreshSupporterList()
        }
    }

    @available(iOS 16.0, *)
    func session(_ session: NISession, didUpdateAlgorithmConvergence convergence: NIAlgorithmConvergence, for object: NINearbyObject?) {
        switch convergence.status {
        case .converged: converged = true
        case .notConverged: converged = false
        @unknown default: break
        }
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
            if peerID == activePeerID, !isDemo { statusLabel.text = "相手との接続が切れました。再探索中…" }
            refreshSupporterList()
        case .timeout:
            if let config = session.configuration { session.run(config) }
            if peerID == activePeerID, !isDemo { statusLabel.text = "相手を見失いました…" }
        default:
            break
        }
    }

    func sessionWasSuspended(_ session: NISession) {
        if !isDemo, sessionOwners[ObjectIdentifier(session)] == activePeerID { statusLabel.text = "一時停止中" }
    }

    func sessionSuspensionEnded(_ session: NISession) {
        if let config = session.configuration { session.run(config) }
    }

    func session(_ session: NISession, didInvalidateWith error: Error) {
        if case NIError.userDidNotAllow = error {
            statusLabel.text = "「正確な位置情報の共有」の許可が必要です。設定から変更できます。"
            let alert = UIAlertController(title: "許可が必要です",
                                          message: "近くの人との距離測定(Nearby Interaction)の許可が必要です。設定を開いて許可してください。",
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
        // Drop the broken link; MultipeerConnectivity will reconnect and rebuild it.
        if let peerID = sessionOwners[ObjectIdentifier(session)] {
            sessionOwners.removeValue(forKey: ObjectIdentifier(session))
            links.removeValue(forKey: peerID)
            if activePeerID == peerID { activePeerID = nil }
            if selectedSupporterID == peerID { selectedSupporterID = nil }
            refreshSupporterList()
        }
    }
}

// MARK: - Helpers

private final class PaddedLabel: UILabel {
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
