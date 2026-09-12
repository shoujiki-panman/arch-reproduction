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
#if DEBUG
import CoreMotion
#endif

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
    /// Kept so each new bearing re-targets the running spring instead of queuing
    /// behind it: readings arrive up to 60 times a second.
    private var arrowAnimator: UIViewPropertyAnimator?
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

        valueLabel.font = Type.reading
        valueLabel.textColor = .white
        valueLabel.textAlignment = .center

        captionLabel.font = Type.caption
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
        valueLabel.attributedText = Type.tracked(value, font: Type.reading)
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
            Motion.animate(response: 0.2, interrupting: arrowAnimator) { self.arrow.alpha = 0.22 }
            return
        }
        let angle = atan2(direction.x, -direction.z)
        // Rotation gets a touch of overshoot (0.8) the way Apple's own dials do,
        // and each new reading re-targets the running spring rather than queuing
        // behind it — at 60 readings a second, a queue would lag visibly.
        arrowAnimator = Motion.animate(damping: 0.8, response: 0.4, interrupting: arrowAnimator) {
            self.arrow.alpha = 1
            self.arrow.transform = CGAffineTransform(rotationAngle: CGFloat(angle))
        }
    }

    func reset() {
        arrowAnimator?.stopAnimation(true)
        arrowAnimator = nil
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
    /// How far the pair has to drift back apart before we leave `.arrived`.
    /// Provisional until the field test gives us the real jitter band.
    private let arrivalHysteresis: Float = 0.5

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
        /// Guards the auto-recovery in didInvalidateWith against a loop when the
        /// replacement session fails the same way. Reset on the next measurement.
        var invalidateRetries = 0
        init(peerID: MCPeerID) { self.peerID = peerID }
    }

    private var mpc: MPCSession?
    private var links: [MCPeerID: PeerLink] = [:]
    /// Sessions we (or the system) have invalidated. NISession exposes no
    /// isValid, and a dead session silently ignores run().
    private var deadSessions = Set<ObjectIdentifier>()
    private var sessionOwners: [ObjectIdentifier: MCPeerID] = [:]
    private var activePeerID: MCPeerID?
    private var selectedHelperID: MCPeerID?
    private var supportsUWB = true
    private var cameraAssistance = false
    private var supportsDirection = true

    // Measurement HUD state (values are cheap to keep; the HUD itself is DEBUG-only).
    private var convergenceText = "-"
    private var convergenceReasons = "-"
    /// What NI is actually waiting for, in words. It asks for these in turn, so
    /// showing one at a time turns 30 seconds of waving into a set of steps.
    private var sweepHint: String?
    private var lastNIError = "-"
    private var callbackCounter = 0
    private var callbacksPerSecond = 0
    private var activeCameraAssist = false
    /// Set once NI has told us this device cannot do camera assistance with our
    /// ARSession, so we stop asking and say so on screen instead.
    private var cameraAssistFailed = false
    /// Whether we hand NI our own ARSession (so the screen can show the camera)
    /// or let it create one itself. `-previewNIOwnAR` flips this to compare.
    private var provideOwnARSession = true
    private var anonNames: [MCPeerID: String] = [:]
    #if DEBUG
    private let hud = MeasureHUD()
    private var hudTimer: Timer?
    private let altimeter = CMAltimeter()
    private var relativeAltitude: Double?
    #endif

    private var latestDistance: Float?
    private var latestDirection: simd_float3?
    private var latestWorldTransform: simd_float4x4?

    private let impactGenerator = UIImpactFeedbackGenerator(style: .medium)
    /// The panel toggles between "choose and send" and "sent, cancel". Tapping
    /// send then cancel quickly must reverse from where the panel actually is.
    private var waiterPanelAnimator: UIViewPropertyAnimator?

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

    // DEBUG-only automation flags for the two-simulator reconnect check.
    private var previewAutoSend = false
    private var previewAutoFinish = false
    private var previewAutoGuide = false
    private var previewResend = false

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
    /// One step above the background. Dark interfaces need surfaces, not lines.
    private let surfaceColour = UIColor(red: 0.10, green: 0.10, blue: 0.12, alpha: 1)
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
    /// The choices sit on a raised surface instead of floating on the ground:
    /// on a flat black screen a column of small labels reads as a settings form.
    private let waiterCard = UIView()
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
    private let finderHeadline = UILabel()
    /// The measuring HUD is a DEBUG overlay pinned to the safe area, so the
    /// panels have to keep out from under it or the bottom line is unreadable.
    private static var hudInset: CGFloat {
        #if DEBUG
        return 34
        #else
        return 0
        #endif
    }
    /// A passing message (disconnected, they cancelled). Outranks the standby
    /// copy until something replaces it, so the two do not fight over one label.
    private var finderNotice: String?
    private let finderTip = UILabel()

    private let arScreen = UIView()
    /// Camera is the screen; the read-out is a thin layer on top of it. A dial in
    /// the middle made the camera a backdrop, which is backwards for a screen
    /// whose whole job is "which way".
    private let arScrim = GradientView(colors: [UIColor.black.withAlphaComponent(0.72),
                                                UIColor.black.withAlphaComponent(0.35),
                                                .clear],
                                       locations: [0, 0.55, 1])
    private let arReadout = UIStackView()
    private let arDistanceCaption = UILabel()
    private let arDistanceValue = UILabel()
    private let arPeerName = UILabel()
    private let arHint = PaddedLabel()
    private let arMarkerChip = PaddedLabel()
    /// Held so it can stand down while the arrival overlay owns the screen: its
    /// material is meant for camera video, and over an opaque colour it leaves
    /// white text on a bright ground.
    private let arCloseButton = UIButton(type: .system)
    private let arrivalOverlay = UIView()
    private let arrivalMarker = UILabel()

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = bgColour

        #if DEBUG
        // Read before anything builds an MCPeerID: the name is baked into the
        // session at startup() and cannot be changed without rebuilding it.
        if let arg = CommandLine.arguments.first(where: { $0.hasPrefix("-previewName=") }) {
            UserDefaults.standard.set(String(arg.dropFirst("-previewName=".count)), forKey: Self.displayNameKey)
        }
        #endif

        if #available(iOS 16.0, *) {
            supportsUWB = NISession.deviceCapabilities.supportsPreciseDistanceMeasurement
            cameraAssistance = NISession.deviceCapabilities.supportsCameraAssistance
            supportsDirection = NISession.deviceCapabilities.supportsDirectionMeasurement
        } else {
            supportsUWB = NISession.isSupported
        }

        impactGenerator.prepare()
        arrivalGenerator.prepare()

        buildARScreen()
        buildHome()
        #if DEBUG
        setupMeasureHUD()
        #endif
        followTextSize(from: view)
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
        if args.contains("-previewLog") {
            // What the accessibility settings actually report to us, so a claim
            // about reduced motion can be checked rather than assumed.
            print("A11Y reduceMotion=\(UIAccessibility.isReduceMotionEnabled) "
                  + "reduceTransparency=\(UIAccessibility.isReduceTransparencyEnabled) "
                  + "darkerColors=\(UIAccessibility.isDarkerSystemColorsEnabled) "
                  + "contentSize=\(traitCollection.preferredContentSizeCategory.rawValue)")
            // Two-simulator reconnect check: a line every 2s with the link state.
            Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                guard let self else { return }
                let rows = self.links.values.map { link -> String in
                    let dead = link.session.map { self.deadSessions.contains(ObjectIdentifier($0)) } ?? true
                    let d = link.distance.map { String(format: "%.2f", $0) } ?? "nil"
                    return "\(link.peerID.displayName)[role=\(link.peerRole ?? "?") token=\(link.peerToken != nil) dead=\(dead) dist=\(d)]"
                }
                print("RECON role=\(self.role) phase=\(self.phase) active=\(self.activePeerID?.displayName ?? "-") sent=\(self.requestSent) links=\(rows.joined(separator: " "))")
            }
        }
        if args.contains("-previewAutoSend") {
            // Waiter: send as soon as the first helper shows up.
            previewAutoSend = true
        }
        if args.contains("-previewAutoFinish") {
            // Finder: end the meet-up 8s after a request arrives (exercises restartLink).
            previewAutoFinish = true
        }
        if args.contains("-previewNIOwnAR") {
            // Do not hand NI our ARSession; let it make its own. Tests whether
            // -5883 is our AR configuration or camera assistance itself.
            provideOwnARSession = false
        }
        if args.contains("-previewAutoGuide") {
            // Finder: open the AR screen 2s after a request arrives, so the
            // two-simulator run reaches .guiding / .arrived.
            previewAutoGuide = true
        }
        if args.contains("-previewDrift") {
            // Finder: once we have arrived, feed one out-of-range distance so the
            // .arrived -> .guiding recovery is checkable without two UWB phones
            // (the simulator's own mock distance is pinned at 0.04 m).
            var fired = false
            Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                guard let self, !fired, self.phase == .arrived else { return }
                fired = true
                let out = self.arrivalThreshold + self.arrivalHysteresis + 0.1
                print("RECON drift: feeding \(out)m")
                self.updateMeasurement(distance: out, direction: nil, world: nil)
                print("RECON drift: phase=\(self.phase)")
            }
        }
        if args.contains("-previewResend") {
            // Waiter: send the same request a second time 14s later, which is
            // what used to close the finder's AR screen.
            previewResend = true
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

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        askForDisplayNameIfNeeded()
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    // MARK: - The name the other phone sees

    private static let displayNameKey = "kokodayo.displayName"


    static var myDisplayName: String {
        UserDefaults.standard.string(forKey: Self.displayNameKey) ?? "iPhone"
    }

    private var hasDisplayName: Bool {
        UserDefaults.standard.string(forKey: Self.displayNameKey)?.isEmpty == false
    }

    /// Asked once, on the first run. Two of the same iPhone both advertise as
    /// "iPhone", which makes the waiting side's list unusable, and there is no
    /// way to read the user's own device name without a special entitlement.
    private func askForDisplayNameIfNeeded() {
        guard !hasDisplayName else { return }
        #if DEBUG
        // An unattended run must not stop on a modal.
        if CommandLine.arguments.contains(where: { $0.hasPrefix("-preview") }) {
            UserDefaults.standard.set(UIDevice.current.name, forKey: Self.displayNameKey)
            restartMPCForNewName()
            return
        }
        #endif
        let alert = UIAlertController(title: "相手に見せる名前",
                                      message: "相手の一覧にこの名前で出ます。呼び名でも、ニックネームでも構いません。",
                                      preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = "たとえば たぬま"
            field.autocorrectionType = .no
            field.returnKeyType = .done
        }
        alert.addAction(UIAlertAction(title: "あとで", style: .cancel) { [weak self] _ in
            UserDefaults.standard.set("iPhone", forKey: Self.displayNameKey)
            self?.restartMPCForNewName()
        })
        alert.addAction(UIAlertAction(title: "決定", style: .default) { [weak self] _ in
            let typed = alert.textFields?.first?.text ?? ""
            let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
            UserDefaults.standard.set(trimmed.isEmpty ? "iPhone" : trimmed, forKey: Self.displayNameKey)
            self?.restartMPCForNewName()
        })
        present(alert, animated: true)
    }

    /// MCPeerID is fixed when the session is built, so a new name needs a new one.
    private func restartMPCForNewName() {
        guard supportsUWB else { return }
        resetSession()
        startup()
        refreshPeerList()
    }

    // MARK: - Nearby Interaction (extended from the Apple sample to several peers)

    private func startup() {
        startupMPC()
    }

    private func startupMPC() {
        if mpc == nil {
            #if targetEnvironment(simulator)
            mpc = MPCSession(service: "nisample",
                             identity: "com.example.apple-samplecode.simulator.peekaboo-nearbyinteraction",
                             maxPeers: 3, displayName: Self.myDisplayName)
            #else
            mpc = MPCSession(service: "nisample",
                             identity: "com.example.apple-samplecode.peekaboo-nearbyinteraction",
                             maxPeers: 3, displayName: Self.myDisplayName)
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
        if let session = links[peer]?.session { killSession(session) }
        links.removeValue(forKey: peer)
        if activePeerID == peer {
            activePeerID = nil
            latestDistance = nil
            latestDirection = nil
            latestWorldTransform = nil
            if role == .supporter, !isDemo { finderNotice = "相手との接続が切れました。探し直しています…" }
            // The peer is gone, so the AR screen has nothing left to point at.
            // Fall back to the home screen, where the disconnect line is visible.
            if role == .supporter {
                activeRequest = nil
                finderChips.isHidden = true
                finderTip.isHidden = true
            }
            if phase == .guiding || phase == .arrived { phase = .searching }
        }
        if selectedHelperID == peer { selectedHelperID = nil }
        refreshPeerList()
        refreshDials()
    }

    /// Returns a live session for the link, creating one (and sending our fresh
    /// token to the peer) if the current one has been invalidated.
    @discardableResult
    private func ensureLiveSession(for link: PeerLink) -> NISession {
        if let session = link.session, !deadSessions.contains(ObjectIdentifier(session)) {
            return session
        }
        let session = NISession()
        session.delegate = self
        link.session = session
        sessionOwners[ObjectIdentifier(session)] = link.peerID
        if let token = session.discoveryToken,
           let data = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true) {
            mpc?.sendData(data: data, peers: [link.peerID], mode: .reliable)
        }
        return session
    }

    private func killSession(_ session: NISession) {
        deadSessions.insert(ObjectIdentifier(session))
        sessionOwners.removeValue(forKey: ObjectIdentifier(session))
        session.invalidate()
    }

    private func runConfig(for link: PeerLink, cameraAssist: Bool = false) {
        guard link.peerToken != nil else { return }
        let wantsCamera = cameraAssist && cameraAssistance && !cameraAssistFailed
        // `setARSession` only takes hold on a session that has not run yet: Apple
        // invalidates with NIErrorCodeInvalidARConfiguration (-5883) when the
        // ARSession is handed to a session that is already ranging. So switching
        // into camera assistance means starting a fresh NISession, which also
        // re-sends our token so the peer follows us over.
        if wantsCamera, let old = link.session, !deadSessions.contains(ObjectIdentifier(old)) {
            killSession(old)
            link.session = nil
        }
        let session = ensureLiveSession(for: link)
        guard let token = link.peerToken else { return }
        let config = NINearbyPeerConfiguration(peerToken: token)
        if link.peerID == activePeerID { activeCameraAssist = wantsCamera }
        if #available(iOS 16.0, *), wantsCamera {
            config.isCameraAssistanceEnabled = true
            if provideOwnARSession {
                startARIfNeeded()
                session.setARSession(sceneView.session)
            }
            // Otherwise NI creates and runs its own ARSession. No camera picture
            // for us, but worldTransform(for:) still answers.
        }
        session.run(config)
    }

    /// Ends ranging with a peer and starts a fresh session, so "終わったら共有も終わる"
    /// is real rather than a label.
    private func restartLink(_ link: PeerLink) {
        if let old = link.session { killSession(old) }
        link.distance = nil
        link.direction = nil
        link.world = nil
        // The peer's token stays valid as long as *their* session is alive, so
        // keep it and resume straight away with our new session. The peer will
        // receive our fresh token and re-run on their side.
        ensureLiveSession(for: link)
        runConfig(for: link)
    }

    private func dataReceivedHandler(data: Data, peer: MCPeerID) {
        #if DEBUG
        print("RECON recv from=\(peer.displayName) bytes=\(data.count) known=\(links[peer] != nil) head=\(String(data: data.prefix(60), encoding: .utf8) ?? "<bin>")")
        #endif
        guard let link = links[peer] else { return }

        if let token = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NIDiscoveryToken.self, from: data) {
            link.peerToken = token
            runConfig(for: link, cameraAssist: activePeerID == peer && phase == .guiding)
            return
        }
        if let hello = try? JSONDecoder().decode(HelloMessage.self, from: data), hello.type == "hello" {
            link.peerRole = hello.role
            refreshPeerList()
            // refreshPeerList is the waiting side's list and returns early for the
            // finder, whose standby copy names this peer. Redraw it too.
            refreshDials()
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
            finderNotice = "相手が合流をやめました"
            refreshDials()
        }
    }

    private func sendMeetRequest(_ request: MeetRequest, to peer: MCPeerID) {
        guard let data = try? JSONEncoder().encode(request) else { return }
        #if DEBUG
        print("RECON send meet to=\(peer.displayName) bytes=\(data.count) mpc=\(mpc != nil)")
        #endif
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
        finderNotice = nil
        // A re-send from the same waiter must not yank the finder out of the AR
        // screen, so only lift the home screen out of `.searching`.
        if latestDistance != nil, phase == .searching { phase = .ready }
        impactGenerator.impactOccurred()
        refreshDials()
        #if DEBUG
        if previewAutoGuide {
            previewAutoGuide = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                print("RECON finder: startGuidance()")
                self?.startGuidance()
            }
        }
        if previewAutoFinish {
            previewAutoFinish = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                print("RECON finder: finishMeet()")
                self?.finishMeet()
            }
        }
        #endif
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

        if phase == .arrived, let d = distance, d > arrivalThreshold + arrivalHysteresis {
            phase = .guiding
        }
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
        refreshDemoButton()
        let colour = latestDistance.map { band(for: $0).colour } ?? UIColor.white.withAlphaComponent(0.35)
        let idleColour = UIColor.white.withAlphaComponent(0.35)

        if role == .requester {
            // Always on screen. Hiding it until the request went out left the
            // screen with no subject and a screenful of empty black.
            waiterDial.isHidden = false
            if requestSent {
                let value = latestDistance.map { $0 < arrivalThreshold ? "合流" : formatMeters($0) } ?? "—"
                let caption: String
                if let d = latestDistance, d < arrivalThreshold {
                    caption = "顔を上げてください"
                } else if latestDirection == nil {
                    caption = supportsDirection ? "方向を測定中\n端末をゆっくり動かして" : "この端末は方向を出せません\n距離だけで案内します"
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
                caption = "相手が送るまで待ちます"
            } else if let d = latestDistance, d < arrivalThreshold {
                caption = "顔を上げてください"
            } else if latestDirection == nil {
                caption = supportsDirection ? "方向を測定中\n端末をゆっくり動かして" : "この端末は方向を出せません\nカメラで探すと方向が出ることがあります"
            } else {
                caption = "この方向にいます"
            }
            finderDial.set(distance: waiting ? nil : latestDistance,
                           direction: waiting ? nil : latestDirection,
                           colour: waiting ? idleColour : colour,
                           value: value, caption: caption)
            // A button that is permanently greyed out reads as broken. It only
            // exists once there is something to point the camera at.
            let ready = activeRequest != nil && latestDistance != nil
            cameraButton.isHidden = !ready
            cameraButton.isEnabled = ready
            cameraButton.alpha = 1

            // Standby is a state of its own, not the absence of one. Until the
            // waiting side sends, this side has nothing to do and must say so.
            finderHeadline.isHidden = !waiting || isDemo || !supportsUWB
            if waiting, !isDemo, supportsUWB {
                let waiter = links.values.first { $0.peerRole == "requester" }
                if let waiter {
                    finderHeadline.text = "待っています"
                    finderStatus.text = finderNotice
                        ?? "\(waiter.peerID.displayName)が「ここだよ」を送ると、ここに距離が出ます"
                } else {
                    finderHeadline.text = "相手を探しています"
                    finderStatus.text = finderNotice ?? guidanceWhenNoPartner()
                }
            } else if !isDemo, supportsUWB {
                finderStatus.text = finderNotice
            }
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
        // One action at a time: the arrival screen has its own way out.
        arCloseButton.isHidden = phase == .arrived
        if phase != .guiding { stopProximityFeedback() }
        refreshDemoButton()
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
        for link in links.values { if let session = link.session { killSession(session) } }
        links.removeAll()
        sessionOwners.removeAll()
        deadSessions.removeAll()
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
        finderNotice = nil
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
        finderNotice = nil
        finderStatus.text = nil
        phase = .searching
        refreshDials()
    }

    // MARK: - Demo

    /// Demo is only allowed while nothing real is going on: no active peer,
    /// no request out, still searching. Otherwise a tap would feed simulated
    /// distances into the same funnel as real UWB measurements.
    private var demoAllowed: Bool {
        isDemo || (phase == .searching && activePeerID == nil && !requestSent)
    }

    private func refreshDemoButton() {
        demoButton.isEnabled = demoAllowed
        demoButton.alpha = demoAllowed ? 1.0 : 0.3
    }

    @objc private func demoTapped() {
        if isDemo { stopDemo(); return }
        guard demoAllowed else { return }
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
            if let session = link.session { killSession(session) }
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
        // The set NearbyInteraction documents as compatible. Left implicit these
        // default the right way today, but a default that moves would come back
        // as -5883 with nothing on screen to explain it.
        let config = ARWorldTrackingConfiguration()
        config.worldAlignment = .gravity
        config.isCollaborationEnabled = false
        config.planeDetection = []
        config.environmentTexturing = .none
        if ARWorldTrackingConfiguration.supportsUserFaceTracking {
            config.userFaceTrackingEnabled = false
        }
        sceneView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
        #endif
        arRunning = true
    }

    /// Distance, then who. The number carries the screen, so it is tracked the
    /// way display type is and coloured by how close the pair has got.
    private func setReadout(distance: Float?) {
        let text = distance.map { $0 < arrivalThreshold ? "合流" : formatMeters($0) } ?? "—"
        arDistanceValue.attributedText = Type.tracked(text, font: Type.display)
        arDistanceValue.textColor = distance.map { band(for: $0).colour } ?? .white
        arPeerName.text = activePeerID?.displayName ?? (isDemo ? "デモの相手" : "相手")
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
            arHint.text = sweepHint ?? "端末をゆっくり動かしてください"
            arHint.isHidden = false
            setReadout(distance: nil)
            setARGuidesHidden(true)
            return
        }

        let colour = band(for: distance).colour
        setReadout(distance: distance)

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
            arHint.text = sweepHint ?? "端末をゆっくり動かしてください"
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
        title.font = Type.appName
        title.attributedText = Type.tracked("ここだよ", font: Type.appName)
        title.textColor = .white

        demoButton.setTitle("デモ", for: .normal)
        demoButton.setTitleColor(UIColor.white.withAlphaComponent(0.45), for: .normal)
        demoButton.titleLabel?.font = Type.label
        demoButton.addTarget(self, action: #selector(demoTapped), for: .touchUpInside)
        respondOnPress(demoButton)

        roleSwitch.selectedSegmentIndex = 0
        roleSwitch.selectedSegmentTintColor = amber
        roleSwitch.backgroundColor = cardColour
        roleSwitch.setTitleTextAttributes([.foregroundColor: UIColor.white.withAlphaComponent(0.7),
                                           .font: Type.button], for: .normal)
        roleSwitch.setTitleTextAttributes([.foregroundColor: UIColor.black,
                                           .font: Type.font(15, .bold, .body)], for: .selected)
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
                panel.bottomAnchor.constraint(equalTo: safe.bottomAnchor,
                                              constant: -Self.hudInset),
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

        // Replaced on every refresh by guidanceWhenNoPartner(); this is only what
        // shows for the instant before the first refresh.
        peerEmptyLabel.text = "相手にも「ここだよ」を開いて、「迎えに行く」を選んでもらってください"
        peerEmptyLabel.font = Type.label
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
        respondOnPress(sendButton)

        var cancelConf = UIButton.Configuration.plain()
        cancelConf.title = "合流をやめる"
        cancelConf.baseForegroundColor = UIColor.white.withAlphaComponent(0.65)
        cancelButton.configuration = cancelConf
        cancelButton.isHidden = true
        cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        respondOnPress(cancelButton)

        waiterStatus.text = "場所と目印を選んで、迎えに来てもらう相手に送ります"
        waiterStatus.font = Type.caption
        waiterStatus.textColor = UIColor.white.withAlphaComponent(0.45)
        waiterStatus.textAlignment = .center
        waiterStatus.numberOfLines = 3

        waiterCard.backgroundColor = surfaceColour
        waiterCard.layer.cornerRadius = 22
        waiterCard.layer.borderWidth = 1
        waiterCard.layer.borderColor = UIColor.white.withAlphaComponent(0.07).cgColor

        for v in [waiterCard, waiterDial, sendButton, cancelButton, waiterStatus] {
            waiterPanel.addSubview(v)
            v.translatesAutoresizingMaskIntoConstraints = false
        }
        waiterCard.addSubview(waiterSelection)
        waiterSelection.translatesAutoresizingMaskIntoConstraints = false

        // Hidden views still hold their space, so collapse the selection outright
        // once the request is out — otherwise it keeps pushing the dial down.
        let collapse = waiterCard.heightAnchor.constraint(equalToConstant: 0)
        collapse.priority = .required
        waiterSelectionCollapse = collapse

        // The list keeps its natural height; the dial gives way instead of squashing it.
        waiterSelection.setContentCompressionResistancePriority(.required, for: .vertical)
        peerListStack.setContentCompressionResistancePriority(.required, for: .vertical)
        // Same rank as the list it stands in for. Left at the default it tied with
        // the dial's centring and lost, and the line was crushed to nothing.
        peerEmptyLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        let dialCentre = waiterDial.centerYAnchor.constraint(equalTo: waiterPanel.centerYAnchor, constant: -10)
        dialCentre.priority = .defaultHigh
        dialCentre.isActive = true

        // Preferred size, not a demand: on a short screen it gives way.
        let dialSize = waiterDial.heightAnchor.constraint(equalToConstant: 210)
        dialSize.priority = .defaultHigh
        dialSize.isActive = true

        NSLayoutConstraint.activate([
            waiterCard.topAnchor.constraint(equalTo: waiterPanel.topAnchor),
            waiterCard.leadingAnchor.constraint(equalTo: waiterPanel.leadingAnchor, constant: 20),
            waiterCard.trailingAnchor.constraint(equalTo: waiterPanel.trailingAnchor, constant: -20),

            waiterSelection.topAnchor.constraint(equalTo: waiterCard.topAnchor, constant: 18),
            waiterSelection.bottomAnchor.constraint(equalTo: waiterCard.bottomAnchor, constant: -18),
            waiterSelection.leadingAnchor.constraint(equalTo: waiterCard.leadingAnchor, constant: 18),
            waiterSelection.trailingAnchor.constraint(equalTo: waiterCard.trailingAnchor, constant: -18),

            waiterDial.centerXAnchor.constraint(equalTo: waiterPanel.centerXAnchor),
            waiterDial.topAnchor.constraint(greaterThanOrEqualTo: waiterCard.bottomAnchor, constant: 24),
            // Never allowed to reach the button. A short screen shrinks the dial
            // instead of stacking it on top of what you are meant to press.
            waiterDial.bottomAnchor.constraint(lessThanOrEqualTo: sendButton.topAnchor, constant: -16),
            waiterDial.widthAnchor.constraint(equalTo: waiterDial.heightAnchor),
            waiterDial.heightAnchor.constraint(greaterThanOrEqualToConstant: 132),

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
        respondOnPress(cameraButton)
        cameraButton.isEnabled = false
        cameraButton.alpha = 0.4

        finderStatus.font = Type.caption
        finderStatus.textColor = UIColor.white.withAlphaComponent(0.45)
        finderStatus.textAlignment = .center
        finderStatus.numberOfLines = 2

        finderTip.font = Type.caption
        finderTip.textColor = UIColor.white.withAlphaComponent(0.45)
        finderTip.textAlignment = .center
        finderTip.numberOfLines = 2
        finderTip.isHidden = true

        finderHeadline.font = Type.headline
        finderHeadline.textColor = UIColor.white.withAlphaComponent(0.9)
        finderHeadline.textAlignment = .center
        finderHeadline.numberOfLines = 1
        finderHeadline.isHidden = true

        for v in [finderChips, finderHeadline, finderDial, cameraButton, finderTip, finderStatus] {
            finderPanel.addSubview(v)
            v.translatesAutoresizingMaskIntoConstraints = false
        }

        NSLayoutConstraint.activate([
            finderChips.topAnchor.constraint(equalTo: finderPanel.topAnchor, constant: 4),
            finderChips.leadingAnchor.constraint(equalTo: finderPanel.leadingAnchor, constant: 20),
            finderChips.trailingAnchor.constraint(equalTo: finderPanel.trailingAnchor, constant: -20),

            finderHeadline.bottomAnchor.constraint(equalTo: finderDial.topAnchor, constant: -20),
            finderHeadline.leadingAnchor.constraint(equalTo: finderPanel.leadingAnchor, constant: 24),
            finderHeadline.trailingAnchor.constraint(equalTo: finderPanel.trailingAnchor, constant: -24),

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

        let close = arCloseButton
        var closeConf = UIButton.Configuration.filled()
        closeConf.title = "閉じる"
        closeConf.baseBackgroundColor = .clear
        closeConf.baseForegroundColor = .white
        closeConf.cornerStyle = .capsule
        closeConf.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16)
        close.configuration = closeConf
        close.addTarget(self, action: #selector(closeAR), for: .touchUpInside)
        respondOnPress(close)

        style(chip: arMarkerChip, background: .clear, text: .white)
        arMarkerChip.text = "手を振ってる"

        // Camera video sits behind these, so both need their own ground.
        arHint.font = Type.font(14, .semibold, .subheadline)
        arHint.textColor = .white
        arHint.textAlignment = .center
        arHint.numberOfLines = 2
        arHint.insets = UIEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
        arHint.backgroundColor = .clear
        arHint.layer.cornerRadius = 12
        arHint.clipsToBounds = true

        // A read-out, not a dial: a caption, the number, then the person.
        arDistanceCaption.text = "きょり"
        arDistanceCaption.font = Type.captionStrong
        arDistanceCaption.textColor = UIColor.white.withAlphaComponent(0.7)

        arDistanceValue.font = Type.display
        arDistanceValue.textColor = .white

        arPeerName.font = Type.button
        arPeerName.textColor = UIColor.white.withAlphaComponent(0.85)

        arReadout.axis = .vertical
        arReadout.alignment = .leading
        arReadout.spacing = 2
        arReadout.addArrangedSubview(arDistanceCaption)
        arReadout.addArrangedSubview(arDistanceValue)
        arReadout.setCustomSpacing(10, after: arDistanceValue)
        arReadout.addArrangedSubview(hairline())
        arReadout.setCustomSpacing(10, after: arReadout.arrangedSubviews.last!)
        arReadout.addArrangedSubview(arPeerName)

        for v in [arScrim, close, arMarkerChip, arReadout, arHint] {
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

            arScrim.topAnchor.constraint(equalTo: arScreen.topAnchor),
            arScrim.leadingAnchor.constraint(equalTo: arScreen.leadingAnchor),
            arScrim.trailingAnchor.constraint(equalTo: arScreen.trailingAnchor),
            arScrim.heightAnchor.constraint(equalToConstant: 320),

            arReadout.topAnchor.constraint(equalTo: close.bottomAnchor, constant: 28),
            arReadout.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 24),
            arReadout.trailingAnchor.constraint(lessThanOrEqualTo: safe.trailingAnchor, constant: -24),

            arHint.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 24),
            arHint.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -24),
            arHint.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -28),
        ])

        // Camera video is behind these, which is the one place on this app where
        // a blurred material earns its keep: it separates the chrome from the
        // scene without hiding it. Bigger surface, heavier material.
        putMaterial(behind: close, cornerRadius: 18)
        putMaterial(behind: arMarkerChip, cornerRadius: 16)
        putMaterial(behind: arHint, cornerRadius: 12)
        arScreen.sendSubviewToBack(arScrim)
        arScreen.sendSubviewToBack(sceneView)
        arScreen.bringSubviewToFront(close)
    }

    private func buildArrivalOverlay() {
        arrivalOverlay.backgroundColor = mint
        arrivalOverlay.isHidden = true
        arScreen.addSubview(arrivalOverlay)
        arrivalOverlay.translatesAutoresizingMaskIntoConstraints = false

        let headline = UILabel()
        headline.font = Type.display
        headline.attributedText = Type.tracked("見つけた", font: Type.display)
        headline.textColor = .black
        headline.textAlignment = .center

        let sub = UILabel()
        sub.text = "スマホをしまって顔を上げましょう"
        sub.font = Type.button
        sub.textColor = UIColor.black.withAlphaComponent(0.7)
        sub.textAlignment = .center

        let markerCaption = UILabel()
        markerCaption.text = "相手の目印"
        markerCaption.font = Type.caption
        markerCaption.textColor = UIColor.black.withAlphaComponent(0.55)
        markerCaption.textAlignment = .center

        arrivalMarker.text = "手を振ってる"
        arrivalMarker.font = Type.title
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
        respondOnPress(done)

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
                respondOnPress(row)
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

        peerEmptyLabel.text = guidanceWhenNoPartner()
        peerListStack.isHidden = helpers.isEmpty
        peerEmptyLabel.isHidden = !helpers.isEmpty
        #if DEBUG
        if previewAutoSend, !requestSent, let first = helpers.first, first.distance != nil {
            previewAutoSend = false
            selectedHelperID = first.peerID
            DispatchQueue.main.async { self.sendTapped() }
            if previewResend {
                previewResend = false
                let peer = first.peerID
                DispatchQueue.main.asyncAfter(deadline: .now() + 14) { [weak self] in
                    guard let self, let request = self.activeRequest else { return }
                    print("RECON waiter: resend meet")
                    self.sendMeetRequest(request, to: peer)
                }
            }
        }
        #endif
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

        waiterPanelAnimator = Motion.animate(interrupting: waiterPanelAnimator) {
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
        waiterPanelAnimator = Motion.animate(interrupting: waiterPanelAnimator) {
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
        waiterCard.isHidden = hidden
        waiterSelectionCollapse?.isActive = hidden
    }

    /// Answer on touch-down. Waiting for the release is the single biggest
    /// source of "this feels slow" on an otherwise fast screen.
    private func respondOnPress(_ button: UIButton) {
        button.addTarget(self, action: #selector(pressDown(_:)), for: [.touchDown, .touchDragEnter])
        button.addTarget(self, action: #selector(pressUp(_:)),
                         for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])
    }

    @objc private func pressDown(_ sender: UIButton) { Motion.press(sender, down: true) }
    @objc private func pressUp(_ sender: UIButton) { Motion.press(sender, down: false) }

    /// A blurred material instead of a flat black plate. Only worth it where
    /// something is actually behind the surface — over the camera, not over the
    /// home screen's own background. Falls back to a solid ground when the
    /// reader has asked for less transparency.
    private func putMaterial(behind view: UIView, cornerRadius: CGFloat,
                             style: UIBlurEffect.Style = .systemThinMaterialDark) {
        guard let parent = view.superview else { return }
        let backing: UIView
        if UIAccessibility.isReduceTransparencyEnabled {
            let solid = UIView()
            solid.backgroundColor = UIColor.black.withAlphaComponent(0.86)
            backing = solid
        } else {
            backing = UIVisualEffectView(effect: UIBlurEffect(style: style))
        }
        backing.layer.cornerRadius = cornerRadius
        backing.clipsToBounds = true
        backing.isUserInteractionEnabled = false
        backing.translatesAutoresizingMaskIntoConstraints = false
        parent.insertSubview(backing, belowSubview: view)
        NSLayoutConstraint.activate([
            backing.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backing.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            backing.topAnchor.constraint(equalTo: view.topAnchor),
            backing.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    /// Type only follows the reader's size setting if each label opts in.
    private func followTextSize(from root: UIView) {
        for sub in root.subviews {
            (sub as? UILabel)?.adjustsFontForContentSizeCategory = true
            (sub as? UIButton)?.titleLabel?.adjustsFontForContentSizeCategory = true
            followTextSize(from: sub)
        }
    }

    /// The thin rule that separates the read-out's lines.
    private func hairline() -> UIView {
        let line = UIView()
        line.backgroundColor = UIColor.white.withAlphaComponent(0.35)
        line.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            line.heightAnchor.constraint(equalToConstant: 1),
            line.widthAnchor.constraint(equalToConstant: 132),
        ])
        return line
    }

    /// What the person holding the other phone has to do, in words this side can
    /// read out loud. Two people who have not agreed on roles beforehand cannot
    /// work out "待つ / 迎えに行く" from two bare tabs — the first real pair
    /// outdoors (2026-09-12) got stuck exactly here.
    private func guidanceWhenNoPartner() -> String {
        let mine = role == .requester ? "requester" : "supporter"
        let sameRoleNearby = links.values.contains { $0.peerRole == mine }
        if sameRoleNearby {
            // Both sides picked the same thing. Name the rule rather than the tab.
            return role == .requester
                ? "相手も「待つ」になっています。先に着いた人が「待つ」、これから向かう人が「迎えに行く」です"
                : "相手も「迎えに行く」になっています。先に着いた人が「待つ」、これから向かう人が「迎えに行く」です"
        }
        return role == .requester
            ? "相手にも「ここだよ」を開いて、「迎えに行く」を選んでもらってください"
            : "相手にも「ここだよ」を開いて、「待つ」を選んでもらってください"
    }

    private func sectionLabel(_ text: String) -> UILabel {
        let label = UILabel()
        // Squeezed to nothing on a real 16 Pro, which left the chips with no
        // question above them.
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        label.text = text
        label.font = Type.captionStrong
        label.textColor = UIColor.white.withAlphaComponent(0.45)
        return label
    }

    private func chipRow(titles: [String], action: Selector, store: inout [UIButton]) -> UIView {
        let scroll = FadingScrollView()
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
        // Grows with the reader's text size instead of clipping: at the
        // accessibility sizes a fixed 40pt row swallowed the label below it.
        let rowHeight = scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 40)
        rowHeight.priority = .required
        rowHeight.isActive = true
        scroll.setContentHuggingPriority(.defaultHigh, for: .vertical)

        for (index, title) in titles.enumerated() {
            let button = CapsuleButton(type: .system)
            var conf = UIButton.Configuration.plain()
            conf.title = title
            conf.contentInsets = NSDirectionalEdgeInsets(top: 9, leading: 16, bottom: 9, trailing: 16)
            conf.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in
                var a = attrs
                a.font = Type.font(14, .semibold, .subheadline)
                return a
            }
            button.configuration = conf
            button.tag = index
            // cornerRadius is set from the height on every layout pass: the row
            // now grows with the reader's text size, and a fixed radius would
            // stop matching it.
            button.layer.borderWidth = 1
            button.addTarget(self, action: action, for: .touchUpInside)
            respondOnPress(button)
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
        chip.font = Type.chip
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
            a.font = Type.button
            return a
        }
        conf.subtitleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in
            var a = attrs
            a.font = Type.caption
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
            a.font = Type.appName
            return a
        }
        return conf
    }
}

#if DEBUG
// MARK: - Measurement HUD (実測日の計測器。DEBUGビルドのみ)

extension MeetViewController {

    private func setupMeasureHUD() {
        view.addSubview(hud)
        hud.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hud.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hud.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hud.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            // The bottom strip is the home indicator's, so the HUD sat where a
            // tap never reached it: its 3-tap expand and long-press share were
            // both unusable on a real phone.
            hud.heightAnchor.constraint(greaterThanOrEqualToConstant: 32),
        ])
        hud.onShare = { [weak self] url in
            let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            self?.present(sheet, animated: true)
        }

        // A 60-second still test must not be cut short by auto-lock.
        UIApplication.shared.isIdleTimerDisabled = true

        if CMAltimeter.isRelativeAltitudeAvailable() {
            altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, _ in
                self?.relativeAltitude = data?.relativeAltitude.doubleValue
            }
        }

        hudTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.callbacksPerSecond = self.callbackCounter
            self.callbackCounter = 0
            self.hud.record(self.hudRow())
        }
    }

    /// Peers are logged as 端末A/B/… so CSVs and screenshots carry no names.
    private func anon(_ peer: MCPeerID) -> String {
        if let n = anonNames[peer] { return n }
        let letters = ["A", "B", "C", "D", "E", "F"]
        let n = "端末" + (letters.indices.contains(anonNames.count) ? letters[anonNames.count] : "\(anonNames.count)")
        anonNames[peer] = n
        return n
    }

    private func hudRow() -> [String] {
        let link = activePeerID.flatMap { links[$0] }
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        let dist = (link?.distance ?? latestDistance).map { String(format: "%.2f", $0) } ?? "-"
        let dir = link?.direction ?? latestDirection
        let hAngle = dir.map { String(format: "%.0f", atan2($0.x, -$0.z) * 180 / .pi) } ?? "-"
        var supDir = "-", supCam = "-"
        if #available(iOS 16.0, *) {
            supDir = NISession.deviceCapabilities.supportsDirectionMeasurement ? "1" : "0"
            supCam = NISession.deviceCapabilities.supportsCameraAssistance ? "1" : "0"
        }
        return [
            f.string(from: Date()),
            role == .supporter ? "finder" : "waiter",
            String(describing: phase),
            activePeerID.map { anon($0) } ?? "-",
            String(links.count),
            dist,
            dir == nil ? "1" : "0",
            hAngle,
            activeCameraAssist ? "1" : "0",
            (link?.world ?? latestWorldTransform) == nil ? "1" : "0",
            convergenceText,
            convergenceReasons,
            supDir,
            supCam,
            lastNIError,
            String(callbacksPerSecond),
            relativeAltitude.map { String(format: "%.2f", $0) } ?? "-",
            UIDevice.current.model,
            UIDevice.current.systemVersion,
        ]
    }
}

/// One dark strip at the bottom of the screen. Triple-tap expands every column;
/// long-press shares the whole log as CSV.
final class MeasureHUD: UIView {
    static let header = ["time", "role", "phase", "peer", "mpc", "dist_m", "dir_nil", "h_angle_deg", "cam_assist",
                         "world_nil", "conv", "conv_reasons", "sup_dir", "sup_cam", "ni_error", "cb_per_s",
                         "rel_alt_m", "device", "os"]
    private let label = UILabel()
    private(set) var rows: [[String]] = []
    private var lastRow: [String] = []
    private var expanded = false
    var onShare: ((URL) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.black.withAlphaComponent(0.72)
        label.font = UIFont.monospacedSystemFont(ofSize: 9, weight: .regular)
        label.textColor = UIColor.white.withAlphaComponent(0.9)
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
        ])
        let triple = UITapGestureRecognizer(target: self, action: #selector(toggle))
        triple.numberOfTapsRequired = 3
        addGestureRecognizer(triple)
        addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(share(_:))))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func record(_ row: [String]) {
        rows.append(row)
        lastRow = row
        render()
        print("HUD " + row.joined(separator: ","))
    }

    private func render() {
        guard lastRow.count == Self.header.count else { return }
        if expanded {
            label.numberOfLines = 0
            label.text = zip(Self.header, lastRow).map { "\($0)=\($1)" }.joined(separator: "  ")
        } else {
            label.numberOfLines = 1
            let r = lastRow
            label.text = "d=\(r[5]) dirNil=\(r[6]) ang=\(r[7]) cam=\(r[8]) worldNil=\(r[9]) conv=\(r[10]) cb/s=\(r[15]) err=\(r[14]) alt=\(r[16]) mpc=\(r[4])"
        }
    }

    @objc private func toggle() {
        expanded.toggle()
        render()
    }

    @objc private func share(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began else { return }
        let escape: (String) -> String = { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        let csv = ([Self.header] + rows).map { $0.map(escape).joined(separator: ",") }.joined(separator: "\n")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kokodayo-measure.csv")
        try? csv.data(using: .utf8)?.write(to: url)
        onShare?(url)
    }
}
#endif

// MARK: - NISessionDelegate

extension MeetViewController: NISessionDelegate {

    func session(_ session: NISession, didUpdate nearbyObjects: [NINearbyObject]) {
        guard let peerID = sessionOwners[ObjectIdentifier(session)], let link = links[peerID] else { return }
        link.invalidateRetries = 0
        guard let token = link.peerToken,
              let object = nearbyObjects.first(where: { $0.discoveryToken == token }) else { return }

        callbackCounter += 1
        link.distance = object.distance
        link.direction = object.direction
        if #available(iOS 16.0, *), cameraAssistance, peerID == activePeerID {
            link.world = session.worldTransform(for: object)
        }

        if peerID == activePeerID {
            updateMeasurement(distance: link.distance, direction: link.direction, world: link.world)
        } else {
            refreshPeerList()
            if role == .supporter, activeRequest == nil { refreshDials() }
        }
    }

    @available(iOS 16.0, *)
    func session(_ session: NISession, didUpdateAlgorithmConvergence convergence: NIAlgorithmConvergence, for object: NINearbyObject?) {
        switch convergence.status {
        case .converged:
            convergenceText = "converged"; convergenceReasons = "-"
            sweepHint = nil
        case .notConverged(let reasons):
            convergenceText = "notConverged"
            convergenceReasons = reasons.map { String(describing: $0) }.joined(separator: "|")
            if reasons.contains(.insufficientLighting) {
                sweepHint = "もう少し明るい場所へ"
            } else if reasons.contains(.insufficientMovement) {
                sweepHint = "端末を持って少し歩いてください"
            } else if reasons.contains(.insufficientHorizontalSweep) {
                sweepHint = "左右にゆっくり大きく振ってください"
            } else if reasons.contains(.insufficientVerticalSweep) {
                sweepHint = "上下にもゆっくり振ってください"
            } else {
                sweepHint = "そのまま少し動かしてください"
            }
        case .unknown:
            convergenceText = "unknown"; convergenceReasons = "-"
        @unknown default:
            convergenceText = "?"; convergenceReasons = "-"
        }
        if phase == .guiding { updateGuidance() }
    }

    func session(_ session: NISession, didRemove nearbyObjects: [NINearbyObject], reason: NINearbyObject.RemovalReason) {
        guard let peerID = sessionOwners[ObjectIdentifier(session)], let link = links[peerID] else { return }
        guard let token = link.peerToken, nearbyObjects.contains(where: { $0.discoveryToken == token }) else { return }

        switch reason {
        case .peerEnded:
            // The peer invalidated their session (they finished/cancelled, or
            // restarted). Our session is still fine. Keep it and keep their old
            // token; their new token arrives over MPC and runConfig replaces it.
            link.distance = nil
            link.direction = nil
            link.world = nil
            if peerID == activePeerID {
                latestDistance = nil
                latestDirection = nil
                latestWorldTransform = nil
            }
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
        let ns = error as NSError
        lastNIError = "\(ns.domain)#\(ns.code)"
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
        deadSessions.insert(ObjectIdentifier(session))
        guard let peerID = sessionOwners[ObjectIdentifier(session)] else { return }
        sessionOwners.removeValue(forKey: ObjectIdentifier(session))
        guard let link = links[peerID] else { return }

        // The NI session died, but MultipeerConnectivity is still up and the peer
        // is still standing there. Dropping the link stranded the finder on a
        // frozen AR screen, so keep it and start ranging again.
        let cameraWasOn = activeCameraAssist && peerID == activePeerID
        // -5883 = NIErrorCodeInvalidARConfiguration (iOS 16+). Compared as a raw
        // value so the deployment target stays at 15.0.
        if cameraWasOn, ns.domain == NIErrorDomain, ns.code == -5883 {
            // This device will not do camera assistance with our ARSession. Say so
            // and carry on with distance only, rather than losing the peer.
            cameraAssistFailed = true
            activeCameraAssist = false
            link.world = nil
            link.session = nil
            link.invalidateRetries = 0
            runConfig(for: link)
            if phase == .guiding || phase == .arrived {
                arHint.text = "この端末ではカメラでの方向が出せません。距離と目印で探してください"
                arHint.isHidden = false
            }
            refreshPeerList()
            refreshDials()
            return
        }

        guard link.invalidateRetries < 2 else {
            // Two failures in a row: stop retrying so we do not spin.
            links.removeValue(forKey: peerID)
            if activePeerID == peerID { activePeerID = nil }
            if selectedHelperID == peerID { selectedHelperID = nil }
            refreshPeerList()
            return
        }
        link.invalidateRetries += 1
        link.session = nil
        link.world = nil
        if peerID == activePeerID { activeCameraAssist = false }
        runConfig(for: link)
        refreshPeerList()
    }
}

/// A one-way scrim. Text over camera video needs a ground that does not become
/// a plate: a gradient keeps the scene visible where it matters.
final class GradientView: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }

    init(colors: [UIColor], locations: [NSNumber]) {
        super.init(frame: .zero)
        let layer = self.layer as! CAGradientLayer
        layer.colors = colors.map(\.cgColor)
        layer.locations = locations
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// Fades its trailing edge instead of chopping a pill in half, so the row reads
/// as "there is more over there" rather than as a broken shape.
final class FadingScrollView: UIScrollView {
    private let fade = CAGradientLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        fade.colors = [UIColor.white.cgColor, UIColor.white.cgColor, UIColor.clear.cgColor]
        fade.locations = [0, 0.88, 1]
        fade.startPoint = CGPoint(x: 0, y: 0.5)
        fade.endPoint = CGPoint(x: 1, y: 0.5)
        layer.mask = fade
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fade.frame = bounds
        // Nothing to hint at once the row fits, so stop dimming the last pill.
        let scrolls = contentSize.width > bounds.width + 1
        fade.locations = scrolls ? [0, 0.88, 1] : [0, 1, 1]
        CATransaction.commit()
    }
}

/// A pill whose corner follows its height, so it stays a pill when the reader
/// enlarges text.
final class CapsuleButton: UIButton {
    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
    }
}

// MARK: - Type

/// One scale instead of a dozen loose sizes. Every face scales with the reader's
/// text-size setting, and the large ones are tracked in the way Apple tightens
/// display type (about -0.02em; body stays at 0).
enum Type {
    static func font(_ size: CGFloat, _ weight: UIFont.Weight, _ style: UIFont.TextStyle) -> UIFont {
        UIFontMetrics(forTextStyle: style).scaledFont(for: .systemFont(ofSize: size, weight: weight))
    }

    static var display: UIFont { font(40, .heavy, .largeTitle) }   // 到着の一言
    static var reading: UIFont { font(30, .bold, .title1) }        // ダイヤルの距離
    static var title: UIFont { font(26, .bold, .title2) }          // 到着の目印
    static var headline: UIFont { font(20, .semibold, .title3) }   // 画面の状態
    static var appName: UIFont { font(17, .bold, .headline) }
    static var button: UIFont { font(15, .semibold, .body) }
    static var body: UIFont { font(15, .regular, .body) }
    static var chip: UIFont { font(13, .semibold, .subheadline) }
    static var label: UIFont { font(13, .regular, .subheadline) }
    static var caption: UIFont { font(12, .regular, .caption1) }
    static var captionStrong: UIFont { font(12, .semibold, .caption1) }

    /// -0.02em, the amount Apple tightens large text by. Body is left alone.
    static func tracked(_ text: String, font: UIFont) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: font, .kern: font.pointSize * -0.02])
    }
}

// MARK: - Motion

/// Apple's fluid-interface numbers in one place: springs rather than durations,
/// interruptible rather than fire-and-forget, and silent when the reader has
/// asked for less movement.
/// See ~/.claude/skills/apple-design-uikit (from emilkowalski/skills apple-design).
enum Motion {
    /// Damping 1.0 = no overshoot. Response 0.4s is the default for moving things.
    static func spring(damping: CGFloat = 1.0, response: TimeInterval = 0.4) -> UISpringTimingParameters {
        UISpringTimingParameters(dampingRatio: damping)
    }

    static var reduced: Bool { UIAccessibility.isReduceMotionEnabled }

    /// An interruptible animator. Hand back the previous one to continue from
    /// where it actually is on screen instead of snapping to its target first.
    @discardableResult
    static func animate(damping: CGFloat = 1.0,
                        response: TimeInterval = 0.4,
                        interrupting previous: UIViewPropertyAnimator? = nil,
                        _ changes: @escaping () -> Void) -> UIViewPropertyAnimator? {
        // Stopping at .current leaves the presentation values in place, which is
        // what the next spring starts from.
        if let previous, previous.state == .active {
            previous.stopAnimation(false)
            previous.finishAnimation(at: .current)
        }
        guard !reduced else {
            changes()
            return nil
        }
        let animator = UIViewPropertyAnimator(duration: response, timingParameters: spring(damping: damping,
                                                                                          response: response))
        animator.addAnimations(changes)
        animator.startAnimation()
        return animator
    }

    /// Press feedback that lands before the finger lifts.
    static func press(_ view: UIView, down: Bool) {
        guard !reduced else { return }
        let animator = UIViewPropertyAnimator(duration: 0.1, timingParameters: spring(response: 0.1))
        animator.addAnimations {
            view.transform = down ? CGAffineTransform(scaleX: 0.97, y: 0.97) : .identity
            view.alpha = down ? 0.85 : 1
        }
        animator.startAnimation()
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
