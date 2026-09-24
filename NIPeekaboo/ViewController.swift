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
import CoreLocation
import NearbyInteraction
import MultipeerConnectivity
import simd
import ActivityKit
import CoreMotion
import AppIntents
import CryptoKit
import Security

// MARK: - Meet-up protocol (the waiting side -> the side coming to find them)

struct MeetRequest: Codable {
    enum Kind: String, Codable, CaseIterable {
        case here      // ここで待ってる
        case inside    // お店・建物の中
        case outside   // 外で待ってる

        var text: String {
            switch self {
            case .here: return "その場で待機"
            case .inside: return "建物の中"
            case .outside: return "建物の外"
            }
        }
        /// Shown to the side coming to find them.
        var tip: String {
            switch self {
            case .here: return "相手はその場で待っています。"
            case .inside: return "相手は建物の中にいます。入口から探してください。"
            case .outside: return "相手は建物の外にいます。人の流れの外側を探してください。"
            }
        }
    }
    enum MarkerHint: String, Codable, CaseIterable {
        case wave, standing, seated
        var text: String {
            switch self {
            case .wave: return "手を振っている"
            case .standing: return "立っている"
            case .seated: return "座っている"
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

// Sent right after connecting. It carries no name: only this install's public
// key and a signature over the group and the recipient, so it can neither be
// forged nor replayed to someone else.
/// Sent the moment two phones connect. The random value in it is what the other
/// side must sign, so a proof collected from one phone cannot be shown to another.
struct ChallengeMessage: Codable {
    var type: String = "challenge"
    var nonce: String
}

struct HelloMessage: Codable {
    var type: String = "hello"
    var member: String
    var proof: String
}

/// Someone who opened the link asks the host to be let in.
struct JoinMessage: Codable {
    var type: String = "join"
    var name: String
    /// The one-time key from the link, if this phone opened one.
    var token: String?
}

/// The host's signed list of who is in today's group, with each name fixed at the
/// moment that person was approved. A newer version replaces an older one.
struct WelcomeMessage: Codable {
    var type: String = "welcome"
    var group: String
    var members: [String]
    var names: [String: String]
    var version: Int
    /// いつまで見せ合うか（1970年からの秒）。ホストが変えたらここで伝わる。
    var expires: Double
    var signature: String
}

/// What the host signs for a welcome, encoded with sorted keys, so a comma in a
/// name cannot shift one list into another.
struct WelcomeBody: Codable {
    var group: String
    var members: [String]
    var names: [String: String]
    var version: Int
    var expires: Double
}

/// The host ended the group for everyone. Signed, so only the host can.
struct DissolveMessage: Codable {
    var type: String = "dissolve"
    var group: String
    var signature: String
}

struct DeclineMessage: Codable {
    var type: String = "decline"
}

/// 「ここだよ！」 — one tap that makes the other phone buzz and say look up. The
/// last five metres in a crowd are a phone call's job; this is the phone call.
struct PingMessage: Codable {
    var type: String = "ping"
}

/// Where the host is, in words, for the stretch before the radio can measure:
/// 「北改札の前」 carries 200 m, the radio 20.
struct SpotMessage: Codable {
    var type: String = "spot"
    var text: String
}

/// A name goes only to people already approved.
struct NameMessage: Codable {
    var type: String = "name"
    var name: String
}

/// いまの様子。一人に一言だけ。相手の地図の名前の下に出る。
/// 場所（SpotMessage）はホストが「どこにいるか」を言うもの、こちらは
/// 一人ひとりが「いま何をしているか」を言うもの。役目が違うので別にする。
struct MoodMessage: Codable {
    var type: String = "mood"
    var text: String
}

struct MessageKind: Decodable {
    let type: String
}

// Walking or standing still, sent whenever it changes, so each side can tell who
// is closing in without anybody choosing a side.
struct MotionMessage: Codable {
    var type: String = "motion"
    var moving: Bool
}

/// One signing key per group, kept in the Keychain on this device only until that
/// group expires. A member ID means nothing outside its own group, so the same
/// person cannot be recognised across days or groups, but within one group the
/// same phone stays the same member: leaving and asking again does not get a
/// fresh face past a host who already said no.
enum GroupKey {
    private static let service = "jp.shutanuma.kokodayo.groupkey"

    static func loadOrCreate(groupID: String, expires: Date) -> Curve25519.Signing.PrivateKey {
        load(groupID: groupID) ?? create(groupID: groupID, expires: expires)
    }

    static func create(groupID: String, expires: Date) -> Curve25519.Signing.PrivateKey {
        let key = Curve25519.Signing.PrivateKey()
        delete(groupID: groupID)
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: groupID,
            kSecAttrLabel as String: String(Int(expires.timeIntervalSince1970)),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrSynchronizable as String: false,
            kSecValueData as String: key.rawRepresentation,
        ]
        SecItemAdd(item as CFDictionary, nil)
        return key
    }

    /// グループの期限を変えたら、鍵の寿命も合わせる。合わせないと、
    /// 延ばしたはずのグループの鍵だけ先に消えて、署名できなくなる。
    static func setExpiry(groupID: String, expires: Date) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: groupID,
        ]
        let update: [String: Any] = [kSecAttrLabel as String: String(Int(expires.timeIntervalSince1970))]
        SecItemUpdate(query as CFDictionary, update as CFDictionary)
    }

    static func load(groupID: String) -> Curve25519.Signing.PrivateKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: groupID,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? Curve25519.Signing.PrivateKey(rawRepresentation: data)
    }

    static func delete(groupID: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: groupID,
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Keys whose group has ended, and keys from builds that did not record an end.
    static func purgeExpired() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return }
        let now = Date().timeIntervalSince1970
        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String else { continue }
            let end = (item[kSecAttrLabel as String] as? String).flatMap(Double.init) ?? 0
            if end <= now { delete(groupID: account) }
        }
    }
}

/// Today's group: who may see this phone's distance. Only phones holding the
/// invitation can find each other, each newcomer needs the host's yes, and the
/// whole thing expires at four in the morning.
struct TodayGroup: Codable {
    var id: String
    var hostKey: String
    var hostName: String
    var expires: Date
    var myMember: String
    var approved: [String]
    var names: [String: String] = [:]
    var version: Int = 0
    /// Refused or removed today: not asked about again.
    var rejected: [String] = []
    /// People this phone stopped sharing with, when it is not the host.
    var excluded: [String] = []
    /// Only 「許可しない」 taps. Removing a friend on purpose is not a refusal and
    /// must not close the group to everyone else.
    var refusals: Int = 0
    /// Host side: every invitation link carries a one-time key. The first phone
    /// to open a link walks in — the host sent it to that person — and the key is
    /// spent. A second phone on the same link gets the host's yes-or-no instead.
    var tokens: [String: Bool] = [:]
    /// Joiner side: the key from the link this phone opened.
    var inviteToken: String?
    /// Where the host says they are, in their own words. Set by the host, shown
    /// to everyone else until the distance takes over.
    var spot: String?
    var isHost: Bool { hostKey == myMember }

    enum CodingKeys: String, CodingKey {
        case id, hostKey, hostName, expires, myMember, approved, names, version, rejected, excluded, refusals,
             tokens, inviteToken, spot
    }
}

extension TodayGroup {
    /// A group saved by an older build is missing the fields added since. Those
    /// read as their defaults instead of throwing away a group that is still live.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        hostKey = try c.decode(String.self, forKey: .hostKey)
        hostName = try c.decode(String.self, forKey: .hostName)
        expires = try c.decode(Date.self, forKey: .expires)
        myMember = try c.decode(String.self, forKey: .myMember)
        approved = try c.decode([String].self, forKey: .approved)
        names = try c.decodeIfPresent([String: String].self, forKey: .names) ?? [:]
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 0
        rejected = try c.decodeIfPresent([String].self, forKey: .rejected) ?? []
        excluded = try c.decodeIfPresent([String].self, forKey: .excluded) ?? []
        refusals = try c.decodeIfPresent(Int.self, forKey: .refusals) ?? 0
        tokens = try c.decodeIfPresent([String: Bool].self, forKey: .tokens) ?? [:]
        inviteToken = try c.decodeIfPresent(String.self, forKey: .inviteToken)
        spot = try c.decodeIfPresent(String.self, forKey: .spot)
    }
}

/// Four symbols from a member ID. Read out over LINE, they tell the host that the
/// phone asking to join is the friend it claims to be.
enum Badge {
    private static let symbols = Array("🍎🍊🍋🍉🍇🍓🍒🍑🥝🍍🥥🥑🌽🥕🍄🌰🐶🐱🐭🐹🐰🦊🐻🐼🐨🐯🦁🐮🐷🐸🐵🐔🐧🐦🦆🦉🐝🦋🐢🐙🐬🐳🌵🌲🌻🌸🍀🌙⭐☀🌈⚡❄🔥💧🎈🎁🎵⚽🚲🚀⛵🔑🎩")
    static func of(_ member: String) -> String {
        guard let data = Data(base64URL: member) else { return "" }
        return SHA256.hash(data: data).prefix(4).map { String(symbols[Int($0) % symbols.count]) }.joined()
    }
}

/// Names come from the other phone: control characters and newlines are dropped
/// and the rest cut to twenty characters before it reaches the screen.
func cleanName(_ raw: String) -> String {
    var kept = ""
    kept.unicodeScalars.append(contentsOf: raw.unicodeScalars.filter {
        !CharacterSet.controlCharacters.contains($0) && !CharacterSet.newlines.contains($0)
    })
    let trimmed = kept.trimmingCharacters(in: .whitespaces)
    return String((trimmed.isEmpty ? "相手" : trimmed).prefix(20))
}

extension Data {
    var base64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    init?(base64URL: String) {
        var text = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while text.count % 4 != 0 { text += "=" }
        self.init(base64Encoded: text)
    }
}

// MARK: - Shared colours

// Blue means an action or guidance; mint is reserved for arrival.
// Opaque text colours retain their contrast on the dark sheet material.
enum MeetPalette {
    static let background = UIColor(red: 16/255, green: 22/255, blue: 32/255, alpha: 1)
    static let surface = UIColor(red: 30/255, green: 40/255, blue: 55/255, alpha: 1)
    static let raised = UIColor(red: 44/255, green: 57/255, blue: 76/255, alpha: 1)
    static let primary = UIColor(red: 244/255, green: 247/255, blue: 252/255, alpha: 1)
    static let secondary = UIColor(red: 184/255, green: 196/255, blue: 213/255, alpha: 1)
    static let action = UIColor(red: 169/255, green: 202/255, blue: 255/255, alpha: 1)
    /// Arrival is the seal being pressed: the same ink gold as the scale, not a
    /// second colour. Mint was the sample app's; a mint sheet with black type is
    /// the one screen everyone has seen before.
    static let arrival = UIColor(red: 198/255, green: 164/255, blue: 92/255, alpha: 1)
    /// The trail left behind while the distance was growing. Warm, not alarming:
    /// walking away is not an error, it is information. Kept well off the gold.
    static let drift = UIColor(red: 230/255, green: 140/255, blue: 92/255, alpha: 1)
    /// Ink gold, and only ever the instrument's scale around the reading — the
    /// ticks and the unit. Cover every gold mark with a thumb and the screen
    /// must still work; the day it does not, this colour comes out again.
    static let ink = UIColor(red: 198/255, green: 164/255, blue: 92/255, alpha: 1)
}

// MARK: - The dial both sides look at

/// A ring that fills as the gap closes, with the direction arrow in the middle.
/// Distance is a shape you watch, not a number you read.
final class MeetDial: UIView {

    private let track = CAShapeLayer()
    private let bar = CAShapeLayer()
    /// 探しているあいだ、輪の上を回る金の光。頭が明るく、尾が薄い。
    /// 止まった輪は「壊れている」に見えるので、待っている間は必ず動かす。
    private let sweep = CALayer()
    private let sweepHead = CAShapeLayer()
    private let sweepTail = CAShapeLayer()
    private let innerRing = CAShapeLayer()
    private let midRing = CAShapeLayer()
    /// One metre per mark, scribed on the axis the ring's top edge travels along,
    /// so the ring is read against a ruler instead of against nothing. The marks
    /// know nothing — they never move, and they never say anything the number
    /// does not already say.
    private let scaleMarks = CAShapeLayer()
    private let indexMark = CAShapeLayer()
    private var didDrawScale = false
    /// Arrival. The ring that was the distance is gone; in its place a thin gold
    /// ring sits around the word like a pressed seal, and two hairline ripples
    /// go out once — the press itself. Nothing fills, nothing turns green.
    private let seal = CAShapeLayer()
    private let ripples: [CAShapeLayer] = [CAShapeLayer(), CAShapeLayer()]
    private let arrow = UIImageView(image: UIImage(systemName: "location.north.fill"))
    /// Kept so each new bearing re-targets the running spring instead of queuing
    /// behind it: readings arrive up to 60 times a second.
    private var arrowAnimator: UIViewPropertyAnimator?
    private let valueLabel = UILabel()
    private let captionLabel = UILabel()
    /// With nothing to measure, the ring shows a symbol and a sentence instead of
    /// a number, the way a system screen with no content says so.
    private let symbolView = UIImageView()
    private var isStatus = false
    /// A sentence gets more of the ring's width than a number, and stays on one
    /// line: wrapped, 「距離を測定できません」 left 「ん」 alone on the second.
    private var numberWidth: NSLayoutConstraint?
    private var sentenceWidth: NSLayoutConstraint?

    /// The distance at which the ring fills the screen.
    var span: CGFloat = 20
    /// Where the ring was a few moments ago, left behind and fading. Cool where
    /// the distance was closing, amber where it was opening: at a glance, which
    /// way was working. They die in 12 seconds, so the screen is always about now.
    private var shells: [CAShapeLayer] = []
    private var nextShell = 0
    private var lastShellAt: CFTimeInterval = 0
    private var didTighten = false
    private let shellLife: CFTimeInterval = 10
    private let shellEvery: CFTimeInterval = 0.9
    private var ringScale: CGFloat = 1
    private static let readingWidth: CGFloat = 7
    var lineWidth: CGFloat = 14 { didSet { track.lineWidth = lineWidth; bar.lineWidth = lineWidth } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear

        // Two faint rings inside the track. The references all share one thing:
        // a single strong figure on a dark ground, and nothing else. Rings are
        // also the honest shape here — we know the distance, never the bearing,
        // so "somewhere on this circle" is exactly what we can claim.
        // 金の光。頭（濃く短い弧）と尾（薄く長い弧）を1つの層に入れて、層ごと回す。
        for (layer, alpha, width) in [(sweepTail, CGFloat(0.28), CGFloat(1.0)),
                                      (sweepHead, CGFloat(1.0), CGFloat(1.0))] {
            layer.fillColor = UIColor.clear.cgColor
            layer.strokeColor = MeetPalette.ink.withAlphaComponent(alpha).cgColor
            layer.lineCap = .round
            layer.lineWidth = width
            layer.shadowColor = MeetPalette.ink.cgColor
            layer.shadowOpacity = 0.9
            layer.shadowRadius = 10
            layer.shadowOffset = .zero
            sweep.addSublayer(layer)
        }
        sweep.isHidden = true
        layer.addSublayer(sweep)

        for layer in [innerRing, midRing] {
            layer.fillColor = UIColor.clear.cgColor
            layer.lineWidth = 1
            layer.strokeColor = UIColor.white.withAlphaComponent(0.06).cgColor
            self.layer.addSublayer(layer)
        }
        scaleMarks.fillColor = UIColor.clear.cgColor
        scaleMarks.strokeColor = MeetPalette.ink.cgColor
        scaleMarks.lineWidth = 1
        scaleMarks.lineCap = .butt
        scaleMarks.strokeEnd = 0
        layer.addSublayer(scaleMarks)
        indexMark.fillColor = MeetPalette.ink.cgColor
        indexMark.strokeColor = UIColor.clear.cgColor
        indexMark.opacity = 0
        layer.addSublayer(indexMark)
        seal.fillColor = UIColor.clear.cgColor
        seal.strokeColor = MeetPalette.ink.cgColor
        seal.lineWidth = 1.5
        seal.opacity = 0
        layer.addSublayer(seal)
        for ripple in ripples {
            ripple.fillColor = UIColor.clear.cgColor
            ripple.strokeColor = MeetPalette.ink.cgColor
            ripple.lineWidth = 1
            ripple.opacity = 0
            layer.addSublayer(ripple)
        }

        for layer in [track, bar] {
            layer.fillColor = UIColor.clear.cgColor
            layer.lineCap = .round
            layer.lineWidth = lineWidth
            self.layer.addSublayer(layer)
        }
        track.strokeColor = UIColor.white.withAlphaComponent(0.07).cgColor
        bar.strokeColor = UIColor.white.cgColor
        bar.strokeEnd = 0
        // A whisper of light, not a neon sign. Apple's own finding UI fills a
        // shape; it does not glow.
        bar.shadowOpacity = 0.08
        bar.shadowRadius = 18
        bar.shadowOffset = .zero

        // Twelve is a shell every 0.6s for a little over seven seconds of history;
        // beyond that the oldest is faint enough to reuse.
        for _ in 0..<14 {
            let shell = CAShapeLayer()
            shell.fillColor = UIColor.clear.cgColor
            shell.lineWidth = 2
            shell.opacity = 0
            shell.lineCap = .round
            layer.insertSublayer(shell, at: 0)
            shells.append(shell)
        }

        arrow.contentMode = .scaleAspectFit
        arrow.alpha = 0
        // The radio gives distance and never a bearing, so the dial never draws
        // one. The arrow stays only because the AR screen's own guides do.
        arrow.isHidden = true

        valueLabel.font = Type.dial
        valueLabel.textColor = MeetPalette.primary
        valueLabel.textAlignment = .center
        valueLabel.adjustsFontSizeToFitWidth = true
        valueLabel.minimumScaleFactor = 0.4

        captionLabel.font = Type.caption
        captionLabel.textColor = MeetPalette.secondary
        captionLabel.textAlignment = .center
        captionLabel.numberOfLines = 2

        symbolView.contentMode = .scaleAspectFit
        symbolView.tintColor = MeetPalette.secondary
        symbolView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(weight: .regular)
        symbolView.isHidden = true

        for v in [arrow, symbolView, valueLabel, captionLabel] {
            addSubview(v)
            v.translatesAutoresizingMaskIntoConstraints = false
        }
        numberWidth = valueLabel.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.62)
        sentenceWidth = valueLabel.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.8)
        NSLayoutConstraint.activate([
            arrow.centerXAnchor.constraint(equalTo: centerXAnchor),
            arrow.bottomAnchor.constraint(equalTo: valueLabel.topAnchor, constant: -6),
            arrow.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.20),
            arrow.heightAnchor.constraint(equalTo: arrow.widthAnchor),

            symbolView.centerXAnchor.constraint(equalTo: centerXAnchor),
            symbolView.bottomAnchor.constraint(equalTo: valueLabel.topAnchor, constant: -10),
            symbolView.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.16),
            symbolView.heightAnchor.constraint(equalTo: symbolView.widthAnchor),

            valueLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            valueLabel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 8),
            // Stays inside the ring. Without a width the label just grew past it
            // and adjustsFontSizeToFitWidth had nothing to shrink against.
            numberWidth!,

            captionLabel.topAnchor.constraint(equalTo: valueLabel.bottomAnchor, constant: 2),
            captionLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            // Inside the ring, not spilling past it.
            captionLabel.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.76),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 待っているあいだだけ光を回す。動きを減らす設定の人には、止まった金の弧を置く。
    private func setSweeping(_ on: Bool) {
        sweep.isHidden = !on
        guard on else {
            sweep.removeAnimation(forKey: "sweep")
            return
        }
        guard !UIAccessibility.isReduceMotionEnabled else {
            sweep.removeAnimation(forKey: "sweep")
            return
        }
        guard sweep.animation(forKey: "sweep") == nil else { return }
        let turn = CABasicAnimation(keyPath: "transform.rotation.z")
        turn.fromValue = 0
        turn.toValue = Double.pi * 2
        turn.duration = 2.6
        turn.repeatCount = .infinity
        sweep.add(turn, forKey: "sweep")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let side = min(bounds.width, bounds.height)
        guard side > lineWidth * 2 else {
            // Squeezed out entirely on a short screen. Draw nothing rather than
            // an inside-out ring.
            track.path = nil
            bar.path = nil
            arrow.isHidden = true
            valueLabel.isHidden = true
            captionLabel.isHidden = true
            symbolView.isHidden = true
            return
        }
        valueLabel.isHidden = false
        symbolView.isHidden = !isStatus
        let ringWidth = min(CGFloat(10), side * 0.035)
        track.lineWidth = ringWidth
        bar.lineWidth = ringWidth
        valueLabel.attributedText = valueText(valueLabel.text ?? "", side: side)
        let radius = side / 2 - ringWidth / 2
        let path = UIBezierPath(arcCenter: CGPoint(x: bounds.midX, y: bounds.midY),
                                radius: radius,
                                startAngle: -.pi / 2,
                                endAngle: 1.5 * .pi,
                                clockwise: true)
        track.path = path.cgPath
        bar.path = path.cgPath
        track.frame = bounds
        bar.frame = bounds

        // 光は同じ円の上を走る。頭は1/12周、尾はその手前1/5周。
        sweep.frame = bounds
        sweep.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        sweep.position = CGPoint(x: bounds.midX, y: bounds.midY)
        sweep.bounds = bounds
        let centrePoint = CGPoint(x: bounds.midX, y: bounds.midY)
        let head = UIBezierPath(arcCenter: centrePoint, radius: radius,
                                startAngle: -.pi / 2, endAngle: -.pi / 2 + .pi / 6, clockwise: true)
        let tail = UIBezierPath(arcCenter: centrePoint, radius: radius,
                                startAngle: -.pi / 2 - .pi / 2.2, endAngle: -.pi / 2, clockwise: true)
        sweepHead.path = head.cgPath
        sweepTail.path = tail.cgPath
        for layer in [sweepHead, sweepTail] {
            layer.frame = bounds
            layer.lineWidth = ringWidth
        }
        // Scaled from the middle so the ring grows and shrinks around the number.
        bar.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        bar.position = CGPoint(x: bounds.midX, y: bounds.midY)
        bar.bounds = bounds
        for shell in shells {
            shell.path = path.cgPath
            shell.bounds = bounds
            shell.position = CGPoint(x: bounds.midX, y: bounds.midY)
        }
        applyRingScale(ringScale, animated: false)

        let centre = CGPoint(x: bounds.midX, y: bounds.midY)
        let marks = UIBezierPath()
        for metre in 1...Int(span) {
            let r = radius * scale(for: Float(metre))
            // The ladder stops short of the number: the reading is the figure,
            // the scale is only the paper it is read against.
            guard r > radius * 0.34 else { continue }
            let long = metre % 5 == 0
            let half: CGFloat = long ? 9 : 4.5
            marks.move(to: CGPoint(x: centre.x - half, y: centre.y - r))
            marks.addLine(to: CGPoint(x: centre.x + half, y: centre.y - r))
        }
        scaleMarks.path = marks.cgPath
        scaleMarks.frame = bounds
        let index = UIBezierPath()
        index.move(to: CGPoint(x: centre.x, y: centre.y - radius - 3))
        index.addLine(to: CGPoint(x: centre.x - 4, y: centre.y - radius - 11))
        index.addLine(to: CGPoint(x: centre.x + 4, y: centre.y - radius - 11))
        index.close()
        indexMark.path = index.cgPath
        indexMark.frame = bounds
        // Around the word, inside where the ladder starts.
        seal.path = UIBezierPath(arcCenter: centre, radius: radius * 0.58, startAngle: 0,
                                 endAngle: .pi * 2, clockwise: true).cgPath
        seal.bounds = bounds
        seal.position = centre
        for ripple in ripples {
            ripple.path = path.cgPath
            ripple.bounds = bounds
            ripple.position = centre
        }

        for (layer, scale) in [(midRing, CGFloat(0.66)), (innerRing, CGFloat(0.36))] {
            layer.frame = bounds
            layer.path = UIBezierPath(arcCenter: CGPoint(x: bounds.midX, y: bounds.midY),
                                      radius: radius * scale,
                                      startAngle: 0, endAngle: .pi * 2,
                                      clockwise: true).cgPath
        }
        // Keep the text area clear; the outer ring already conveys distance.
        innerRing.isHidden = true
        midRing.isHidden = true
        // Squeezed small on a short screen there is no room inside the ring for a
        // two-line caption, and it spills out below. The bottom of the screen is
        // already saying the same thing.
        captionLabel.isHidden = side < 140
    }

    /// A number fills the ring; a sentence about the state sits at headline size.
    private func valueText(_ text: String, side: CGFloat) -> NSAttributedString {
        guard side > 0 else { return NSAttributedString(string: text, attributes: [.font: Type.dial]) }
        if isStatus {
            let font = Type.font(min(CGFloat(17), side * 0.068), .semibold, .headline)
            return NSAttributedString(string: text, attributes: [.font: font])
        }
        let attributed = NSMutableAttributedString(attributedString:
            Type.tracked(text, font: Type.font(min(CGFloat(56), side * 0.20), .bold, .largeTitle)))
        // 「8」 is the reading and stays white; 「m」 belongs to the scale.
        if let unit = text.range(of: " m", options: .backwards), unit.upperBound == text.endIndex {
            let range = NSRange(unit, in: text)
            attributed.addAttribute(.foregroundColor, value: MeetPalette.ink, range: range)
            attributed.addAttribute(.font, value: Type.font(min(CGFloat(30), side * 0.11), .semibold, .title3), range: range)
        }
        return attributed
    }

    /// Distance as a size, not as a percentage: an 8 m ring is twice a 4 m ring,
    /// and walking in actually shrinks it. The power curve keeps the near metres,
    /// where the last few steps happen, from collapsing into a dot.
    private func scale(for distance: Float) -> CGFloat {
        let d = min(max(CGFloat(distance), 0), span) / span
        return max(0.10, pow(d, 0.72))
    }

    private func applyRingScale(_ scale: CGFloat, animated: Bool) {
        ringScale = scale
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        if animated {
            CATransaction.setAnimationDuration(0.35)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        }
        bar.transform = CATransform3DMakeScale(scale, scale, 1)
        // Constant on screen whatever the ring's size: a drawn instrument line,
        // not a band that fattens as you walk in.
        bar.lineWidth = Self.readingWidth / max(scale, 0.05)
        CATransaction.commit()
    }

    /// Leaves the current ring behind as a shell, coloured by whether those
    /// seconds were taking you closer.
    private func dropShell(scale: CGFloat, closing: Bool?) {
        // Nothing is left behind once the ring is down among the words: the last
        // few metres are about the number, not about where you have been.
        guard scale > 0.44 else { return }
        let now = CACurrentMediaTime()
        guard now - lastShellAt >= shellEvery else { return }
        lastShellAt = now
        let shell = shells[nextShell % shells.count]
        nextShell += 1
        let colour: UIColor
        switch closing {
        case true?: colour = MeetPalette.action
        case false?: colour = MeetPalette.drift
        default: colour = MeetPalette.secondary.withAlphaComponent(0.5)
        }
        shell.removeAllAnimations()
        // Placed, not animated into place: a shell marks where the ring was, and
        // Core Animation's implicit 0.25 s would slide it in from the last one.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shell.strokeColor = colour.cgColor
        shell.transform = CATransform3DMakeScale(scale, scale, 1)
        shell.lineWidth = 2.5 / max(scale, 0.05)
        shell.opacity = 0
        CATransaction.commit()
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.62
        fade.toValue = 0
        fade.duration = shellLife
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        shell.add(fade, forKey: "fade")
    }

    /// Drawn once, clockwise from the top, at the first real reading — the moment
    /// the app stops guessing and starts measuring.
    private func scribeScale() {
        scaleMarks.opacity = 1
        guard !didDrawScale else { return }
        didDrawScale = true
        let draw = CABasicAnimation(keyPath: "strokeEnd")
        draw.fromValue = 0
        draw.toValue = 1
        draw.duration = 0.7
        draw.timingFunction = CAMediaTimingFunction(name: .easeOut)
        scaleMarks.strokeEnd = 1
        scaleMarks.add(draw, forKey: "scribe")
        let appear = CABasicAnimation(keyPath: "opacity")
        appear.fromValue = 0
        appear.toValue = 1
        appear.duration = 0.7
        indexMark.opacity = 1
        indexMark.add(appear, forKey: "appear")
    }

    private func collapse() {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.45)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeIn))
        bar.transform = CATransform3DMakeScale(0.02, 0.02, 1)
        bar.opacity = 0
        for shell in shells where shell.presentation()?.opacity ?? 0 > 0.01 {
            shell.removeAllAnimations()
            shell.transform = CATransform3DMakeScale(0.02, 0.02, 1)
            shell.opacity = 0
        }
        scaleMarks.opacity = 0
        indexMark.opacity = 0
        CATransaction.commit()
        ringScale = 0.02
        pressSeal()
    }

    private func pressSeal() {
        let press = CAKeyframeAnimation(keyPath: "transform.scale")
        press.values = [0.86, 1.03, 1]
        press.keyTimes = [0, 0.6, 1]
        press.duration = 0.55
        press.timingFunction = CAMediaTimingFunction(name: .easeOut)
        seal.opacity = 1
        seal.add(press, forKey: "press")
        for (index, ripple) in ripples.enumerated() {
            let grow = CABasicAnimation(keyPath: "transform.scale")
            grow.fromValue = 0.2
            grow.toValue = 1.12
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.8
            fade.toValue = 0
            let group = CAAnimationGroup()
            group.animations = [grow, fade]
            group.duration = 1.1
            group.beginTime = CACurrentMediaTime() + 0.2 * Double(index)
            group.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ripple.opacity = 0
            ripple.add(group, forKey: "ripple")
        }
    }

    /// One press at arrival, the way a seal is pressed: the scale tightens by a
    /// hair and lets go. Nothing else on screen moves.
    private func tightenScale() {
        let press = CAKeyframeAnimation(keyPath: "transform.scale")
        press.values = [1, 0.97, 1]
        press.keyTimes = [0, 0.35, 1]
        press.duration = 0.32
        press.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        scaleMarks.add(press, forKey: "press")
        indexMark.add(press, forKey: "press")
    }

    func clearShells() {
        for shell in shells {
            shell.removeAllAnimations()
            shell.opacity = 0
        }
        lastShellAt = 0
    }

    func set(distance: Float?, direction: simd_float3?, colour: UIColor, value: String, caption: String,
             symbol: String? = nil, closing: Bool? = nil, arrived: Bool = false, waiting: Bool = false) {
        isStatus = symbol != nil
        setSweeping(waiting && distance == nil)
        symbolView.image = symbol.flatMap { UIImage(systemName: $0) }
        symbolView.isHidden = symbol == nil
        if isStatus {
            numberWidth?.isActive = false
            sentenceWidth?.isActive = true
        } else {
            sentenceWidth?.isActive = false
            numberWidth?.isActive = true
        }
        captionLabel.numberOfLines = isStatus ? 3 : 2
        valueLabel.attributedText = valueText(value, side: min(bounds.width, bounds.height))
        captionLabel.text = caption
        // With the ring gone at arrival, the word carries the colour that used to
        // live in it. Nothing else on the screen turns mint.
        valueLabel.textColor = MeetPalette.primary
        if !arrived { seal.opacity = 0 }
        arrow.tintColor = colour
        bar.strokeColor = colour.cgColor
        bar.shadowColor = colour.cgColor

        if let distance {
            bar.strokeEnd = 1
            bar.isHidden = false
            track.lineDashPattern = nil
            track.removeAnimation(forKey: "turn")
            // Arrived: the instrument has nothing left to say, so ring, trail and
            // scale go into the middle and leave the word on its own.
            if arrived {
                if !didTighten {
                    didTighten = true
                    tightenScale()
                    collapse()
                }
            } else {
                didTighten = false
                let s = scale(for: distance)
                // The ring never enters the words. Once it would be smaller than
                // the number it is read from, the number is the reading and the
                // ring bows out.
                bar.opacity = s < 0.42 ? 0 : 1
                applyRingScale(s, animated: true)
                dropShell(scale: s, closing: closing)
                scribeScale()
            }
        } else {
            // Nothing measured yet. A ring that is drawn but broken says so
            // better than an empty one, and it turns slowly so it reads as
            // waiting rather than as failure.
            bar.isHidden = true
            clearShells()
            didDrawScale = false
            didTighten = false
            scaleMarks.strokeEnd = 0
            indexMark.opacity = 0
            if isStatus {
                track.lineDashPattern = nil
                track.removeAnimation(forKey: "turn")
            } else if track.animation(forKey: "turn") == nil {
                track.lineDashPattern = [2, 14]
                let turn = CABasicAnimation(keyPath: "transform.rotation.z")
                turn.fromValue = 0
                turn.toValue = Double.pi * 2
                turn.duration = 24
                turn.repeatCount = .infinity
                track.add(turn, forKey: "turn")
            }
        }
    }

    func reset() {
        arrowAnimator?.stopAnimation(true)
        arrowAnimator = nil
        bar.strokeEnd = 0
        arrow.alpha = 0
        arrow.transform = .identity
        clearShells()
        applyRingScale(1, animated: false)
        didDrawScale = false
        didTighten = false
        scaleMarks.strokeEnd = 0
        indexMark.opacity = 0
        seal.opacity = 0
    }
}

final class MeetViewController: UIViewController {

    // MARK: - Role

    private enum Role { case supporter, requester }   // supporter = 迎えに行く / requester = 待つ
    /// Nobody picks a side any more: every phone runs the path that can both ask
    /// and accept, and walking decides who is closing in. The requester code
    /// below is no longer reachable.
    private var role: Role = .supporter

    // MARK: - Flow state

    private enum Phase { case searching, ready, guiding, arrived }
    private var phase: Phase = .searching { didSet { applyPhase() } }

    private var activeRequest: MeetRequest?
    private var requestSent = false

    private let arrivalThreshold: Float = 1.0
    /// Where the screen stops guiding and tells you to look up instead.
    private static let handoffDistance: Float = 2.5
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
        /// Walking or not, as that phone last said. Kept per link so switching
        /// focus between friends does not forget what each of them is doing.
        var moving: Bool?
        var isDemo = false
        /// Guards the auto-recovery in didInvalidateWith against a loop when the
        /// replacement session fails the same way. Reset on the next measurement.
        var invalidateRetries = 0
        init(peerID: MCPeerID) { self.peerID = peerID }
    }

    // 遠いときの層（RemoteMeet.swift）。UWBが届かない間だけ働く。
    private var remote: RemoteChannel?
    private let locations = LocationSource()
    private var theirFix: RemoteFix?
    private var remotePush: Timer?
    private weak var mapScreen: MeetMapViewController?
    /// ホーム画面の下に敷く地図（画面を増やさず、同じ地図を埋めて使う）。
    private weak var mapFloor: MeetMapViewController?
    private let topScrim = GradientView(colors: [MeetPalette.background.withAlphaComponent(0.92),
                                                 MeetPalette.background.withAlphaComponent(0.55),
                                                 .clear],
                                        locations: [0, 0.5, 1])
    /// 輪が前に出るときに地図を落とす幕。地図と輪が同時に主役になると
    /// どちらも読めない（実測で確かめた）。
    private let floorDim = UIView()
    private let bottomScrim = GradientView(colors: [UIColor.clear,
                                                    MeetPalette.background.withAlphaComponent(0.6),
                                                    MeetPalette.background.withAlphaComponent(0.96)],
                                           locations: [0, 0.45, 1])

    // おつかいと「近くにいるよ」。どちらも相手が遠いあいだの層に乗る。
    /// 相手のそばで見つかった店。見つかっている間だけ「頼む」が出せる。
    private var peerStore: NearbyStore.Found?
    private var storeCheckedAt = Date.distantPast
    private var storeCheckedFrom: CLLocationCoordinate2D?
    /// 自分が頼んだリストと、相手が買えたと言っている物。
    private var sentErrand: ErrandMessage?
    private var sentErrandGot: [String] = []
    /// 自分が頼まれたリストと、自分が買えた物。
    private var myErrand: ErrandMessage?
    private var myErrandGot: [String] = []
    /// 中継は投げっぱなしなので、返事が来るまで数回だけ送り直す。
    private var errandResend: Timer?
    private var errandResends = 0
    /// 同じリストがMPCと中継の両方から届く。番号で一度だけ受け取る。
    private var seenErrands = Set<String>()
    /// 相手が決めた距離まで近づいたかの見張り。
    private var approach = ApproachWatcher()
    /// 相手のいまの様子（一言）。
    private var peerMood: String?
    private static let moodKey = "kokodayo.mood"
    /// 自分のいまの様子。次の待ち合わせでもそのまま使えるよう覚えておく。
    private var myMood: String? {
        get { UserDefaults.standard.string(forKey: Self.moodKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.moodKey) }
    }
    #if DEBUG
    /// 確認用。電波（UWB）が無いことにして、地図側の表示を試す。
    private var previewNoRadio = false
    #endif

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
    /// カメラ補助で得られる値。方向が出ない端末でも、これなら出るかを実機で確かめるため。
    private var latestHorizontalAngle: Float?
    private var latestVerticalEstimate: String?
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
    /// The ring of places the friend could be, standing on the floor of the room
    /// you are actually in. The radio gives one number, so the honest picture is
    /// a circle — and a circle is something you can walk through.
    private let possibleRing = SCNNode()
    private var possibleRods: [SCNNode] = []
    private let possibleTrail = SCNNode()
    private var lastTrailDrop: simd_float3?
    /// The circles already standing in the room. Two circles that were measured
    /// from different spots cross in at most two places, and one of those places
    /// is where the friend was. Keeping a few of them is the whole trick.
    private var trailCircles: [(centre: simd_float3, radius: Float)] = []
    /// Crossings that keep landing in the same spot. Two circles cross in two
    /// places and one of them is a mirror; walk a few metres and only the real
    /// one keeps collecting crossings. The tall bright pins are the votes.
    private var crossingVotes: [(point: simd_float3, count: Int, node: SCNNode)] = []
    /// Roughly hand height: the rings stand on the floor, not in your face.
    private let floorDrop: Float = 1.35
    /// Camera view without camera assistance: distance comes from the radio, the
    /// picture from our own ARSession. Nothing is handed to NearbyInteraction, so
    /// -5883 never enters into it.
    private var floorRingsOnly = false
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
    /// A tick, not a thud. Picking one of three pills should feel like a dial
    /// clicking over, which is what UISelectionFeedbackGenerator is for.
    private let selectionTick = UISelectionFeedbackGenerator()
    /// The panel toggles between "choose and send" and "sent, cancel". Tapping
    /// send then cancel quickly must reverse from where the panel actually is.
    private var waiterPanelAnimator: UIViewPropertyAnimator?

    // MARK: - Proximity feedback (colour + haptics tighten as the gap closes)

    private enum ProximityBand: Int {
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
            case .far, .mid, .near: return MeetPalette.action
            case .arrived: return MeetPalette.arrival
            }
        }
    }
    private var currentBand: ProximityBand?
    private var hapticTimer: Timer?
    /// When the last real reading arrived. Silence means "not measuring", so the
    /// beat must stop rather than keep a stale rhythm going.
    private var lastDistanceAt: CFTimeInterval = 0
    private var staleTimer: Timer?
    /// A 「ここだよ！」 just arrived: the headline hands over to it for a few seconds.
    private var pingUntil: CFTimeInterval = 0
    /// 最後に合図を受けた時刻。二重に鳴らさないための覚え書き。
    private var lastPingAt: CFTimeInterval = 0
    private var pingFrom = ""
    private var lastSentInstruction: String?
    private var lastSentArrived: Bool?
    /// The Dynamic Island / Lock Screen face of the meet-up. It carries one
    /// number — how far apart the two phones are — and ends when the group does.
    private var meetActivityBox: Any?
    private var lastActivityUpdate: CFTimeInterval = 0

    @available(iOS 16.2, *)
    private var meetActivity: Activity<MeetActivityAttributes>? {
        get { meetActivityBox as? Activity<MeetActivityAttributes> }
        set { meetActivityBox = newValue }
    }
    private static let hapticsKey = "kokodayo.haptics"
    private var hapticsOn: Bool {
        get { UserDefaults.standard.object(forKey: Self.hapticsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.hapticsKey) }
    }
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

    private let bgColour = MeetPalette.background
    private let cardColour = MeetPalette.surface
    private let actionColour = MeetPalette.action
    private let arrivalColour = MeetPalette.arrival

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
    /// Everything the waiting side touches rides on a sheet that rises from the
    /// bottom edge and sits **over** the dial. Stacking the two caused every
    /// squeeze bug on 2026-09-12: on a short screen they fought for one column and
    /// Auto Layout picked a loser at random. Overlapping ends that class of bug.
    /// The content UIKit's sheet carries. No surface of its own: the sheet is it.
    private var waiterSheetVC: SheetCarrier?
    /// What the sheet rests at: the primary button and the line under it. Anything
    /// above that is behind a drag, which is the whole point of the sheet.
    private static let compactSheetHeight: CGFloat = 208
    /// Just the grabber and a sliver of the button: enough to tap, nothing to read.
    private static let closedSheetHeight: CGFloat = 64
    private let waiterCard = UIView()
    private let peerListStack = UIStackView()
    private let peerEmptyLabel = UILabel()
    private var peerRows: [MCPeerID: UIButton] = [:]
    private var peerOrder: [MCPeerID] = []
    /// Who sent the link that opened this app, if it was opened that way.
    private var invitedBy: String?
    private let callButton = UIButton(type: .system)
    private let waiterControls = UIStackView()
    private var selectedKind: MeetRequest.Kind =
        MeetRequest.Kind(rawValue: UserDefaults.standard.string(forKey: "kokodayo.kind") ?? "") ?? .here
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
        return measurementUIVisible ? 34 : 0
        #else
        return 0
        #endif
    }
    #if DEBUG
    private static var measurementUIVisible: Bool {
        !Set(CommandLine.arguments).isDisjoint(with: ["-previewMeasure", "-previewLog", "-previewCaps"])
    }
    #endif

    /// A passing message (disconnected, they cancelled). Outranks the standby
    /// copy until something replaces it, so the two do not fight over one label.
    private var finderNotice: String?
    private var lastSameRoleHere = false
    /// The actions under the ring: connect to someone, invite, look with the
    /// camera, or end. Only the ones that apply are on screen.
    private let actionStack = UIStackView()
    private let connectStack = UIStackView()
    /// 覚えた相手を並べる場所（リンクを送らずに、押すだけで再開する）
    private let friendsStack = UIStackView()
    private var connectRows: [MCPeerID: UIButton] = [:]
    private var connectOrder: [MCPeerID] = []
    private let inviteButton = UIButton(type: .system)
    /// 相手が店のそばにいる間だけ出る。用が無いときは画面から消えている。
    private let errandButton = UIButton(type: .system)
    /// 輪の中がいま「まわりを見る」かどうか。
    private var dialExplores = false
    /// 地図の上に浮かぶ小さい丸。左が「まわりを見る」、右が地図⇄カメラ。
    private let exploreButton = UIButton(type: .system)
    private let switchButton = UIButton(type: .system)
    private let floatingButtons = UIStackView()
    private let endButton = UIButton(type: .system)
    private let motionActivity = CMMotionActivityManager()
    private var motionStarted = false
    /// Walking or not, from Core Motion. nil until known, or where unavailable.
    private var isMoving: Bool?
    /// Whether the focused friend is walking, as their phone last said. Lives on
    /// the link, so a tap to another friend shows what that friend is doing.
    private var peerMoving: Bool? {
        get { activePeerID.flatMap { links[$0]?.moving } }
        set { if let id = activePeerID { links[id]?.moving = newValue } }
    }
    private var didAnnounceArrival = false
    /// Everyone this phone has connected to, in the order they joined. The first
    /// one is the focus until another name is tapped.
    private var groupPeers: [MCPeerID] = []
    private static let maxGroup = 7
    private let friendsRadar = FriendsRadar()
    private let radarCaption = UILabel()
    /// Whether the distance to the focused person is falling or rising. Japan gives
    /// no bearing, but walking a few steps and watching this gives one.
    private enum Trend { case none, closer, farther }
    private var trend: Trend = .none
    private var trendSamples: [(time: TimeInterval, meters: Float)] = []
    private let trendLabel = PaddedLabel()
    private var group: TodayGroup?
    private static let groupKey = "kokodayo.todayGroup"
    /// A throwaway name on the air. The real one only goes to approved people.
    private var myPeerName = ""
    private var peerNames: [MCPeerID: String] = [:]
    private var peerMembers: [MCPeerID: String] = [:]
    /// The random value this phone sent to each peer, and expects back signed.
    private var myChallenge: [MCPeerID: String] = [:]
    private var joinQueue: [MCPeerID] = []
    private var askingJoin = false
    private var awaitingApproval = false
    private var signingKey: Curve25519.Signing.PrivateKey?
    private var expiryTimer: Timer?
    private var joinAlert: UIAlertController?
    private var joinAlertPeer: MCPeerID?
    private var resumePending = false
    private let finderTip = UILabel()
    /// 一時の知らせ。下の1行（状態）とは別の、浮いた面に出す。
    private let toast = ToastView()

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
    private let arrivalSeal = SealMark()
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
        selectionTick.prepare()

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

        loadTodayGroup()
        endOrphanedActivities()
        NotificationCenter.default.addObserver(self, selector: #selector(appWillEnterForeground),
                                               name: UIApplication.willEnterForegroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appDidEnterBackground),
                                               name: UIApplication.didEnterBackgroundNotification, object: nil)
        // 知らせの「合図する」。アプリが起きていれば1つめ、止まっていたところから
        // 起こされたときは2つめが拾う（画面より先にボタンが押されている）。
        NotificationCenter.default.addObserver(self, selector: #selector(pingFromNotification),
                                               name: .kokodayoPingRequested, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(pingFromNotification),
                                               name: UIApplication.didBecomeActiveNotification, object: nil)
        refreshDials()
        if supportsUWB {
            // A group restored from the last launch waits for the resume prompt.
            if group == nil { startup() }
        } else {
            waiterStatus.text = "デモは右上のメニューから利用できます。"
            finderStatus.text = "デモは右上のメニューから利用できます。"
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
        #if DEBUG
        previewNoRadio = args.contains("-previewNoRadio")
            || ProcessInfo.processInfo.environment["KOKODAYO_NO_RADIO"] == "1"
        print("RECON flags noRadio=\(previewNoRadio) args=\(args.dropFirst().joined(separator: " "))")
        // 画面から読めない確認のために、書類フォルダにも残す（DEBUGのみ）
        if let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let line = "noRadio=\(previewNoRadio) args=\(args.dropFirst().joined(separator: " ")) env=\(ProcessInfo.processInfo.environment["KOKODAYO_NO_RADIO"] ?? "-")\n"
            try? line.write(to: dir.appendingPathComponent("recon.txt"), atomically: true, encoding: .utf8)
        }
        #endif
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
        if args.contains("-previewFloor") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.startFloorPreview() }
        }
        if args.contains("-previewSolo") {
            // One friend, closing in: the only way to watch the ring, the trail
            // and the scale on a single machine without two phones and real UWB.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.startSoloDemo() }
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
        if let arg = args.first(where: { $0.hasPrefix("-previewInvite=") }),
           let url = URL(string: String(arg.dropFirst("-previewInvite=".count))) {
            // iOS asks "Open in ここだよ?" before handing over a custom scheme, and
            // a simulator run cannot tap that. This is the same entry point.
            DispatchQueue.main.async { self.handleInvite(url) }
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
                print("MEASURE cardFrame=\(self.waiterCard.frame) controlsFrame=\(self.waiterControls.frame) send=\(self.sendButton.frame) call=\(self.callButton.frame) status=\(self.waiterStatus.frame) cancelHidden=\(self.cancelButton.isHidden)")
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
        showWaiterSheetIfNeeded()
        askToResumeIfNeeded()
    }

    /// The waiting side's controls live in a UIKit sheet over the home screen. At
    /// rest it shows only the primary button; drag it up for the choices. Apple's
    /// own Precision Finding puts a distance and nothing else on screen, and Uber
    /// shows a map and a search field until anything else becomes relevant.
    private func showWaiterSheetIfNeeded() {
        guard role == .requester, presentedViewController == nil, view.window != nil else { return }
        let carrier = SheetCarrier(head: waiterControls, body: waiterCard)
        carrier.isModalInPresentation = true        // never swiped away entirely
        carrier.modalPresentationStyle = .pageSheet
        if let sheet = carrier.sheetPresentationController {
            sheet.delegate = carrier
            sheet.prefersGrabberVisible = true
            sheet.preferredCornerRadius = 28
            // Otherwise the scroll view inside swallows the drag and the sheet
            // jumps straight to its largest detent: the grabber looked dead.
            sheet.prefersScrollingExpandsWhenScrolledToEdge = false
            if #available(iOS 16.0, *) {
                let compact = UISheetPresentationController.Detent.custom(identifier: .init("compact")) { [weak carrier] context in
                    // Measured, not guessed: exactly the fixed head plus the home
                    // indicator. 208pt was a number I made up and never checked.
                    let wanted = (carrier?.headHeight ?? Self.compactSheetHeight) + 8
                    let value = min(wanted, context.maximumDetentValue * 0.9)
                    #if DEBUG
                    print("SHEET compact=\(value) head=\(carrier?.headHeight ?? -1) max=\(context.maximumDetentValue)")
                    #endif
                    return value
                }
                // Like LINE's rich menu: it can be put away entirely, leaving a
                // tab you tap to bring it back. Until now the lowest rest still
                // covered a third of the screen, which read as "won't go down".
                let closed = UISheetPresentationController.Detent.custom(identifier: .init("closed")) { _ in
                    Self.closedSheetHeight
                }
                sheet.detents = [closed, compact, .medium()]
                sheet.largestUndimmedDetentIdentifier = .medium
                var start: UISheetPresentationController.Detent.Identifier = .init("compact")
                #if DEBUG
                // The sheet can only be dragged by a finger, which a simulator run
                // does not have. This opens it for a screenshot.
                if CommandLine.arguments.contains("-previewSheetOpen") { start = .medium }
                if CommandLine.arguments.contains("-previewSheetClosed") {
                    start = .init("closed")
                    DispatchQueue.main.async { carrier.setHeadVisible(false) }
                }
                #endif
                sheet.selectedDetentIdentifier = start
                carrier.setBodyVisible(start == .medium)
            } else {
                sheet.detents = [.medium(), .large()]
                sheet.largestUndimmedDetentIdentifier = .medium
            }
        }
        waiterSheetVC = carrier
        carrier.onDetentChange = { [weak carrier] id in
            carrier?.setHeadVisible(id != "closed")
            carrier?.setBodyVisible(id == "com.apple.UIKit.medium" || id == "com.apple.UIKit.large")
        }
        carrier.onHeadTap = { [weak carrier] in
            guard #available(iOS 16.0, *), let sheet = carrier?.sheetPresentationController else { return }
            let next: UISheetPresentationController.Detent.Identifier =
                sheet.selectedDetentIdentifier == .init("closed") ? .init("compact") : .init("closed")
            sheet.animateChanges {
                sheet.selectedDetentIdentifier = next
            }
            carrier?.setHeadVisible(next != .init("closed"))
            carrier?.setBodyVisible(false)
        }
        present(carrier, animated: true) { [weak carrier] in
            // The head can lose a button before the sheet has a width to measure
            // it with, which left the compact rest a button taller than its content.
            if #available(iOS 16.0, *) { carrier?.sheetPresentationController?.invalidateDetents() }
        }
    }

    private func hideWaiterSheet() {
        guard let carrier = waiterSheetVC else { return }
        waiterSheetVC = nil
        carrier.dismiss(animated: true)
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    // MARK: - Inviting the other phone

    /// `kokodayo://meet?name=…&kind=here&mode=wave`
    ///
    /// Sent over whatever messenger the pair already uses, so the buzz on the
    /// other phone comes from LINE rather than from a push service we would have
    /// to run. Tapping it opens this app already on the finding side, with the
    /// waiting side's place and marker filled in. Apple's own Precision Finding
    /// works the same way round: notify, the other person taps, then it measures.
    private func inviteURL() -> URL? {
        guard var current = group, current.isHost else { return nil }
        // One key per link. The person it was sent to spends it by opening it;
        // anyone it is forwarded to afterwards has to be let in by hand.
        let token = SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) }.base64URL
        current.tokens[token] = false
        group = current
        saveTodayGroup()
        var c = URLComponents()
        c.scheme = "kokodayo"
        c.host = "join"
        c.queryItems = [
            URLQueryItem(name: "g", value: current.id),
            URLQueryItem(name: "k", value: current.hostKey),
            URLQueryItem(name: "n", value: current.hostName),
            URLQueryItem(name: "e", value: String(Int(current.expires.timeIntervalSince1970))),
            URLQueryItem(name: "t", value: token),
        ]
        return c.url
    }

    /// Opened from the link. Nothing happens until the person confirms: what the link
    /// claims is shown as a claim, and joining sends their name to the host.
    func handleInvite(_ url: URL) {
        guard url.scheme == "kokodayo", url.host == "join",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return }
        let value = { (key: String) in items.first { $0.name == key }?.value }
        guard let id = value("g"), id.count >= 16,
              let hostKey = value("k"), Data(base64URL: hostKey)?.count == 32 else { return }
        let claimed = value("e").flatMap(Double.init).map { Date(timeIntervalSince1970: $0) } ?? Self.endOfToday()
        // Never longer than today, whatever the link says.
        let expires = min(claimed, Self.maxExpiry())
        guard expires > Date() else {
            finderNotice = "この招待リンクは期限が切れています"
            refreshDials()
            return
        }
        guard group?.id != id else { return }
        let hostName = cleanName(value("n") ?? "相手")
        let token = value("t")
        // No group on this phone: the tap on the link was the decision. iOS has
        // already asked once; the waiting screen says what the other side sees.
        guard let current = group else {
            joinGroup(id: id, hostKey: hostKey, hostName: hostName, expires: expires, token: token)
            return
        }
        // Already in a group: moving ends that one, which is worth one question.
        let alert = UIAlertController(title: "\(hostName)のグループに移りますか？",
                                      message: current.isHost ? "いまのあなたのグループは終了します。"
                                                              : "いまの\(current.hostName)のグループから抜けます。",
                                      preferredStyle: .alert)
        // Opening a link at launch presents this before viewDidAppear, so the
        // resume prompt for the group already on this phone has to be asked after.
        alert.addAction(UIAlertAction(title: "やめる", style: .cancel) { [weak self] _ in
            self?.askToResumeIfNeeded()
        })
        alert.addAction(UIAlertAction(title: "移る", style: .default) { [weak self] _ in
            self?.joinGroup(id: id, hostKey: hostKey, hostName: hostName, expires: expires, token: token)
        })
        presentOnTop(alert)
    }

    private func joinGroup(id: String, hostKey: String, hostName: String, expires: Date, token: String?) {
        if group != nil { finishMeet() }
        let key = GroupKey.loadOrCreate(groupID: id, expires: expires)
        signingKey = key
        group = TodayGroup(id: id, hostKey: hostKey, hostName: hostName, expires: expires,
                           myMember: key.publicKey.rawRepresentation.base64URL, approved: [],
                           inviteToken: token)
        awaitingApproval = false
        resumePending = false
        finderNotice = "\(hostName)には「\(Self.myDisplayName)」と表示されます"
        saveTodayGroup()
        resetSession()
        if supportsUWB { startup() }
        refreshDials()
        impactGenerator.impactOccurred()
    }

    /// Where someone without the app gets it: the public TestFlight link once there
    /// is one, the App Store page after release. Until then the invitation says
    /// nothing it cannot deliver.
    private static let installURL: URL? = nil

    /// Starts today's group if there is none, then shares the link. Only the host
    /// invites, and every newcomer still has to be approved on this phone.
    @objc private func callPartnerTapped() {
        // Intake closed after too many refusals: the old link has reached the wrong
        // people, so the button starts a new group with a new link instead.
        if let current = group, current.isHost, current.refusals >= Self.maxRefusals {
            finishMeet()
        }
        if group == nil {
            let secret = SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) }.base64URL
            let key = GroupKey.create(groupID: secret, expires: shareExpiry())
            let me = key.publicKey.rawRepresentation.base64URL
            signingKey = key
            group = TodayGroup(id: secret, hostKey: me, hostName: Self.myDisplayName,
                               expires: shareExpiry(), myMember: me, approved: [me],
                               names: [me: Self.myDisplayName])
            finderNotice = nil
            saveTodayGroup()
            resetSession()
            if supportsUWB { startup() }
            refreshDials()
        }
        guard let url = inviteURL() else { return }
        var lines = ["「ここだよ」で合流しましょう。このリンクを開くと、\(Self.myDisplayName)との距離が見えるようになります（\(group.map { untilText($0.expires) } ?? "今日")）。"]
        if let install = Self.installURL {
            lines.append("まだ入れていない場合:\n\(install.absoluteString)")
        }
        lines.append("アプリが入っている場合は、ここから開けます:\n\(url.absoluteString)")
        let sheet = UIActivityViewController(activityItems: [lines.joined(separator: "\n\n")], applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = inviteButton
        sheet.popoverPresentationController?.sourceRect = inviteButton.bounds
        presentOnTop(sheet)
    }

    /// The waiting side's sheet is itself presented from here, so presenting
    /// anything else from self is refused ("already presenting") and the tap
    /// does nothing. Present from whatever is on top instead.
    private func presentOnTop(_ controller: UIViewController) {
        var top: UIViewController = self
        while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
        top.present(controller, animated: true)
    }

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
        let welcome = WelcomeViewController()
        welcome.modalPresentationStyle = .pageSheet
        welcome.onDone = { [weak self] name in
            UserDefaults.standard.set(name, forKey: Self.displayNameKey)
            self?.restartMPCForNewName()
            // The sheet could not come up while the welcome was on screen.
            self?.showWaiterSheetIfNeeded()
        }
        present(welcome, animated: true)
    }

    /// Renaming used to be impossible after the first run. A one-field alert is
    /// what the system itself uses to rename something.
    private func renameTapped() {
        let alert = UIAlertController(title: "表示名を変更",
                                      message: "近くの相手にこの名前で表示されます。",
                                      preferredStyle: .alert)
        alert.addTextField { field in
            field.text = Self.myDisplayName
            field.clearButtonMode = .whileEditing
            field.autocorrectionType = .no
            field.returnKeyType = .done
        }
        alert.addAction(UIAlertAction(title: "キャンセル", style: .cancel))
        alert.addAction(UIAlertAction(title: "保存", style: .default) { [weak self] _ in
            let typed = (alert.textFields?.first?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !typed.isEmpty, typed != Self.myDisplayName else { return }
            UserDefaults.standard.set(typed, forKey: Self.displayNameKey)
            self?.restartMPCForNewName()
            self?.refreshDials()
        })
        presentOnTop(alert)
    }

    /// Built each time it opens, so the demo item says 見る or 終了 and greys out
    /// while a real meet-up is in progress.
    /// 「…」の中身。歩きながら押す道具なので、上に出すのは4つまで。
    /// いま相手にできること（様子・おつかい）と、見る場所（地図・カメラ）だけを上に置き、
    /// 設定はまとめて下に畳む。12行あったものを5行にした。
    private func moreMenuItems() -> [UIMenuElement] {
        var actions: [UIMenuElement] = []

        // ① いま見る場所。近いときはカメラ、遠いときは地図しか意味がない。
        if theirFix != nil {
            actions.append(UIAction(title: "地図で見る", image: UIImage(systemName: "map")) { [weak self] _ in
                self?.openMap()
            })
        }
        if activePeerID != nil, latestDistance != nil, supportsUWB {
            // Camera assistance is the only way a 16 Pro gives a direction
            // (supportsDirectionMeasurement=false).
            actions.append(UIAction(title: "カメラで見る", image: UIImage(systemName: "camera.viewfinder")) { [weak self] _ in
                self?.startGuidance()
            })
        }

        // ② いま相手にできること。
        if group != nil {
            let mood = UIAction(title: "いまの様子を伝える", image: UIImage(systemName: "text.bubble")) { [weak self] _ in
                self?.askMood()
            }
            mood.subtitle = myMood ?? "相手の地図に一言で出ます"
            actions.append(mood)
        }
        if group != nil, myErrand == nil {
            // 店が見つかっていなくても頼めるようにしておく（小さな店は地図に無いことがある）。
            let errand = UIAction(title: sentErrand == nil ? "おつかいを頼む" : "頼んだリストを見る",
                                  image: UIImage(systemName: "cart")) { [weak self] _ in
                self?.errandTapped()
            }
            errand.subtitle = peerStore.map { "\(partnerName)は\($0.name)のそば" } ?? "店は見つかっていません"
            actions.append(errand)
        }

        actions.append(UIMenu(title: "設定", image: UIImage(systemName: "gearshape"),
                              children: settingsMenuItems()))
        return actions
    }

    /// 設定。一度決めたら当分さわらないものだけ。
    private func settingsMenuItems() -> [UIMenuElement] {
        let rename = UIAction(title: "表示名を変更", image: UIImage(systemName: "person.crop.circle")) { [weak self] _ in
            self?.renameTapped()
        }
        rename.subtitle = Self.myDisplayName
        // A new name rebuilds every connection, which would end a meet-up in progress.
        if requestSent || activeRequest != nil { rename.attributes = .disabled }

        let haptics = UIAction(title: hapticsOn ? "振動を止める" : "振動を使う",
                               image: UIImage(systemName: hapticsOn ? "iphone.slash" : "iphone.radiowaves.left.and.right")) { [weak self] _ in
            guard let self else { return }
            self.hapticsOn = !self.hapticsOn
            if !self.hapticsOn { self.stopProximityFeedback() }
        }
        haptics.subtitle = "近づくほど速くなります"

        // 近くにいたら知らせる。距離は街の広さで変わるので本人が決める。
        let toggle = UIAction(title: NearbyAlert.isOn ? "知らせを止める" : "知らせを使う",
                              image: UIImage(systemName: NearbyAlert.isOn ? "bell.slash" : "bell")) { [weak self] _ in
            NearbyAlert.isOn.toggle()
            if NearbyAlert.isOn { NearbyAlert.ask() } else { self?.approach.reset() }
        }
        let distances = NearbyAlert.choices.map { metres in
            let action = UIAction(title: NearbyAlert.text(metres)) { [weak self] _ in
                NearbyAlert.metres = metres
                self?.approach.reset()
            }
            action.state = NearbyAlert.metres == metres ? .on : .off
            return action
        }
        let background = UIAction(title: "画面を閉じていても知らせる",
                                  image: UIImage(systemName: "iphone.gen3.slash")) { [weak self] _ in
            NearbyAlert.runsInBackground.toggle()
            self?.locations.applyBackground()
        }
        background.state = NearbyAlert.runsInBackground ? .on : .off
        background.subtitle = "位置を背景で使います（電池を使います）"
        let nearMenu = UIMenu(title: "近くにいたら知らせる（\(NearbyAlert.text(NearbyAlert.metres))）",
                              image: UIImage(systemName: "bell.badge"),
                              children: [toggle, background,
                                         UIMenu(title: "知らせる距離", options: .displayInline, children: distances)])

        // 共有の期限。いまのグループがあればその場で変わり、無ければ次のリンクから。
        let limits = Self.limitChoices.map { choice in
            let action = UIAction(title: choice.label) { [weak self] _ in self?.setShareLimit(choice.seconds) }
            action.state = shareLimit == choice.seconds ? .on : .off
            return action
        }
        let limitMenu = UIMenu(title: "共有の期限（\(shareLimitShort)）",
                               image: UIImage(systemName: "clock"),
                               children: limits)

        var items: [UIMenuElement] = [rename, haptics, nearMenu, limitMenu]

        // ホストだけができる、相手への伝え方2つ。頻度が低いのでここに置く。
        if let current = group, current.isHost {
            let spot = UIAction(title: "いる場所を伝える", image: UIImage(systemName: "mappin.and.ellipse")) { [weak self] _ in
                self?.askSpot()
            }
            spot.subtitle = current.spot ?? "相手の画面に一言で出ます"
            let card = UIAction(title: "場所を画像で送る", image: UIImage(systemName: "photo")) { [weak self] _ in
                self?.shareSpotCard()
            }
            card.subtitle = "アプリがない人にも"
            items.append(contentsOf: [spot, card])
        }

        let demo = UIAction(title: isDemo ? "デモを終了" : "デモを見る",
                            image: UIImage(systemName: isDemo ? "stop.circle" : "play.circle")) { [weak self] _ in
            self?.demoTapped()
        }
        if !demoAllowed { demo.attributes = .disabled }
        items.append(demo)

        // One person at a time, without ending it for everyone.
        if let current = group {
            // Everyone on the list, not just whoever is in range right now: the
            // person a host most wants out is often the one who has walked off.
            let people = current.approved.filter { $0 != current.myMember }.map { member in
                UIAction(title: "\(name(ofMember: member))（\(Badge.of(member))）",
                         image: UIImage(systemName: "person.crop.circle.badge.minus"),
                         attributes: .destructive) { [weak self] _ in self?.stopSharing(with: member) }
            }
            if !people.isEmpty {
                items.append(UIMenu(title: current.isHost ? "グループから外す" : "この人との共有をやめる",
                                    image: UIImage(systemName: "person.crop.circle.badge.minus"),
                                    children: people))
            }
        }

        #if DEBUG
        // 確認用: 電波（UWB）が届かない状況をその場で作る。屋外の実測前に地図側を試すため。
        let noRadio = UIAction(title: previewNoRadio ? "電波を使う（試験）" : "電波を無いことにする（試験）",
                               image: UIImage(systemName: previewNoRadio ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")) { [weak self] _ in
            guard let self else { return }
            self.previewNoRadio.toggle()
            if self.previewNoRadio { self.latestDistance = nil; self.latestDirection = nil; self.latestWorldTransform = nil }
            self.refreshDials()
        }
        // 確認用: 2台目が無くても、頼む画面と届いた画面を通しで見る。
        let tryErrand = UIAction(title: "おつかいを試す（試験）",
                                 image: UIImage(systemName: "cart.badge.plus")) { [weak self] _ in
            guard let self else { return }
            if self.peerStore == nil {
                self.peerStore = NearbyStore.Found(name: "ライフ 西新宿店", metres: 40)
                self.refreshDials()
            }
            let vc = ErrandComposeViewController(partner: self.partnerName,
                                                 place: self.peerStore?.name ?? "") { [weak self] chosen in
                guard let self else { return }
                let errand = ErrandMessage(id: UUID().uuidString, from: self.partnerName,
                                           place: self.peerStore?.name ?? "", items: chosen)
                guard let data = try? JSONEncoder().encode(errand),
                      let back = try? JSONDecoder().decode(ErrandMessage.self, from: data) else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.receive(errand: back) }
            }
            if let sheet = vc.sheetPresentationController {
                sheet.detents = [.medium(), .large()]
                sheet.prefersGrabberVisible = true
            }
            self.presentOnTop(vc)
        }
        items.append(UIMenu(title: "試験", options: .displayInline, children: [noRadio, tryErrand]))
        #endif
        return items
    }

    /// MCPeerID is fixed when the session is built, so a new name needs a new one.
    private func restartMPCForNewName() {
        guard supportsUWB else { return }
        resetSession()
        startup()
        refreshPeerList()
    }

    // MARK: - Today's group

    private static var groupFileURL: URL? {
        guard var dir = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                     appropriateFor: nil, create: true) else { return nil }
        dir.appendPathComponent("todayGroup.json")
        return dir
    }

    /// A group survives a relaunch only until four in the morning, and never starts
    /// broadcasting on its own: the next launch asks first.
    private func loadTodayGroup() {
        // Earlier builds kept one key for every group, and the group, in
        // UserDefaults. Neither is used any more.
        UserDefaults.standard.removeObject(forKey: "kokodayo.identityKey")
        UserDefaults.standard.removeObject(forKey: Self.groupKey)
        GroupKey.purgeExpired()
        guard let url = Self.groupFileURL, let data = try? Data(contentsOf: url),
              let saved = try? JSONDecoder().decode(TodayGroup.self, from: data) else { return }
        guard saved.expires > Date(), saved.expires <= Self.maxExpiry(),
              let key = GroupKey.load(groupID: saved.id) else {
            GroupKey.delete(groupID: saved.id)
            try? FileManager.default.removeItem(at: url)
            return
        }
        group = saved
        signingKey = key
        resumePending = true
        scheduleExpiry()
    }

    /// Kept out of backups, and unreadable while the phone is locked.
    private func saveTodayGroup() {
        // グループがあるあいだは、遠いときの層も生かしておく（中身は電波が切れたときだけ流れる）
        if group != nil { startRemote() } else { stopRemote() }
        if let url = Self.groupFileURL {
            if let group, let data = try? JSONEncoder().encode(group) {
                try? data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                var target = url
                try? target.setResourceValues(values)
            } else {
                try? FileManager.default.removeItem(at: url)
            }
        }
        scheduleExpiry()
    }

    private func scheduleExpiry() {
        expiryTimer?.invalidate()
        expiryTimer = nil
        guard let group else { return }
        let timer = Timer(fire: group.expires, interval: 0, repeats: false) { [weak self] _ in
            self?.expireGroup()
        }
        RunLoop.main.add(timer, forMode: .common)
        expiryTimer = timer
    }

    private func expireGroup() {
        guard let group, group.expires <= Date() else { return }
        leaveTodayGroup()
        GroupKey.purgeExpired()
        finderNotice = "今日のグループは期限切れで終了しました"
        refreshDials()
    }

    /// Timers stop in the background, so the expiry is checked on the way back.
    @objc private func appWillEnterForeground() {
        expireGroup()
        refreshDials()
        askToResumeIfNeeded()
    }

    /// A group restored after a relaunch does not start by itself.
    private func askToResumeIfNeeded() {
        guard resumePending, let current = group, presentedViewController == nil else { return }
        resumePending = false
        let others = current.approved.filter { $0 != current.myMember }.compactMap { current.names[$0] }
        let whose = current.isHost ? "あなたのグループ" : "\(current.hostName)のグループ"
        let alert = UIAlertController(title: "\(whose)を再開しますか？",
                                      message: (others.isEmpty ? "" : "許可済み: \(others.joined(separator: "、"))\n")
                                        + "再開すると、許可済みの人に距離が\(untilText(current.expires))見えます。",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "終了", style: .destructive) { [weak self] _ in
            self?.finishMeet()
        })
        alert.addAction(UIAlertAction(title: "再開", style: .default) { [weak self] _ in
            guard let self, self.supportsUWB else { return }
            self.startup()
            self.refreshDials()
        })
        present(alert, animated: true)
    }

    /// Four in the morning, so a late night still counts as today.
    // MARK: - 共有の期限

    private static let limitKey = "kokodayo.limit"
    /// 選べる長さ。0 は「今日中（朝4時まで）」。
    /// 上限を24時間にしているのは、これが待ち合わせの道具で、見守りの道具ではないから。
    static let limitChoices: [(label: String, seconds: TimeInterval)] = [
        ("1時間", 3600), ("3時間", 3 * 3600), ("今日中（朝4時まで）", 0), ("24時間", 24 * 3600),
    ]

    /// いま選ばれている長さ。既定は今日中（これまでと同じ）。
    private var shareLimit: TimeInterval {
        get { UserDefaults.standard.object(forKey: Self.limitKey) as? TimeInterval ?? 0 }
        set { UserDefaults.standard.set(newValue, forKey: Self.limitKey) }
    }

    private var shareLimitLabel: String {
        Self.limitChoices.first { $0.seconds == shareLimit }?.label ?? "今日中（朝4時まで）"
    }

    /// メニューの見出し用。括弧が二重にならないよう短い方を使う。
    private var shareLimitShort: String {
        shareLimit > 0 ? shareLimitLabel : "今日中"
    }

    /// これから作るグループの期限。
    private func shareExpiry() -> Date {
        shareLimit > 0 ? Date().addingTimeInterval(shareLimit) : Self.endOfToday()
    }

    /// どれだけ長くしても、ここは越えない。リンクが何と言っていても切り落とす。
    static func maxExpiry() -> Date { Date().addingTimeInterval(24 * 3600) }

    private static func endOfToday() -> Date {
        let calendar = Calendar.current
        var next = calendar.date(bySettingHour: 4, minute: 0, second: 0, of: Date()) ?? Date().addingTimeInterval(12 * 3600)
        if next <= Date() { next = calendar.date(byAdding: .day, value: 1, to: next) ?? next }
        return next
    }

    private func untilText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "H:mm"
        // 24時間を選べるようになったので、今日の4時なのか明日の4時なのかを書き分ける。
        let day = Calendar.current.isDateInTomorrow(date) ? "明日の" : ""
        return "\(day)\(formatter.string(from: date))まで"
    }

    /// 覚えた相手のボタン。グループに入っていないときだけ出す。
    /// 押すと、その相手とのグループをその場で作る。リンクは送らない
    /// （部屋の名前は2人の鍵から計算するので、相手の端末でも同じ部屋になる）。
    private func refreshFriends() {
        friendsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        // 🚧 まだ出さない。いまの鍵はグループごとに作り直されるので、相手の鍵も毎回変わり、
        // 「覚えた相手」と次に同じ部屋を計算できない。端末ごとに変わらない身元（長期の鍵）を
        // 持ち、つないだときに交換する仕組みを入れてから出す。
        // 押しても相手に届かないボタンを置くのが、いちばんまずい。
        friendsStack.isHidden = true
        if true { return }
        guard group == nil else { friendsStack.isHidden = true; return }
        let friends = KnownFriends.all().prefix(3)
        friendsStack.isHidden = friends.isEmpty
        for friend in friends {
            let button = UIButton(type: .system)
            var conf = UIButton.Configuration.filled()
            conf.title = "\(friend.name) に つなぐ"
            conf.subtitle = "リンクは要りません"
            conf.baseBackgroundColor = MeetPalette.surface
            conf.baseForegroundColor = MeetPalette.primary
            conf.cornerStyle = .capsule
            conf.contentInsets = .init(top: 14, leading: 20, bottom: 14, trailing: 20)
            button.configuration = conf
            button.contentHorizontalAlignment = .leading
            button.addAction(UIAction { [weak self] _ in self?.connectToFriend(friend) }, for: .touchUpInside)
            respondOnPress(button)
            friendsStack.addArrangedSubview(button)
        }
    }

    /// 覚えた相手と、その場でつなぎ直す。
    private func connectToFriend(_ friend: KnownFriend) {
        guard group == nil else { return }
        let key = GroupKey.create(groupID: friend.key, expires: shareExpiry())
        let me = key.publicKey.rawRepresentation.base64URL
        signingKey = key
        group = TodayGroup(id: KnownFriends.pairSecret(mine: me, theirs: friend.key),
                           hostKey: me, hostName: Self.myDisplayName,
                           expires: shareExpiry(), myMember: me,
                           approved: [me, friend.key],
                           names: [me: Self.myDisplayName, friend.key: friend.name])
        finderNotice = "\(friend.name)とつなぎました。相手がアプリを開くと居場所が出ます"
        saveTodayGroup()
        resetSession()
        if supportsUWB { startup() }
        refreshDials()
    }

    /// 相手が遠いあいだの居場所のやりとりを始める。
    /// 電波（UWB）が効いている間は送らない。届かなくなった時だけ流れる。
    private func startRemote() {
        guard let group, remote == nil else { return }
        // 覚えている相手とだけのグループなら、部屋名は2人の鍵から作る。
        // こうすると、次からはリンクを送らなくても同じ部屋で会える。
        let partners = group.approved.filter { $0 != group.myMember }
        let known = KnownFriends.all().map(\.key)
        let seed: String
        if partners.count == 1, known.contains(partners[0]) {
            seed = KnownFriends.pairSecret(mine: group.myMember, theirs: partners[0])
        } else {
            seed = group.id
        }
        let channel = RemoteChannel(groupID: seed)
        channel.onFix = { [weak self] fix in
            guard let self else { return }
            self.theirFix = fix
            self.checkPeerStore()
            self.updateNearbyAlert()
            self.refreshDials()
            self.pushToMap()
        }
        // 離れているあいだ、おつかいのやりとりが通る唯一の道。
        channel.onNote = { [weak self] data in self?.handleNote(data) }
        NearbyAlert.ask()
        // つないだ直後に一度伝える（相手の地図に名前だけが並ばないように）。
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.sendMood() }
        channel.connect()
        remote = channel
        locations.onFix = { [weak self] _ in
            self?.pushLocationIfFar()
            self?.pushToMap()
            // 相手が止まっていても、自分が歩けば距離は縮む。こちらの動きでも見直す。
            self?.updateNearbyAlert()
        }
        locations.start()
        // 立ち止まっていても相手の画面が止まらないよう、定期的にも送る
        remotePush = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            self?.pushLocationIfFar()
        }
    }

    private func stopRemote() {
        remotePush?.invalidate(); remotePush = nil
        locations.stop()
        remote?.disconnect()
        remote = nil
        theirFix = nil
    }

    /// 居場所を送る。電波が効いているあいだはゆっくり（10秒に1回）だけ送る。
    /// 完全に止めると、電波の値が現実と食い違っていても気づけない
    /// （シミュレータで実際に起きた: 6km離れているのに電波は0.04mを返し続けた）。
    private var lastSlowPush = CFTimeInterval(0)
    private func pushLocationIfFar() {
        guard let l = locations.last, let channel = remote else { return }
        let radioFresh = latestDistance != nil && CACurrentMediaTime() - lastDistanceAt < 3
        if radioFresh {
            guard CACurrentMediaTime() - lastSlowPush > 10 else { return }
            lastSlowPush = CACurrentMediaTime()
        }
        channel.send(l)
    }

    @objc private func openMap() {
        let who = activePeerID.map { self.name(of: $0) } ?? (group?.hostName ?? "相手")
        let vc = MeetMapViewController(peerName: who, myName: Self.myDisplayName)
        vc.modalPresentationStyle = .fullScreen
        mapScreen = vc
        present(vc, animated: true) { [weak self] in self?.pushToMap() }
    }

    /// 地図の画面に、いまの見立てを渡す。電波が届けばそちらの距離を使う。
    private func pushToMap() {
        guard let vc = mapScreen else { return }
        let radio = radioIsFresh() ? latestDistance.map { Double($0) } : nil   // 食い違えば地図を採る
        let map = mapDistance()
        vc.update(peerAt: theirFix?.coordinate,
                  meAt: locations.last,
                  metres: radio ?? map?.meters,
                  accuracy: map?.accuracy,
                  byRadio: radio != nil,
                  peerMood: peerMood,
                  myMood: myMood)
    }

    /// 電波が無いときの、地図での距離。
    private func mapDistance() -> (meters: Double, accuracy: Double)? {
        guard let mine = locations.last, let fix = theirFix, fix.age < 90 else { return nil }
        let other = CLLocation(latitude: fix.lat, longitude: fix.lon)
        return (mine.distance(from: other), max(mine.horizontalAccuracy, fix.acc))
    }

    // MARK: - おつかい（相手が店のそばにいるあいだ）

    /// いま向き合っている相手の名前。1対1のときに「相手」と出さないためのもの。
    private var partnerName: String {
        if let id = activePeerID { return name(of: id) }
        if let current = group {
            if !current.isHost { return current.hostName }
            if let other = current.approved.first(where: { $0 != current.myMember }) {
                return name(ofMember: other)
            }
        }
        return "相手"
    }

    /// 相手の居場所のまわりに店があるかを見る。
    /// 地図の検索はApple側で回数が限られているので、相手が80m動いたか90秒たった時だけ。
    private func checkPeerStore() {
        guard group != nil, let fix = theirFix, fix.age < 120 else { return }
        let moved = storeCheckedFrom.map {
            CLLocation(latitude: $0.latitude, longitude: $0.longitude)
                .distance(from: CLLocation(latitude: fix.lat, longitude: fix.lon))
        } ?? .greatestFiniteMagnitude
        guard moved > 80 || Date().timeIntervalSince(storeCheckedAt) > 90 else { return }
        storeCheckedAt = Date()
        storeCheckedFrom = fix.coordinate
        NearbyStore.around(fix.coordinate) { [weak self] found in
            guard let self else { return }
            let before = self.peerStore?.name
            self.peerStore = found
            // 店が変わった時だけ一言。同じ店で何度も言わない。
            if let found, found.name != before, self.sentErrand == nil, self.myErrand == nil {
                self.flash("\(self.partnerName)は\(found.name)のそばにいます")
            }
            self.refreshDials()
        }
    }

    /// おつかいのボタンは、用があるときだけ出す。
    /// ①頼まれている ②頼んでいる ③相手が店のそば — それ以外は画面から消す。
    private func refreshErrandButton() {
        let title: String?
        // 店名は地図から来るので長い（「HANAGATAYA 東京中央 ドラえもん…」）。
        // 1行目は何をするかだけにして、店名は下の小さい行に置く。
        var subtitle: String?
        let image: String
        if let errand = myErrand {
            let left = errand.items.count - myErrandGot.count
            title = left > 0 ? "おつかいリスト" : "おつかいを終わりにする"
            subtitle = left > 0 ? "残り\(left)個・\(errand.placeText)" : errand.placeText
            image = "list.bullet"
        } else if let sent = sentErrand {
            title = "頼み中"
            subtitle = "\(sentErrandGot.count)/\(sent.items.count)個 買えました"
            image = "cart"
        } else if let store = peerStore, group != nil {
            title = "おつかいを頼む"
            subtitle = store.name
            image = "cart.fill"
        } else {
            title = nil
            image = "cart.fill"
        }
        errandButton.isHidden = title == nil
        guard let title else { return }
        errandButton.configuration?.title = title
        errandButton.configuration?.subtitle = subtitle
        errandButton.configuration?.image = UIImage(systemName: image)
    }

    /// 輪の中が「まわりを見る」になっているか。距離を地図で見ているあいだだけ。
    @objc private func dialTapped() {
        guard dialExplores else { return }
        impactGenerator.impactOccurred()
        let vc = ExploreViewController(centre: locations.last?.coordinate)
        if let sheet = vc.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        presentOnTop(vc)
    }

    /// 地図⇄カメラ。同じ場所のボタンを押すだけで行き来する。
    @objc private func switchTapped() {
        impactGenerator.impactOccurred()
        startGuidance()
    }

    @objc private func errandTapped() {
        // 頼まれている側なら、開くのは届いたリスト。
        if myErrand != nil { openErrandList(); return }
        if let sent = sentErrand {
            let left = sent.items.filter { !sentErrandGot.contains($0) }
            flash(left.isEmpty ? "\(partnerName)は全部買いました"
                               : "\(partnerName)に頼み中: \(left.joined(separator: "、"))")
            return
        }
        askErrand()
    }

    /// 頼む物を選ぶ画面を出す。
    private func askErrand() {
        guard group != nil else { return }
        let vc = ErrandComposeViewController(partner: partnerName,
                                             place: peerStore?.name ?? "") { [weak self] items in
            self?.sendErrand(items: items)
        }
        if let sheet = vc.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        presentOnTop(vc)
    }

    private func sendErrand(items: [String]) {
        guard !items.isEmpty else { return }
        let errand = ErrandMessage(id: UUID().uuidString,
                                   from: Self.myDisplayName,
                                   place: peerStore?.name ?? "",
                                   items: items)
        sentErrand = errand
        sentErrandGot = []
        errandResends = 0
        pushErrand()
        // 中継は投げっぱなしで、相手のアプリが閉じていれば消える。返事が来るまで
        // 20秒おきに数回だけ送り直す（それ以上は鳴らしすぎになる）。
        errandResend?.invalidate()
        errandResend = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] timer in
            guard let self, self.sentErrand != nil, self.errandResends < 5 else {
                timer.invalidate()
                self?.errandResend = nil
                return
            }
            self.errandResends += 1
            self.pushErrand()
        }
        impactGenerator.impactOccurred()
        flash("\(partnerName)に頼みました: \(items.joined(separator: "、"))")
        refreshDials()
    }

    private func pushErrand() {
        guard let errand = sentErrand, let data = try? JSONEncoder().encode(errand) else { return }
        sendToPartner(data)
    }

    /// 近いときはMPC、遠いときは中継。どちらが効いているかを人に選ばせない。
    private func sendToPartner(_ data: Data) {
        let peers = groupPeers.filter { links[$0]?.isDemo != true }
        if !peers.isEmpty { mpc?.sendData(data: data, peers: peers, mode: .reliable) }
        remote?.send(note: data)
    }

    /// 便りの入口。MPCから来ても中継から来ても、ここに集める。
    private func handleNote(_ data: Data) {
        guard let kind = try? JSONDecoder().decode(MessageKind.self, from: data) else { return }
        switch kind.type {
        case "ping":
            // 中継から来た合図。部屋の鍵を持っている人しか入れないので、名乗りは要らない。
            guard group != nil else { return }
            receivePing(from: partnerName)
        case "mood":
            guard group != nil, let mood = try? JSONDecoder().decode(MoodMessage.self, from: data) else { return }
            let text = cleanName(mood.text)
            guard text != peerMood else { return }
            peerMood = text.isEmpty ? nil : text
            if let peerMood { flash("\(partnerName): \(peerMood)") }
            pushToMap()
            refreshDials()
        case "errand":
            guard group != nil, let errand = try? JSONDecoder().decode(ErrandMessage.self, from: data) else { return }
            receive(errand: errand)
        case "errandStatus":
            guard let status = try? JSONDecoder().decode(ErrandStatusMessage.self, from: data),
                  let sent = sentErrand, status.id == sent.id else { return }
            // 返事が来た＝届いた。送り直しはここで止める。
            errandResend?.invalidate()
            errandResend = nil
            let added = status.got.filter { !sentErrandGot.contains($0) }
            sentErrandGot = status.got
            if status.done {
                let got = status.got.isEmpty ? "なし" : status.got.joined(separator: "、")
                flash("\(partnerName)のおつかいが終わりました（買えた物: \(got)）")
                NearbyAlert.notify(title: "おつかいが終わりました", body: "買えた物: \(got)")
                if hapticsOn { arrivalGenerator.notificationOccurred(.success) }
                sentErrand = nil
                sentErrandGot = []
            } else if !added.isEmpty {
                flash("\(partnerName)が買いました: \(added.joined(separator: "、"))")
            }
            refreshDials()
        default:
            break
        }
    }

    /// 届いたリストを受け取る。MPCと中継の両方から同じものが来るので、一度だけ。
    private func receive(errand: ErrandMessage) {
        guard !errand.items.isEmpty else { return }
        guard !seenErrands.contains(errand.id) else {
            // 届いていることは返事で伝える（相手の送り直しを止めるため）。
            if myErrand?.id == errand.id { sendErrandStatus(done: false) }
            return
        }
        seenErrands.insert(errand.id)
        myErrand = errand
        myErrandGot = []
        let list = errand.items.joined(separator: "、")
        flash("\(errand.from)からおつかい: \(list)")
        if hapticsOn { arrivalGenerator.notificationOccurred(.warning) }
        NearbyAlert.notify(title: "\(errand.from)からおつかい", body: "\(errand.placeText)で: \(list)")
        sendErrandStatus(done: false)
        refreshDials()
        if UIApplication.shared.applicationState == .active { openErrandList() }
    }

    /// 合図を受けた。近くなら「顔を上げて」、遠いなら「気づいたよ」。
    /// 同じ一押しで、言い方だけが距離で変わる。
    private func receivePing(from who: String) {
        // 同じ合図が電波と中継の両方から届く（実測で80ms差）。鳴らすのは一度だけ。
        guard CACurrentMediaTime() - lastPingAt > 3 else { return }
        lastPingAt = CACurrentMediaTime()
        pingFrom = who
        pingUntil = CACurrentMediaTime() + 8
        let near = radioIsFresh()
        let metres = currentMetres()
        let far = metres.map { "あと\(NearbyAlert.text($0))" }
        flash(near ? "\(who)が合図しています" : "\(who)が合図しています\(far.map { "（\($0)）" } ?? "")")
        // Three heavy taps, unmistakably not the beat.
        let heavy = UIImpactFeedbackGenerator(style: .heavy)
        heavy.prepare()
        for i in 0..<3 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.14 * Double(i)) { heavy.impactOccurred() }
        }
        // 画面を閉じていても届く。押し返せるように、合図のボタンも付ける。
        let body: String
        if near {
            body = "周りを見てください"
        } else if let metres, let far {
            body = "\(far)・\(NearbyAlert.walkText(metres))"
        } else {
            body = "近くにいます"
        }
        NearbyAlert.notify(title: "\(who)が合図しています", body: body, withPing: true)
        refreshDials()
        DispatchQueue.main.asyncAfter(deadline: .now() + 8.1) { [weak self] in self?.refreshDials() }
    }

    /// 知らせの中の「合図する」。アプリが開き切ってから、いつもの合図を送る。
    @objc private func pingFromNotification() {
        guard NearbyAlert.pendingPing else { return }
        NearbyAlert.pendingPing = false
        pingTapped()
    }

    private func openErrandList() {
        guard let errand = myErrand else { return }
        let vc = ErrandListViewController(errand: errand, got: myErrandGot) { [weak self] got, done in
            guard let self else { return }
            self.myErrandGot = got
            self.sendErrandStatus(done: done)
            if done {
                self.myErrand = nil
                self.myErrandGot = []
                self.flash("おつかいを終わりにしました")
            }
            self.refreshDials()
        }
        if let sheet = vc.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        presentOnTop(vc)
    }

    private func sendErrandStatus(done: Bool) {
        guard let errand = myErrand,
              let data = try? JSONEncoder().encode(ErrandStatusMessage(id: errand.id,
                                                                      got: myErrandGot,
                                                                      done: done)) else { return }
        sendToPartner(data)
    }

    /// 期限を選ぶ。いまのグループを持っている側（ホスト）なら、その場で変える。
    /// 相手には署名つきの名簿（welcome）で伝わる。
    private func setShareLimit(_ seconds: TimeInterval) {
        shareLimit = seconds
        guard var current = group, current.isHost else {
            flash("次に送るリンクから\(shareLimitLabel)になります")
            return
        }
        let wanted = shareExpiry()
        current.expires = wanted
        current.version += 1
        group = current
        GroupKey.setExpiry(groupID: current.id, expires: wanted)
        saveTodayGroup()
        sendWelcome(to: approvedPeers)
        flash("共有を\(untilText(wanted))にしました")
        refreshDials()
    }

    // MARK: - いまの様子（一言）

    private static let moodPresets = ["のんびり進みます", "急いでいます", "おつかい中", "道に迷いました", "もうすぐ着きます", "少し遅れます"]

    /// 自分の様子を一言で伝える。選ぶだけで終われるようにする。
    private func askMood() {
        let sheet = UIAlertController(title: "いまの様子を伝える",
                                      message: myMood.map { "いま「\($0)」と伝えています" },
                                      preferredStyle: .actionSheet)
        for preset in Self.moodPresets {
            sheet.addAction(UIAlertAction(title: preset, style: .default) { [weak self] _ in self?.setMood(preset) })
        }
        sheet.addAction(UIAlertAction(title: "ほかの言葉…", style: .default) { [weak self] _ in
            let alert = UIAlertController(title: "いまの様子", message: "相手の地図に、名前の下に出ます", preferredStyle: .alert)
            alert.addTextField { $0.placeholder = "例: 資格勉強"; $0.text = self?.myMood }
            alert.addAction(UIAlertAction(title: "やめる", style: .cancel))
            alert.addAction(UIAlertAction(title: "伝える", style: .default) { [weak self] _ in
                self?.setMood(alert.textFields?.first?.text ?? "")
            })
            self?.presentOnTop(alert)
        })
        if myMood != nil {
            sheet.addAction(UIAlertAction(title: "消す", style: .destructive) { [weak self] _ in self?.setMood("") })
        }
        sheet.addAction(UIAlertAction(title: "やめる", style: .cancel))
        sheet.popoverPresentationController?.sourceView = demoButton
        sheet.popoverPresentationController?.sourceRect = demoButton.bounds
        presentOnTop(sheet)
    }

    private func setMood(_ text: String) {
        let clean = cleanName(text)
        myMood = clean.isEmpty ? nil : clean
        sendMood()
        pushToMap()
        flash(myMood.map { "「\($0)」と伝えています" } ?? "様子を消しました")
        refreshDials()
    }

    /// つながった時にも送る。相手の画面は、こちらが黙っていれば何も出ない。
    private func sendMood() {
        guard group != nil, let data = try? JSONEncoder().encode(MoodMessage(text: myMood ?? "")) else { return }
        sendToPartner(data)
    }

    private func clearErrands() {
        errandResend?.invalidate()
        errandResend = nil
        sentErrand = nil
        sentErrandGot = []
        myErrand = nil
        myErrandGot = []
        seenErrands.removeAll()
        peerStore = nil
        storeCheckedFrom = nil
        storeCheckedAt = .distantPast
        approach.reset()
    }

    // MARK: - 「近くにいるよ」

    /// いま分かっている距離。電波が新しければ電波、無ければ地図。
    private func currentMetres() -> Double? {
        if radioIsFresh(), let d = latestDistance { return Double(d) }
        return mapDistance()?.meters
    }

    /// 決めた距離まで近づいた一度だけ知らせる。画面を見ていれば文字と振動、
    /// 見ていなければ通知。同じことを二重に出さない。
    private func updateNearbyAlert() {
        guard NearbyAlert.isOn, group != nil, let metres = currentMetres() else { return }
        guard approach.step(metres: metres, threshold: NearbyAlert.metres) else { return }
        let who = partnerName
        let far = NearbyAlert.text(metres)
        flash("\(who)が近くにいます（あと\(far)）")
        if hapticsOn { arrivalGenerator.notificationOccurred(.success) }
        NearbyAlert.notify(title: "\(who)が近くにいます",
                           body: "あと\(far)・\(NearbyAlert.walkText(metres))", withPing: true)
    }

    private func leaveTodayGroup() {
        stopRemote()
        clearErrands()
        endLiveActivity()
        #if DEBUG
        print("RECON leaveTodayGroup id=\(group?.id.prefix(4) ?? "-") stack=\(Thread.callStackSymbols.dropFirst().prefix(4).joined(separator: " | "))")
        #endif
        group = nil
        signingKey = nil
        awaitingApproval = false
        resumePending = false
        joinQueue.removeAll()
        dismissJoinAlert()
        saveTodayGroup()
        resetSession()
        peerNames.removeAll()
        peerMembers.removeAll()
        myChallenge.removeAll()
        refreshDials()
    }

    /// The name for a member ID, whether or not that phone is in range.
    private func name(ofMember member: String) -> String {
        if let fixed = group?.names[member] { return fixed }
        if let peer = links.keys.first(where: { peerMembers[$0] == member }) { return peerNames[peer] ?? "相手" }
        return "相手"
    }

    /// The name fixed by the host's signed list first; what a phone says about
    /// itself only until then.
    private func name(of peer: MCPeerID) -> String {
        if let group, let member = peerMembers[peer] {
            if let fixed = group.names[member] { return fixed }
            if member == group.hostKey { return group.hostName }
        }
        return peerNames[peer] ?? "相手"
    }

    private func isApproved(_ member: String) -> Bool {
        guard let group else { return false }
        return group.approved.contains(member) && !group.excluded.contains(member)
    }

    private var amApproved: Bool {
        guard let group else { return false }
        return group.approved.contains(group.myMember) && group.expires > Date()
    }

    /// Every approved phone connected right now.
    private var approvedPeers: [MCPeerID] {
        links.keys.filter { peerMembers[$0].map(isApproved) == true }
    }

    private func normalized(_ text: String) -> String {
        cleanName(text).lowercased()
    }

    private func verifyHello(_ hello: HelloMessage, groupID: String, nonce: String) -> Bool {
        guard let keyData = Data(base64URL: hello.member), let signature = Data(base64URL: hello.proof),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else { return false }
        return key.isValidSignature(signature, for: Data("hello|\(groupID)|\(nonce)".utf8))
    }

    private func welcomeBody(group: String, members: [String], names: [String: String], version: Int,
                             expires: Double) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(WelcomeBody(group: group, members: members, names: names,
                                               version: version, expires: expires))
    }

    private func sendWelcome(to peers: [MCPeerID]) {
        guard let group, group.isHost, !peers.isEmpty, let key = signingKey,
              let body = welcomeBody(group: group.id, members: group.approved, names: group.names,
                                     version: group.version, expires: group.expires.timeIntervalSince1970),
              let signature = try? key.signature(for: body) else { return }
        let message = WelcomeMessage(group: group.id, members: group.approved, names: group.names,
                                     version: group.version, expires: group.expires.timeIntervalSince1970,
                                     signature: signature.base64URL)
        if let data = try? JSONEncoder().encode(message) {
            mpc?.sendData(data: data, peers: peers, mode: .reliable)
        }
        sendSpot(to: peers)
    }

    private func sendSpot(to peers: [MCPeerID]) {
        guard let group, group.isHost, !peers.isEmpty,
              let data = try? JSONEncoder().encode(SpotMessage(text: group.spot ?? "")) else { return }
        mpc?.sendData(data: data, peers: peers, mode: .reliable)
    }

    @objc private func pingTapped() {
        guard let data = try? JSONEncoder().encode(PingMessage()) else { return }
        let who = partnerName
        // 近ければ電波、遠ければ中継。どちらも無いときだけ「送れません」と言う。
        // 届いていないのに「合図しました」と出すと、相手が気づかない理由が分からない。
        let peers = groupPeers.filter { links[$0]?.isDemo != true }
        let relay = remote?.isJoined == true
        guard !peers.isEmpty || relay || isDemo else {
            flash("いまは\(who)とつながっていないので、合図を送れません")
            return
        }
        sendToPartner(data)
        impactGenerator.impactOccurred()
        flash(isDemo ? "デモ: \(who)に合図しました" : "\(who)に合図しました")
    }

    private static let spotPresets = ["改札の前", "入口", "出口", "柱のそば", "看板の下", "ベンチ"]

    /// The host says where they are, in a word. Sent to everyone approved, and
    /// to anyone approved later.
    private func askSpot(then done: (() -> Void)? = nil) {
        guard let current = group, current.isHost else { return }
        let sheet = UIAlertController(title: "いる場所を伝える",
                                      message: current.spot.map { "いま「\($0)」と伝えています" },
                                      preferredStyle: .actionSheet)
        for preset in Self.spotPresets {
            sheet.addAction(UIAlertAction(title: preset, style: .default) { [weak self] _ in
                self?.setSpot(preset); done?()
            })
        }
        sheet.addAction(UIAlertAction(title: "ほかの場所…", style: .default) { [weak self] _ in
            let alert = UIAlertController(title: "いる場所", message: "相手の画面に出ます", preferredStyle: .alert)
            alert.addTextField { $0.placeholder = "例: 北口の時計の下"; $0.text = current.spot }
            alert.addAction(UIAlertAction(title: "やめる", style: .cancel))
            alert.addAction(UIAlertAction(title: "伝える", style: .default) { [weak self] _ in
                self?.setSpot(alert.textFields?.first?.text ?? ""); done?()
            })
            self?.presentOnTop(alert)
        })
        if current.spot != nil {
            sheet.addAction(UIAlertAction(title: "消す", style: .destructive) { [weak self] _ in self?.setSpot("") })
        }
        sheet.addAction(UIAlertAction(title: "やめる", style: .cancel))
        sheet.popoverPresentationController?.sourceView = demoButton
        sheet.popoverPresentationController?.sourceRect = demoButton.bounds
        presentOnTop(sheet)
    }

    private func setSpot(_ text: String) {
        guard var current = group, current.isHost else { return }
        let clean = cleanName(text)
        current.spot = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : clean
        group = current
        saveTodayGroup()
        sendSpot(to: approvedPeers)
        refreshDials()
    }

    /// 「ここだよカード」: one image that says where you are, for the friend who
    /// does not have the app. No map, no link, no server — a picture in LINE.
    private func shareSpotCard() {
        guard let current = group, current.isHost else { return }
        guard let spot = current.spot else {
            askSpot { [weak self] in self?.shareSpotCard() }
            return
        }
        let size = CGSize(width: 1080, height: 1350)
        let image = UIGraphicsImageRenderer(size: size).image { ctx in
            MeetPalette.background.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let centre = CGPoint(x: size.width / 2, y: 560)
            // The seal, pressed.
            let ring = UIBezierPath(arcCenter: centre, radius: 300, startAngle: 0, endAngle: .pi * 2, clockwise: true)
            ring.lineWidth = 4
            MeetPalette.ink.setStroke()
            ring.stroke()
            let para = NSMutableParagraphStyle()
            para.alignment = .center
            func draw(_ text: String, size fontSize: CGFloat, weight: UIFont.Weight, colour: UIColor, y: CGFloat) {
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: fontSize, weight: weight),
                    .foregroundColor: colour, .paragraphStyle: para,
                ]
                let rect = CGRect(x: 80, y: y, width: size.width - 160, height: fontSize * 1.4)
                (text as NSString).draw(in: rect, withAttributes: attrs)
            }
            draw("ここだよ", size: 128, weight: .bold, colour: MeetPalette.primary, y: centre.y - 150)
            draw(current.hostName, size: 56, weight: .semibold, colour: MeetPalette.secondary, y: centre.y + 40)
            draw(spot, size: 96, weight: .bold, colour: MeetPalette.primary, y: 960)
            let formatter = DateFormatter()
            formatter.dateFormat = "H:mm"
            draw("\(formatter.string(from: Date())) 現在", size: 44, weight: .regular, colour: MeetPalette.ink, y: 1110)
        }
        let text = "\(current.hostName)は「\(spot)」にいます"
        let sheet = UIActivityViewController(activityItems: [image, text], applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = demoButton
        sheet.popoverPresentationController?.sourceRect = demoButton.bounds
        presentOnTop(sheet)
    }

    private func sendDissolve() {
        guard let group, group.isHost, let key = signingKey, !links.isEmpty,
              let signature = try? key.signature(for: Data("dissolve|\(group.id)".utf8)),
              let data = try? JSONEncoder().encode(DissolveMessage(group: group.id, signature: signature.base64URL)) else { return }
        mpc?.sendData(data: data, peers: Array(links.keys), mode: .reliable)
    }

    /// 一時の知らせ。下の1行を置き換えると「いま何を共有しているか」が消えるので、
    /// 浮いた面（ToastView）に出して、6秒で引っ込める。
    private func flash(_ text: String) {
        toast.show(text)
    }

    /// A newcomer holding the link still needs a yes. The prompt shows what the host
    /// needs to decide: who is already in, the phone's symbols to check against the
    /// friend, and a warning when the name is already taken.
    private static let maxRefusals = 3

    private func askNextJoin() {
        guard !askingJoin, let current = group, current.refusals < Self.maxRefusals else { return }
        while let peer = joinQueue.first {
            guard links[peer] != nil, let member = peerMembers[peer],
                  !current.approved.contains(member), !current.rejected.contains(member) else {
                joinQueue.removeFirst()
                continue
            }
            break
        }
        guard let peer = joinQueue.first, let member = peerMembers[peer] else { return }
        askingJoin = true
        let who = peerNames[peer] ?? "相手"
        let others = current.approved.filter { $0 != current.myMember }.compactMap { current.names[$0] }
        var lines: [String] = []
        let key = normalized(who)
        if normalized(current.hostName) == key || current.names.values.contains(where: { normalized($0) == key }) {
            lines.append("同じ名前「\(who)」の人がすでにいます。別人かもしれません。")
        }
        lines.append(others.isEmpty ? "許可済みの人はまだいません。" : "許可済み: \(others.joined(separator: "、"))（\(others.count)人）")
        lines.append("許可すると、このグループの全員とお互いの距離が\(untilText(current.expires))見えます。")
        lines.append("記号が本人のものか、LINEなどで確かめてください。知らない人なら許可しないでください。")
        let alert = UIAlertController(title: "\(who)（\(Badge.of(member))）が参加を希望しています",
                                      message: lines.joined(separator: "\n"), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "許可しない", style: .cancel) { [weak self] _ in
            self?.decideJoin(peer: peer, member: member, allow: false)
        })
        alert.addAction(UIAlertAction(title: "許可", style: .default) { [weak self] _ in
            self?.decideJoin(peer: peer, member: member, allow: true)
        })
        joinAlert = alert
        joinAlertPeer = peer
        presentOnTop(alert)
    }

    private func dismissJoinAlert() {
        joinAlert?.dismiss(animated: true)
        joinAlert = nil
        joinAlertPeer = nil
        askingJoin = false
    }

    private func decideJoin(peer: MCPeerID, member: String, allow: Bool) {
        joinAlert = nil
        joinAlertPeer = nil
        askingJoin = false
        joinQueue.removeAll { $0 == peer }
        guard var current = group else { return }
        if allow, links[peer] != nil {
            if !current.approved.contains(member) { current.approved.append(member) }
            current.names[member] = peerNames[peer] ?? "相手"
            current.rejected.removeAll { $0 == member }
            current.version += 1
            group = current
            saveTodayGroup()
            sendWelcome(to: approvedPeers)
            beginRanging(with: peer)
        } else {
            // Remembered for today, so the same phone cannot ask again and again.
            if !current.rejected.contains(member) { current.rejected.append(member) }
            current.refusals += 1
            group = current
            saveTodayGroup()
            if current.refusals >= Self.maxRefusals {
                joinQueue.removeAll()
                finderNotice = nil
            } else {
                finderNotice = nil
                flash("\(peerNames[peer] ?? "相手")を許可しませんでした")
            }
            if let data = try? JSONEncoder().encode(DeclineMessage()) {
                mpc?.sendData(data: data, peers: [peer], mode: .reliable)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.mpc?.disconnect(peer) }
        }
        refreshDials()
        askNextJoin()
    }

    /// Stop sharing with one person. On the host's phone that takes them out of the
    /// group for everyone; on anyone else's, it stops only this phone's side.
    private func stopSharing(with member: String) {
        guard var current = group, member != current.myMember else { return }
        if current.isHost {
            current.approved.removeAll { $0 == member }
            current.names[member] = nil
            if !current.rejected.contains(member) { current.rejected.append(member) }
            current.version += 1
        } else if !current.excluded.contains(member) {
            current.excluded.append(member)
        }
        group = current
        saveTodayGroup()
        for peer in links.keys where peerMembers[peer] == member {
            if current.isHost {
                // The signed list without them, so their phone knows it was taken
                // out and leaves, instead of waiting for a host that says no.
                sendWelcome(to: [peer])
            } else if let data = try? JSONEncoder().encode(CancelMessage()) {
                mpc?.sendData(data: data, peers: [peer], mode: .reliable)
            }
            if let link = links[peer] { restartLink(link) }
            leaveGroup(peer)
            let target = peer
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.mpc?.disconnect(target) }
        }
        if current.isHost { sendWelcome(to: approvedPeers) }
        refreshDials()
    }

    // MARK: - Nearby Interaction (extended from the Apple sample to several peers)

    /// Nothing goes on the air until there is a group: without an invitation this
    /// phone is invisible to everyone nearby.
    private func startup() {
        guard let group else {
            mpc?.invalidate()
            mpc = nil
            return
        }
        if mpc == nil {
            myPeerName = "k" + String(UUID().uuidString.prefix(8))
            let tag = SHA256.hash(data: Data("discover|\(group.id)".utf8)).prefix(8)
                .map { String(format: "%02x", $0) }.joined()
            let proof = Data(SHA256.hash(data: Data("join|\(group.id)".utf8)))
            #if targetEnvironment(simulator)
            let identity = "jp.shutanuma.kokodayo.simulator"
            #else
            let identity = "jp.shutanuma.kokodayo"
            #endif
            mpc = MPCSession(service: "kokodayo", identity: identity, maxPeers: 7,
                             displayName: myPeerName, discoveryTag: tag, joinProof: proof)
            mpc?.peerConnectedHandler = { [weak self] peer in self?.connectedToPeer(peer: peer) }
            mpc?.peerDataHandler = { [weak self] data, peer in self?.dataReceivedHandler(data: data, peer: peer) }
            mpc?.peerDisconnectedHandler = { [weak self] peer in self?.disconnectedFromPeer(peer: peer) }
        }
        mpc?.invalidate()
        mpc?.start()
    }

    private func connectedToPeer(peer: MCPeerID) {
        guard links[peer] == nil, group != nil else { return }
        // Connected is not consented. Only phones holding the invitation get this
        // far, and even then nothing about this person, name or distance, goes
        // over until the host has approved them.
        links[peer] = PeerLink(peerID: peer)
        // Ask first, answer second: the proof this phone accepts is a signature
        // over a value only this phone could have chosen for this connection.
        let nonce = SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) }.base64URL
        myChallenge[peer] = nonce
        if let data = try? JSONEncoder().encode(ChallengeMessage(nonce: nonce)) {
            mpc?.sendData(data: data, peers: [peer], mode: .reliable)
        }
        refreshDials()
    }

    private func disconnectedFromPeer(peer: MCPeerID) {
        if let session = links[peer]?.session { killSession(session) }
        links.removeValue(forKey: peer)
        myChallenge.removeValue(forKey: peer)
        if groupPeers.contains(peer) {
            if !isDemo { finderNotice = "\(name(of: peer))との接続が切れました。" }
            leaveGroup(peer)
        }
        if joinAlertPeer == peer { dismissJoinAlert() }
        if let group, !group.isHost, awaitingApproval, peerMembers[peer] == group.hostKey {
            awaitingApproval = false
            finderNotice = "\(group.hostName)との接続が切れました（まだ許可されていません）"
        }
        peerNames[peer] = nil
        peerMembers[peer] = nil
        joinQueue.removeAll { $0 == peer }
        askNextJoin()
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
        // 遠距離測距。公式には最大何mとは書かれていない（環境次第）が、
        // 入れていなければ第1世代と同じ範囲のままになる。両方の端末が対応していれば効く。
        if #available(iOS 17.0, *), NISession.deviceCapabilities.supportsExtendedDistanceMeasurement {
            config.isExtendedDistanceMeasurementEnabled = true
        }
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
        // Ending the meet-up ends the measuring. Invalidating our session sends
        // the peer .peerEnded, and nothing restarts until the next 「ここだよ」.
        // (Before 9/12 this resumed at once with a fresh token: the sharing
        // never actually stopped.)
        if let old = link.session { killSession(old) }
        link.session = nil
        link.peerToken = nil
        link.distance = nil
        link.direction = nil
        link.world = nil
        link.moving = nil
    }

    private func dataReceivedHandler(data: Data, peer: MCPeerID) {
        guard let link = links[peer] else { return }
        let active = group.map { $0.expires > Date() } ?? false

        if let token = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NIDiscoveryToken.self, from: data) {
            link.peerToken = token
            // Filed, and only used once this peer is in the group on both sides.
            if active, groupPeers.contains(peer) {
                runConfig(for: link, cameraAssist: phase == .guiding && !floorRingsOnly && peer == activePeerID)
            }
            return
        }
        guard let kind = try? JSONDecoder().decode(MessageKind.self, from: data) else { return }
        switch kind.type {
        case "challenge":
            guard let challenge = try? JSONDecoder().decode(ChallengeMessage.self, from: data),
                  let group, let key = signingKey, active, links[peer] != nil,
                  challenge.nonce.count >= 16 else { return }
            let proof = (try? key.signature(for: Data("hello|\(group.id)|\(challenge.nonce)".utf8)))?.base64URL ?? ""
            if let reply = try? JSONEncoder().encode(HelloMessage(member: group.myMember, proof: proof)) {
                mpc?.sendData(data: reply, peers: [peer], mode: .reliable)
            }
        case "hello":
            // One hello per connection: a second could swap the key under an
            // approval already given.
            guard peerMembers[peer] == nil,
                  let hello = try? JSONDecoder().decode(HelloMessage.self, from: data), let group, active,
                  let nonce = myChallenge[peer],
                  verifyHello(hello, groupID: group.id, nonce: nonce) else { return }
            if group.isHost, group.rejected.contains(hello.member) {
                if let data = try? JSONEncoder().encode(DeclineMessage()) {
                    mpc?.sendData(data: data, peers: [peer], mode: .reliable)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.mpc?.disconnect(peer) }
                return
            }
            if group.excluded.contains(hello.member) {
                mpc?.disconnect(peer)
                return
            }
            peerMembers[peer] = hello.member
            if group.isHost {
                // Someone approved earlier today is simply back in range.
                if isApproved(hello.member) {
                    sendWelcome(to: [peer])
                    beginRanging(with: peer)
                }
            } else if hello.member == group.hostKey {
                if amApproved {
                    beginRanging(with: peer)
                } else if let data = try? JSONEncoder().encode(JoinMessage(name: Self.myDisplayName,
                                                                            token: group.inviteToken)) {
                    mpc?.sendData(data: data, peers: [peer], mode: .reliable)
                    awaitingApproval = true
                }
            } else if amApproved {
                beginRanging(with: peer)
            }
            refreshDials()
        case "join":
            guard let join = try? JSONDecoder().decode(JoinMessage.self, from: data), let group, group.isHost, active,
                  let member = peerMembers[peer], !group.rejected.contains(member) else { return }
            if peerNames[peer] == nil { peerNames[peer] = cleanName(join.name) }
            if isApproved(member) {
                sendWelcome(to: [peer])
                beginRanging(with: peer)
            } else if let token = join.token, group.tokens[token] == false {
                // The link's first use: the host sent it to this person. In, and
                // the key is spent — a forwarded copy now needs the host's yes.
                var current = group
                current.tokens[token] = true
                self.group = current
                saveTodayGroup()
                decideJoin(peer: peer, member: member, allow: true)
                flash("\(peerNames[peer] ?? "相手")（\(Badge.of(member))）が参加しました")
            } else if group.refusals >= Self.maxRefusals {
                // The link has reached people the host keeps saying no to. No more
                // prompts to tap through by mistake; a new link starts a new group.
                if let data = try? JSONEncoder().encode(DeclineMessage()) {
                    mpc?.sendData(data: data, peers: [peer], mode: .reliable)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.mpc?.disconnect(peer) }
            } else {
                // A short queue, one entry per phone.
                if !joinQueue.contains(peer), joinQueue.count < 3 { joinQueue.append(peer) }
                askNextJoin()
            }
        case "welcome":
            guard let welcome = try? JSONDecoder().decode(WelcomeMessage.self, from: data),
                  var current = group, !current.isHost, active, welcome.group == current.id,
                  welcome.version >= current.version,
                  peerMembers[peer] == current.hostKey,
                  let hostKeyData = Data(base64URL: current.hostKey),
                  let signature = Data(base64URL: welcome.signature),
                  let hostKey = try? Curve25519.Signing.PublicKey(rawRepresentation: hostKeyData),
                  let body = welcomeBody(group: welcome.group, members: welcome.members,
                                         names: welcome.names, version: welcome.version,
                                         expires: welcome.expires),
                  hostKey.isValidSignature(signature, for: body)
            else { return }
            let wasApproved = current.approved.contains(current.myMember)
            let added = welcome.members.filter {
                !current.approved.contains($0) && $0 != current.myMember && $0 != current.hostKey
            }
            current.approved = welcome.members
            current.names = welcome.names.mapValues(cleanName)
            current.version = welcome.version
            // ホストが期限を変えたら合わせる。上限は同じ（24時間）。
            let told = min(Date(timeIntervalSince1970: welcome.expires), Self.maxExpiry())
            if told > Date(), abs(told.timeIntervalSince(current.expires)) > 30 {
                current.expires = told
                GroupKey.setExpiry(groupID: current.id, expires: told)
                flash("\(current.hostName)が共有を\(untilText(told))にしました")
            }
            group = current
            saveTodayGroup()
            awaitingApproval = false
            if current.approved.contains(current.myMember) {
                // Anyone no longer on the host's list stops ranging with this phone.
                for other in groupPeers where peerMembers[other].map(isApproved) != true {
                    if let otherLink = links[other] { restartLink(otherLink) }
                    leaveGroup(other)
                }
                for other in links.keys where peerMembers[other].map(isApproved) == true {
                    beginRanging(with: other)
                }
                if wasApproved, !added.isEmpty {
                    let who = added.map { "\(current.names[$0] ?? "相手")（\(Badge.of($0))）" }.joined(separator: "、")
                    flash("\(current.hostName)が\(who)を追加しました")
                }
            } else if wasApproved {
                let host = current.hostName
                leaveTodayGroup()
                finderNotice = "\(host)があなたをグループから外しました"
            }
            refreshDials()
        case "dissolve":
            guard let dissolve = try? JSONDecoder().decode(DissolveMessage.self, from: data),
                  let current = group, !current.isHost, dissolve.group == current.id,
                  peerMembers[peer] == current.hostKey,
                  let hostKeyData = Data(base64URL: current.hostKey),
                  let signature = Data(base64URL: dissolve.signature),
                  let hostKey = try? Curve25519.Signing.PublicKey(rawRepresentation: hostKeyData),
                  hostKey.isValidSignature(signature, for: Data("dissolve|\(current.id)".utf8)) else { return }
            let host = current.hostName
            leaveTodayGroup()
            finderNotice = "\(host)がグループを終了しました"
            refreshDials()
        case "decline":
            guard let group, !group.isHost, peerMembers[peer] == group.hostKey else { return }
            let host = group.hostName
            leaveTodayGroup()
            finderNotice = "\(host)が参加を許可しませんでした"
            refreshDials()
        case "name":
            guard let message = try? JSONDecoder().decode(NameMessage.self, from: data),
                  let member = peerMembers[peer], isApproved(member), group?.names[member] == nil else { return }
            peerNames[peer] = cleanName(message.name)
            refreshDials()
        case "meet":
            guard active, let request = try? JSONDecoder().decode(MeetRequest.self, from: data),
                  let member = peerMembers[peer], isApproved(member), amApproved else { return }
            if !groupPeers.contains(peer) { beginRanging(with: peer) }
            guard groupPeers.contains(peer) else { return }
            activeRequest = request
            // Accepting is consent: only now do we make a session and send our token
            // back. If theirs has not arrived yet, the token handler starts ranging
            // when it does.
            ensureLiveSession(for: link)
            runConfig(for: link)
            applyIncomingRequest(request)
            sendMotion()
            sendMood()
        case "motion":
            // From anyone connected, not only the focused friend: a member's state
            // can arrive before the host's list puts them in the group.
            guard let motion = try? JSONDecoder().decode(MotionMessage.self, from: data) else { return }
            link.moving = motion.moving
            if peer == activePeerID { refreshDials() }
        case "ping":
            guard let member = peerMembers[peer], isApproved(member), amApproved else { return }
            receivePing(from: name(of: peer))
        case "errand", "errandStatus", "mood":
            // 近くにいるときはMPCでも届く。中身の扱いは中継から来たときと同じ。
            guard let member = peerMembers[peer], isApproved(member), amApproved else { return }
            handleNote(data)
        case "spot":
            guard let spot = try? JSONDecoder().decode(SpotMessage.self, from: data),
                  var current = group, !current.isHost, peerMembers[peer] == current.hostKey else { return }
            current.spot = spot.text.isEmpty ? nil : cleanName(spot.text)
            group = current
            saveTodayGroup()
            refreshDials()
        case "cancel":
            let who = name(of: peer)
            if var current = group, current.isHost, let member = peerMembers[peer], current.approved.contains(member) {
                // Leaving takes them off today's list: coming back needs a new yes.
                current.approved.removeAll { $0 == member }
                current.names[member] = nil
                current.version += 1
                group = current
                saveTodayGroup()
                sendWelcome(to: approvedPeers)
            }
            guard groupPeers.contains(peer) else {
                refreshDials()
                return
            }
            restartLink(link)
            leaveGroup(peer)
            finderNotice = "\(who)が終了しました"
            refreshDials()
        default:
            break
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
        finderChips.isHidden = true
        finderTip.isHidden = true
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

    private func updateMeasurement(distance rawDistance: Float?, direction: simd_float3?, world: simd_float4x4?) {
        var distance = rawDistance
        var direction = direction
        var world = world
        #if DEBUG
        // 確認用: 電波が届かない状況を作る。シミュレータは必ず模擬の距離を返すため。
        if previewNoRadio { distance = nil; direction = nil; world = nil }
        #endif
        recordTrend(distance)
        if distance != nil {
            lastDistanceAt = CACurrentMediaTime()
            // Fires once, 2.1 s after the last reading, so the screen and the
            // island can say 測っています instead of holding the old advice.
            staleTimer?.invalidate()
            staleTimer = Timer.scheduledTimer(withTimeInterval: 2.1, repeats: false) { [weak self] _ in
                self?.refreshDials()
            }
        }
        updateProximityFeedback(distance: distance)
        latestDistance = distance
        latestDirection = direction
        latestWorldTransform = world
        updateNearbyAlert()

        if distance != nil, phase == .searching, role == .requester || activeRequest != nil || isDemo {
            phase = .ready
        }
        refreshDials()

        if phase == .arrived, let d = distance, d > arrivalThreshold + arrivalHysteresis {
            phase = .guiding
        }
        if phase == .guiding {
            updateGuidance()
            if let d = distance, d < arrivalThreshold, radioIsFresh() { arrive() }
        }
    }

    private func band(for distance: Float) -> ProximityBand {
        if distance < arrivalThreshold { return .arrived }
        if distance < nearThreshold { return .near }
        if distance < 5.0 { return .mid }
        return .far
    }

    /// The band the beat follows. Stepping closer changes at the edge; stepping
    /// back only once the reading has cleared the band's outer edge by the same
    /// margin arrival uses, so a reading jittering on 2.5 m or 1.0 m does not
    /// restart the rhythm every tick.
    private func hapticBand(for distance: Float) -> ProximityBand {
        let raw = band(for: distance)
        guard let current = currentBand, raw.rawValue < current.rawValue else { return raw }
        let outerEdge: Float
        switch current {
        case .arrived: outerEdge = arrivalThreshold
        case .near: outerEdge = nearThreshold
        case .mid: outerEdge = 5.0
        case .far: return raw
        }
        return distance < outerEdge + arrivalHysteresis ? current : raw
    }

    private func formatMeters(_ d: Float) -> String {
        d >= 2 ? String(format: "%.0f m", d.rounded()) : String(format: "%.1f m", d)
    }

    /// One screen: invite, wait for the yes, then the distance. Nobody outside
    /// today's group ever appears here, and nobody outside it can see this phone.
    private func refreshDials() {
        refreshDemoButton()
        refreshFriends()
        // グループがあるなら遠いときの層を生かす。保存の時だけでは、
        // 保存済みのグループを読み直して再開したときに起きなかった。
        if group != nil { startRemote() } else if remote != nil { stopRemote() }
        if let current = group, current.expires <= Date() {
            expireGroup()
            return
        }
        dialExplores = false
        let colour = latestDistance.map { band(for: $0).colour } ?? UIColor.white.withAlphaComponent(0.35)
        let idleColour = UIColor.white.withAlphaComponent(0.35)
        let members = groupPeers.compactMap { links[$0] }.sorted { name(of: $0.peerID) < name(of: $1.peerID) }
        let connected = !members.isEmpty
        /// 電波では繋がっていないが、中継で相手の居場所が届いている状態。
        let mapOnly = !connected && group != nil && mapDistance() != nil
        let showRadar = members.count >= 2
        finderDial.isHidden = showRadar
        friendsRadar.isHidden = !showRadar
        radarCaption.isHidden = !showRadar
        if showRadar {
            friendsRadar.arrivalThreshold = arrivalThreshold
            friendsRadar.show(members.map {
                FriendsRadar.Friend(id: $0.peerID, name: name(of: $0.peerID),
                                    distance: $0.distance, focused: $0.peerID == activePeerID)
            })
        }

        // One latch for everything the eye sees: on below 1.0 m, off only past
        // 1.5 m, so a reading that jitters across the line does not flap the
        // word, the headline, the dial and the island several times a second.
        if let d = latestDistance, d > arrivalThreshold + arrivalHysteresis { didAnnounceArrival = false }
        if connected, let d = latestDistance, d < arrivalThreshold, !didAnnounceArrival, radioIsFresh() {
            didAnnounceArrival = true
            if hapticsOn { arrivalGenerator.notificationOccurred(.success) }
        }
        // つないだ相手は覚えておく。次からリンクは要らない（覚えるのは鍵と名前だけ）
        if connected, let peer = activePeerID, let member = peerMembers[peer], member != group?.myMember {
            KnownFriends.remember(key: member, name: peerNames[peer] ?? "相手")
        }
        let arrived = connected && latestDistance != nil && didAnnounceArrival && radioIsFresh()
        let focusName = activePeerID.map { name(of: $0) } ?? "相手"

        if connected {
            if let d = latestDistance, radioIsFresh() {
                let caption = guidance(for: focusName).detail
                finderDial.set(distance: d, direction: nil,
                               colour: arrived ? MeetPalette.arrival : colour,
                               value: arrived ? "見つけた" : formatMeters(d),
                               caption: caption,
                               closing: d < Self.handoffDistance ? nil : trendClosing,
                               arrived: arrived)
            } else if mapDistance() != nil {
                // 距離は上の見出しが言っている。同じ数字を輪の中でもう一度言わない。
                // 待っているあいだに役に立つのは、まわりに何があるかのほう。
                dialExplores = true
                finderDial.set(distance: nil, direction: nil, colour: idleColour,
                               value: "まわりを見る",
                               caption: "近くのおすすめの場所とイベント会場",
                               symbol: "binoculars")
            } else {
                var caption = "まもなく距離が表示されます"
                #if DEBUG
                if previewNoRadio {
                    let r = remote
                    let mine = locations.last.map { String(format: "%.4f,%.4f", $0.coordinate.latitude, $0.coordinate.longitude) } ?? "なし"
                    caption = "中継=\(r == nil ? "未開始" : (r!.isJoined ? "参加済" : "接続中"))"
                        + " 送\(r?.sentCount ?? 0) 受\(r?.gotCount ?? 0)\n自分=\(mine) 相手=\(theirFix == nil ? "なし" : "あり")"
                }
                #endif
                finderDial.set(distance: nil, direction: nil, colour: idleColour,
                               value: "\(focusName)とつながりました", caption: caption,
                               symbol: "dot.radiowaves.left.and.right", waiting: true)
            }
        } else if mapOnly {
            // 電波（MPC）は数十mしか届かない。遠いあいだは繋がらないのが普通で、
            // そこで画面から距離まで消すと、中継で届いている居場所が無駄になる。
            dialExplores = true
            finderDial.set(distance: nil, direction: nil, colour: idleColour,
                           value: "まわりを見る",
                           caption: "近くのおすすめの場所とイベント会場",
                           symbol: "binoculars")
        } else if !supportsUWB && !isDemo {
            finderDial.set(distance: nil, direction: nil, colour: idleColour,
                           value: "距離を測定できません", caption: "このiPhoneは対応していません",
                           symbol: "exclamationmark.triangle")
        } else if let current = group, current.isHost {
            finderDial.set(distance: nil, direction: nil, colour: idleColour,
                           value: "参加を待っています",
                           caption: current.spot.map { "「\($0)」と伝えています\nリンクを開いた人はそのまま入ります" }
                               ?? "リンクを開いた人は\nそのまま入ります",
                           symbol: "hourglass", waiting: true)
        } else if let current = group {
            finderDial.set(distance: nil, direction: nil, colour: idleColour,
                           value: awaitingApproval ? "\(current.hostName)の許可を待っています" : "\(current.hostName)を探しています",
                           caption: awaitingApproval ? "あなたの記号 \(Badge.of(current.myMember))\nホストに伝えると確かめられます"
                               : (current.spot.map { "\(current.hostName)は「\($0)」にいます" } ?? "\(current.hostName)がアプリを開くと\nつながります"),
                           symbol: awaitingApproval ? "hourglass" : "person.2", waiting: true)
        } else {
            finderDial.set(distance: nil, direction: nil, colour: idleColour,
                           value: "招待リンクで始めます", caption: "リンクを送った相手とだけ\n距離が見えます",
                           symbol: "link")
        }

        // 地図が床のときは輪を引っ込める。地図と輪が同じ場所で重なると、
        // どちらも読めなくなる（近づいて電波が届いたら、輪がまた前に出る）。
        let floorUp = group != nil && theirFix != nil
        let ringHidden = floorUp && !radioIsFresh() && !showRadar
        finderDial.isHidden = showRadar || ringHidden
        // 輪が前に出ている間は地図を落とす。地図だけのときは落とさない。
        let dim = floorUp && !ringHidden
        if floorDim.isHidden != !dim {
            Trans.run(Trans.smoothOut(Trans.fast)) { self.floorDim.alpha = dim ? 1 : 0 }
            floorDim.isHidden = !dim
            floorDim.alpha = dim ? 1 : 0
        }
        floatingButtons.isHidden = !floorUp
        exploreButton.isHidden = !dialExplores && !ringHidden
        switchButton.isHidden = !(activePeerID != nil && latestDistance != nil && supportsUWB)

        // Measuring stops when the phone locks, and finding someone in a crowd is
        // exactly when nobody taps the screen. Only while a distance is arriving.
        UIApplication.shared.isIdleTimerDisabled = connected && latestDistance != nil
        connectStack.isHidden = true
        let hosting = group?.isHost == true
        inviteButton.isHidden = connected || (!supportsUWB && !isDemo) || (group != nil && !hosting)
        let closed = hosting && (group?.refusals ?? 0) >= Self.maxRefusals
        inviteButton.configuration?.title = closed ? "新しいリンクを作る" : hosting ? "もう一度リンクを送る" : "招待リンクを送る"
        // The camera view draws the circle of possible positions on the floor. It
        // needs no camera assistance from NearbyInteraction, so it does not wait
        // on -5883; it only needs a distance to draw.
        cameraButton.isHidden = !connected && !mapOnly
        cameraButton.isEnabled = true
        cameraButton.alpha = 1
        refreshErrandButton()
        refreshMapFloor()
        endButton.isHidden = group == nil && !connected
        endButton.configuration?.title = connected ? "終了" : "やめる"
        // At arrival the dial already says it in mint; the headline would only
        // say it twice.
        if connected || mapOnly, case let guide = guidance(for: focusName), guide.tone != .arrived {
            showGuidance(guide)
        } else {
            finderHeadline.isHidden = true
            lastTone = nil
        }
        // The pill said what the headline now says. One voice.
        showTrend(nil)
        // State changes that arrive without a distance — the peer leaving, the
        // link dropping, the group ending — must reach the island too, or it
        // keeps showing the last number after the person is gone.
        syncLiveActivity()
        if let finderNotice, !connected {
            finderStatus.text = finderNotice
        } else if closed, !connected {
            // From the saved group, so it is still explained after a relaunch.
            finderStatus.text = "断った人が\(Self.maxRefusals)人になったので、新しい参加の受付を止めました"
        } else if isDemo {
            finderStatus.text = "デモ中です。距離は実際の値ではありません。"
        } else if !supportsUWB {
            finderStatus.text = "デモは右上のメニューから利用できます。"
        } else if mapOnly {
            let until = group.map { untilText($0.expires) } ?? "今日"
            finderStatus.text = "電波はまだ届いていません。地図で見ています（\(until)）"
        } else if connected {
            // On screen the whole time anyone can see this phone's distance.
            let until = group.map { untilText($0.expires) } ?? "今日"
            #if DEBUG
            let dbg = previewNoRadio ? "[電波なし試験 送\(remote?.sentCount ?? 0)受\(remote?.gotCount ?? 0)相手\(theirFix == nil ? "×" : "○")] " : ""
            #else
            let dbg = ""
            #endif
            finderStatus.text = dbg + "距離を共有中（\(members.count)人・\(until)）: "
                + members.map { name(of: $0.peerID) }.joined(separator: "、")
        } else {
            finderStatus.text = nil
        }
    }

    /// The distance, plus what to do while standing still. Closing in or drifting
    /// away is the trend label's job, above the ring.
    /// The one sentence the app is for: what to do right now. It comes from both
    /// phones at once — whether you are walking, whether they are, and which way
    /// the gap is going — which is exactly what a map on one phone cannot know.
    private struct Guidance: Equatable {
        enum Tone { case go, wait, turn, near, arrived, unknown }
        let headline: String
        let detail: String
        let tone: Tone
    }

    /// 電波の値の入口。確認用の指定をここで一度だけ効かせる。
    private func radioValue(_ d: Float?) -> Float? {
        #if DEBUG
        if previewNoRadio { return nil }
        #endif
        return d
    }

    /// 電波と地図が食い違ったときの決め方。
    /// 新しい地図の居場所があり、電波の値と大きくずれているなら、その電波は信じない。
    /// （地図が古いときは電波を信じる。屋内でGPSがずれるのは普通のこと）
    private func radioAgreesWithMap() -> Bool {
        guard let d = latestDistance, let fix = theirFix, fix.age < 20,
              let map = mapDistance() else { return true }
        return abs(map.meters - Double(d)) <= max(200, map.accuracy * 3)
    }

    /// UWBの値がいま使えるか。2秒来なければ「無い」とみなす。
    private func radioIsFresh() -> Bool {
        #if DEBUG
        if previewNoRadio { return false }
        #endif
        return latestDistance != nil && CACurrentMediaTime() - lastDistanceAt <= 2 && radioAgreesWithMap()
    }

    private func guidance(for name: String) -> Guidance {
        if CACurrentMediaTime() < pingUntil {
            return Guidance(headline: "\(pingFrom)が合図",
                            detail: radioIsFresh() ? "周りを見てください" : "相手が近づいています", tone: .near)
        }
        // 電波が切れたら「見つけた」は残さない。相手はもう動いているかもしれない。
        if latestDistance != nil, didAnnounceArrival, radioIsFresh() {
            return Guidance(headline: "見つけた", detail: "手を振って合図しましょう", tone: .arrived)
        }
        // 電波が切れたら、地図の数字に切り替える。人には切り替えさせない。
        if !radioIsFresh(), let map = mapDistance() {
            let minutes = max(1, Int((map.meters / 80).rounded()))
            let metres = map.meters < 1000 ? "\(Int(map.meters.rounded()))m" : String(format: "%.1fkm", map.meters / 1000)
            return Guidance(headline: "あと約\(minutes)分・\(metres)",
                            detail: "地図で見ています（誤差±\(Int(map.accuracy.rounded()))m）",
                            tone: map.meters < 80 ? .near : .go)
        }
        // Two seconds without a reading and the last number is history. Saying
        // 進んで on a frozen distance is the one lie this line must never tell.
        if latestDistance != nil, CACurrentMediaTime() - lastDistanceAt > 2 {
            return Guidance(headline: "測っています", detail: "\(name)の距離が届いていません", tone: .unknown)
        }
        if let d = latestDistance, d < Self.handoffDistance {
            return Guidance(headline: "もうすぐそこ", detail: "画面より、周りを見てください", tone: .near)
        }
        guard latestDistance != nil else {
            return Guidance(headline: "測っています", detail: "まもなく距離が出ます", tone: .unknown)
        }
        switch (isMoving, peerMoving, trend) {
        case (false?, true?, _):
            return Guidance(headline: "そのまま待って", detail: "\(name)が向かっています", tone: .wait)
        case (true?, _, .closer), (nil, _, .closer):
            return Guidance(headline: "そのまま進んで", detail: "\(name)に近づいています", tone: .go)
        case (true?, _, .farther), (nil, _, .farther):
            return Guidance(headline: "向きを変えて", detail: "\(name)から離れています", tone: .turn)
        case (true?, _, .none):
            return Guidance(headline: "少し歩いて", detail: "近づいているか、すぐわかります", tone: .go)
        case (false?, false?, _):
            return Guidance(headline: "どちらかが動いて", detail: "2人とも止まっています", tone: .wait)
        default:
            return Guidance(headline: "\(name)まで", detail: "歩くと、近づいているかわかります", tone: .unknown)
        }
    }

    private var lastTone: Guidance.Tone?

    private func showGuidance(_ guide: Guidance) {
        let colour: UIColor
        switch guide.tone {
        case .go: colour = MeetPalette.action
        case .turn: colour = MeetPalette.drift
        case .arrived: colour = MeetPalette.arrival
        case .wait, .near, .unknown: colour = MeetPalette.primary
        }
        finderHeadline.text = guide.headline
        finderHeadline.textColor = colour
        finderHeadline.isHidden = false
        if lastTone != guide.tone {
            lastTone = guide.tone
            // A new instruction lands, it does not fade in: the moment the advice
            // changes is the moment you need to notice it.
            finderHeadline.transform = CGAffineTransform(scaleX: 0.92, y: 0.92)
            Motion.animate(damping: 0.7, response: 0.35) { self.finderHeadline.transform = .identity }
        }
    }

    private func approachCaption(_ name: String) -> String {
        switch (isMoving, peerMoving) {
        case (false?, true?): return "\(name)まで\nその場で待っていてください"
        case (false?, false?): return "\(name)まで\nどちらかが近づいてください"
        default: return "\(name)まで"
        }
    }

    /// Walking toward someone shows up as the distance falling; the wrong way, as it
    /// rising. Each end of a three-second window is averaged over a second, and the
    /// answer needs a clear change to flip, so a jittery reading in a crowd does not
    /// swing it back and forth.
    private func recordTrend(_ distance: Float?) {
        guard let distance else { return }
        let now = CACurrentMediaTime()
        // After a gap the old direction is not evidence about the new one.
        if let last = trendSamples.last, now - last.time > 2 { resetTrend() }
        trendSamples.append((time: now, meters: distance))
        trendSamples.removeAll { now - $0.time > 4 }
        let recent = trendSamples.filter { now - $0.time <= 1 }.map { $0.meters }
        let past = trendSamples.filter { (2.5...3.5).contains(now - $0.time) }.map { $0.meters }
        guard !recent.isEmpty, !past.isEmpty else { return }
        let change = recent.reduce(0, +) / Float(recent.count) - past.reduce(0, +) / Float(past.count)
        let next: Trend
        switch trend {
        case .none: next = change <= -0.4 ? .closer : change >= 0.4 ? .farther : .none
        case .closer: next = change >= 0.4 ? .farther : change > -0.15 ? .none : .closer
        case .farther: next = change <= -0.4 ? .closer : change < 0.15 ? .none : .farther
        }
        guard next != trend else { return }
        trend = next
        // Felt once, at the moment it changes: warmer, or turn around.
        switch next {
        case .closer: impactGenerator.impactOccurred()
        case .farther: arrivalGenerator.notificationOccurred(.warning)
        case .none: break
        }
    }

    private func resetTrend() {
        trendSamples.removeAll()
        trend = .none
    }

    /// Whoever is walking is the subject. Standing still while they come to you
    /// reads "たろが近づいています"; walking yourself, just "近づいています".
    /// For the trail: true where those seconds were closing the gap, false where
    /// they were opening it, nil while it is too early to say.
    private var trendClosing: Bool? {
        switch trend {
        case .closer: return true
        case .farther: return false
        case .none: return nil
        }
    }

    private func trendText(_ name: String) -> String? {
        let theyAreWalking = isMoving == false && peerMoving == true
        switch trend {
        case .closer: return theyAreWalking ? "\(name)が近づいています" : "近づいています"
        case .farther: return theyAreWalking ? "\(name)が離れています" : "離れています　向きを変えてください"
        case .none: return nil
        }
    }

    private func showTrend(_ text: String?) {
        guard let text else {
            trendLabel.isHidden = true
            return
        }
        let closer = trend == .closer
        let ink = closer ? MeetPalette.background : MeetPalette.primary
        let line = NSMutableAttributedString()
        if let symbol = UIImage(systemName: closer ? "checkmark.circle.fill" : "arrow.uturn.backward.circle.fill")?
            .withTintColor(ink, renderingMode: .alwaysOriginal) {
            line.append(NSAttributedString(attachment: NSTextAttachment(image: symbol)))
            line.append(NSAttributedString(string: " "))
        }
        line.append(NSAttributedString(string: text))
        trendLabel.textColor = ink
        trendLabel.attributedText = line
        trendLabel.backgroundColor = closer ? MeetPalette.action : MeetPalette.raised
        trendLabel.isHidden = false
    }

    /// Both phones hold a yes for each other: the host approved this person, and
    /// this phone is on the host's signed list too. Only then does a token change
    /// hands. The side with the smaller member ID asks, so a pair never sends two.
    private func beginRanging(with peer: MCPeerID) {
        guard let link = links[peer], let member = peerMembers[peer], isApproved(member), amApproved,
              let me = group?.myMember,
              !groupPeers.contains(peer), groupPeers.count < Self.maxGroup else { return }
        groupPeers.append(peer)
        if activePeerID == nil {
            activePeerID = peer
            latestDistance = radioValue(link.distance)
            didAnnounceArrival = false
            resetTrend()
        }
        finderNotice = nil
        if let data = try? JSONEncoder().encode(NameMessage(name: Self.myDisplayName)) {
            mpc?.sendData(data: data, peers: [peer], mode: .reliable)
        }
        if me < member {
            ensureLiveSession(for: link)
            sendMeetRequest(MeetRequest(kind: .here, mode: .wave), to: peer)
        }
        startMotionUpdates()
        sendMotion()
        refreshDials()
    }

    /// Tapping a name makes that person the one the camera and the walking hints
    /// are about.
    private func focus(on id: MCPeerID) {
        guard groupPeers.contains(id), id != activePeerID, let link = links[id] else { return }
        selectionTick.selectionChanged()
        activePeerID = id
        peerMoving = nil
        didAnnounceArrival = false
        resetTrend()
        latestDistance = radioValue(link.distance)
        latestDirection = nil
        sendMotion()
        refreshDials()
    }

    /// Someone left the group. The focus moves to whoever is nearest, and only when
    /// nobody is left does the screen go back to the people nearby.
    private func leaveGroup(_ peer: MCPeerID) {
        groupPeers.removeAll { $0 == peer }
        guard activePeerID == peer else { return }
        activeCameraAssist = false
        stopARIfIdle()
        peerMoving = nil
        didAnnounceArrival = false
        resetTrend()
        let next = groupPeers.compactMap { links[$0] }
            .min { ($0.distance ?? .greatestFiniteMagnitude) < ($1.distance ?? .greatestFiniteMagnitude) }
        activePeerID = next?.peerID
        latestDistance = radioValue(next?.distance)
        latestDirection = nil
        latestWorldTransform = nil
        // The camera was pointed at the person who left.
        if phase == .guiding || phase == .arrived { phase = .searching }
        if next == nil {
            activeRequest = nil
            arrivalOverlay.isHidden = true
            finderChips.isHidden = true
            finderTip.isHidden = true
        }
    }

    /// Asked for when it is first needed, not at launch, so the permission prompt
    /// arrives with a reason already on screen.
    private func startMotionUpdates() {
        guard !motionStarted, CMMotionActivityManager.isActivityAvailable() else { return }
        motionStarted = true
        motionActivity.startActivityUpdates(to: .main) { [weak self] activity in
            guard let self, let activity, activity.confidence != .low else { return }
            let moving = activity.walking || activity.running
            guard moving != self.isMoving else { return }
            self.isMoving = moving
            self.sendMotion()
            self.refreshDials()
        }
    }

    private func sendMotion() {
        // Everyone in the group, so whoever has this phone in focus knows. With
        // three people the focus graph is not symmetric; one recipient was not
        // enough.
        let peers = groupPeers.filter { links[$0]?.isDemo != true }
        guard !peers.isEmpty, let isMoving,
              let data = try? JSONEncoder().encode(MotionMessage(moving: isMoving)) else { return }
        mpc?.sendData(data: data, peers: peers, mode: .reliable)
    }

    /// The button says who it goes to and what they will see, so nothing is sent blind.
    private func refreshSendButton() {
        let name = selectedHelperID.flatMap { links[$0] }?.peerID.displayName
        sendButton.configuration?.title = name.map { "\($0)に知らせる" } ?? "知らせる"
        sendButton.configuration?.subtitle = "\(selectedKind.text)・\(selectedMarker.text)"
    }

    // MARK: - Phase handling

    private func applyPhase() {
        let showAR = role == .supporter && (phase == .guiding || phase == .arrived)
        arScreen.isHidden = !showAR
        homeScreen.isHidden = showAR
        waiterPanel.isHidden = role != .requester
        finderPanel.isHidden = role != .supporter
        let wasHidden = arrivalOverlay.isHidden
        arrivalOverlay.isHidden = phase != .arrived
        if wasHidden, phase == .arrived { arrivalSeal.press() }
        // One action at a time: the arrival screen has its own way out.
        arCloseButton.isHidden = phase == .arrived
        if phase != .guiding { stopProximityFeedback() }
        refreshDemoButton()
    }

    @objc private func roleChanged() {
        let next: Role = roleSwitch.selectedSegmentIndex == 0 ? .requester : .supporter
        guard next != role else { return }
        selectionTick.selectionChanged()
        invitedBy = nil
        if next == .supporter { hideWaiterSheet() }
        resetSession()
        role = next
        phase = .searching
        if supportsUWB { startup() }
        refreshPeerList()
        refreshDials()
        if next == .requester { showWaiterSheetIfNeeded() }
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
        groupPeers.removeAll()
        activeRequest = nil
        requestSent = false
        latestDistance = nil
        latestDirection = nil
        latestWorldTransform = nil

        sendButton.isHidden = false
        cancelButton.isHidden = true
        setWaiterSelection(hidden: false)
        waiterStatus.text = "相手がアプリを持っていない場合は、招待を送れます。"
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

    /// The camera view that needs nothing from NearbyInteraction: our ARSession
    /// draws, the radio measures, and the two never touch.
    @objc private func startFloorView() {
        floorRingsOnly = true
        clearPossibleRings()
        startARIfNeeded()
        phase = .guiding
        updateGuidance()
    }

    @objc private func closeAR() {
        stopProximityFeedback()
        floorRingsOnly = false
        clearPossibleRings()
        stopARIfIdle()
        phase = latestDistance != nil ? .ready : .searching
    }

    private func arrive() {
        guard phase != .arrived else { return }
        phase = .arrived
        if isDemo { demoTimer?.invalidate() }
        // The thud is refreshDials' job (once, latched); a second one here made
        // arrival on the camera view buzz twice.
    }

    @objc private func finishMeet() {
        stopProximityFeedback()
        clearErrands()
        endLiveActivity()
        let real = groupPeers.filter { links[$0]?.isDemo == false }
        if group?.isHost == true {
            // The host ending it ends it for everyone, including people this phone is
            // not ranging with right now.
            sendDissolve()
        } else {
            // Leaving: the others stop ranging with this phone, and the host takes it
            // off the list, so coming back needs a new yes.
            let host = links.keys.filter { peerMembers[$0] != nil && peerMembers[$0] == group?.hostKey }
            let recipients = Array(Set(real + host))
            if !recipients.isEmpty, let data = try? JSONEncoder().encode(CancelMessage()) {
                mpc?.sendData(data: data, peers: recipients, mode: .reliable)
            }
        }
        if isDemo { stopDemo() }
        for id in real { if let link = links[id] { restartLink(link) } }
        // Every NISession was just invalidated, and invalidate() never reports
        // back, so the flag would otherwise stay stale and keep the camera on.
        activeCameraAssist = false
        stopARIfIdle()
        groupPeers.removeAll()
        peerMoving = nil
        didAnnounceArrival = false
        resetTrend()
        // Ending is leaving today's group: this phone goes quiet until the next
        // invitation. The radio waits a moment so the cancel above gets out. The key
        // stays until the group expires, so opening the same link again is the
        // same member asking again.
        #if DEBUG
        print("RECON finishMeet id=\(group?.id.prefix(4) ?? "-") stack=\(Thread.callStackSymbols.dropFirst().prefix(4).joined(separator: " | "))")
        #endif
        group = nil
        signingKey = nil
        awaitingApproval = false
        resumePending = false
        joinQueue.removeAll()
        dismissJoinAlert()
        saveTodayGroup()
        links.removeAll()
        peerNames.removeAll()
        peerMembers.removeAll()
        myChallenge.removeAll()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.group == nil else { return }
            self.mpc?.invalidate()
            self.mpc = nil
        }
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
        // The ⋯ menu itself stays available; its demo item greys out instead.
    }

    #if DEBUG
    private var previewCamera: SCNNode?
    private var previewWalk: Timer?

    /// The camera view with no camera: a synthetic walk through a room where the
    /// friend really is at one spot, so the circles that get left behind either
    /// do cross on them or the idea is wrong. ARKit does not run in a simulator,
    /// so this is the only way to check the geometry before a device.
    private func startFloorPreview() {
        let peerID = MCPeerID(displayName: "たろ")
        let link = PeerLink(peerID: peerID)
        link.isDemo = true
        links[peerID] = link
        peerNames[peerID] = "たろ"
        groupPeers = [peerID]
        activePeerID = peerID
        activeRequest = MeetRequest(kind: .here, mode: .wave)
        isDemo = true
        isMoving = true
        peerMoving = false

        let friend = simd_float3(7, 0, -16)
        let cam = SCNNode()
        cam.camera = SCNCamera()
        cam.camera?.zFar = 400
        cam.camera?.fieldOfView = 64
        cam.simdPosition = simd_float3(0, floorDrop, 0)
        cam.eulerAngles = SCNVector3(-0.3, 0, 0)
        sceneView.scene.rootNode.addChildNode(cam)
        sceneView.pointOfView = cam
        previewCamera = cam
        sceneView.scene.background.contents = MeetPalette.background
        addPreviewFloor()
        addPreviewMarker(at: friend)

        floorRingsOnly = true
        phase = .guiding

        var heading: Float = 0
        var elapsed: Float = 0
        previewWalk = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            guard let self, let cam = self.previewCamera else { return }
            elapsed += 1.0 / 30
            // Straight for eight seconds, then a turn — the turn is what makes the
            // old circles cross the new ones instead of nesting inside them.
            if elapsed > 7 {
                let toFriend = atan2(friend.x - cam.simdPosition.x, -(friend.z - cam.simdPosition.z))
                heading += max(-0.012, min(0.012, toFriend - heading))
            }
            cam.eulerAngles = SCNVector3(-0.3, heading, 0)
            let step: Float = 1.15 / 30
            cam.simdPosition += simd_float3(sin(heading) * step, 0, -cos(heading) * step)
            let here = simd_float3(cam.simdPosition.x, 0, cam.simdPosition.z)
            let metres = simd_distance(here, friend)
            link.distance = metres
            self.updateMeasurement(distance: metres, direction: nil, world: nil)
            if metres < 0.7 { self.previewWalk?.invalidate() }
        }
    }

    private func addPreviewFloor() {
        let floor = SCNNode()
        for index in -30...30 {
            for axis in 0..<2 {
                let span: CGFloat = 60
                let geom = axis == 0 ? SCNBox(width: 0.012, height: 0.001, length: span, chamferRadius: 0)
                                     : SCNBox(width: span, height: 0.001, length: 0.012, chamferRadius: 0)
                let material = SCNMaterial()
                material.lightingModel = .constant
                material.diffuse.contents = UIColor.white.withAlphaComponent(0.05)
                geom.materials = [material]
                let node = SCNNode(geometry: geom)
                node.simdPosition = axis == 0 ? simd_float3(Float(index), 0, 0) : simd_float3(0, 0, Float(index))
                floor.addChildNode(node)
            }
        }
        sceneView.scene.rootNode.addChildNode(floor)
    }

    /// Only in the preview: the real answer, so the crossings can be checked
    /// against it. Nothing like this exists in the app — the app never knows.
    private func addPreviewMarker(at position: simd_float3) {
        let geom = SCNCylinder(radius: 0.18, height: 1.7)
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = MeetPalette.arrival.withAlphaComponent(0.25)
        geom.materials = [material]
        let node = SCNNode(geometry: geom)
        node.simdPosition = simd_float3(position.x, 0.85, position.z)
        sceneView.scene.rootNode.addChildNode(node)
    }

    private func startSoloDemo() {
        isDemo = true
        let peerID = MCPeerID(displayName: "たろ")
        let link = PeerLink(peerID: peerID)
        link.isDemo = true
        link.distance = 18
        links[peerID] = link
        peerNames[peerID] = "たろ"
        groupPeers = [peerID]
        activePeerID = peerID
        activeRequest = MeetRequest(kind: .here, mode: .wave)
        // First you stand and they walk, then you walk: both kinds of advice.
        isMoving = false
        peerMoving = true
        var metres: Float = 18
        var away = false
        var wandered = false
        var ticks = 0
        demoTimer?.invalidate()
        demoTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            ticks += 1
            if ticks == 24 { self.isMoving = true; self.peerMoving = false }
            // Walk in, take a few steps the wrong way so the amber half of the
            // trail shows, then walk in for good.
            if !away, !wandered, metres <= 12 { away = true }
            if away, metres >= 15 { away = false; wandered = true }
            metres += (away ? 0.30 : -0.30) + Float.random(in: -0.03...0.03)
            metres = max(0.6, metres)
            link.distance = metres
            self.updateMeasurement(distance: metres, direction: nil, world: nil)
        }
    }
    #endif

    @objc private func demoTapped() {
        if isDemo { stopDemo(); return }
        guard demoAllowed else { return }
        isDemo = true

        if role == .requester {
            for (name, distance) in [("たろ", Float(7.4)),
                                     ("はな", Float(15.6)),
                                     ("ゆう", Float(24.1))] {
                let peerID = MCPeerID(displayName: name)
                let link = PeerLink(peerID: peerID)
                link.isDemo = true
                link.peerRole = "supporter"
                link.distance = distance
                links[peerID] = link
            }
            waiterStatus.text = "デモ中です。距離は実際の値ではありません。"
            refreshPeerList()
            refreshDials()
        } else {
            // Three friends already in today's group.
            for (friend, distance) in [("たろ", Float(12)), ("はな", Float(18)), ("ゆう", Float(26))] {
                let peerID = MCPeerID(displayName: friend)
                let link = PeerLink(peerID: peerID)
                link.isDemo = true
                link.distance = distance
                links[peerID] = link
                peerNames[peerID] = friend
                groupPeers.append(peerID)
            }
            activePeerID = groupPeers.first
            latestDistance = radioValue(activePeerID.flatMap { links[$0]?.distance })
            activeRequest = MeetRequest(kind: .here, mode: .wave)
            refreshDials()
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
                guard self.activeRequest != nil else { return }
                // Everyone connected closes in, each at their own pace. No direction:
                // a real phone in Japan does not report one either.
                // Now and then the wrong way for a few seconds, so 離れています shows in
                // the demo the way it would when someone sets off in the wrong direction.
                let wrongWay = Int(Date().timeIntervalSince1970) % 12 >= 8
                for id in self.groupPeers {
                    guard let link = self.links[id], link.isDemo else { continue }
                    let current = link.distance ?? 12
                    let step = wrongWay && current > 3 ? Float.random(in: 0.08...0.16) : -Float.random(in: 0.05...0.15)
                    link.distance = min(30, max(0.4, current + step))
                }
                let focus = self.activePeerID.flatMap { self.links[$0] }
                self.updateMeasurement(distance: focus?.distance, direction: nil, world: nil)
            }
        }
    }

    private func stopDemo() {
        isDemo = false
        demoTimer?.invalidate()
        demoTimer = nil
        demoDistance = 7.4

        for (peerID, link) in links where link.isDemo {
            if let session = link.session { killSession(session) }
            links.removeValue(forKey: peerID)
            if activePeerID == peerID { activePeerID = nil }
            if selectedHelperID == peerID { selectedHelperID = nil }
        }
        groupPeers.removeAll { links[$0] == nil }
        peerNames = peerNames.filter { links[$0.key] != nil }
        if role == .supporter {
            activeRequest = nil
            finderChips.isHidden = true
            finderTip.isHidden = true
        } else {
            requestSent = false
            setWaiterSelection(hidden: false)
            sendButton.isHidden = false
            cancelButton.isHidden = true
            waiterStatus.text = "相手がアプリを持っていない場合は、招待を送れます。"
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

    /// Our own ARSession, off. Not while an NISession holds it: pausing under
    /// camera assistance would stop the ranging.
    private func stopARIfIdle() {
        guard arRunning, !activeCameraAssist else { return }
        sceneView.session.pause()
        arRunning = false
    }

    /// Distance, then who. The number carries the screen, so it is tracked the
    /// way display type is and coloured by how close the pair has got.
    private func setReadout(distance: Float?) {
        let text = distance.map { $0 < arrivalThreshold ? "見つけた" : formatMeters($0) } ?? "—"
        arDistanceValue.attributedText = Type.tracked(text, font: Type.display)
        arDistanceValue.textColor = distance.map { band(for: $0).colour } ?? .white
        arPeerName.text = activePeerID.map { name(of: $0) } ?? (isDemo ? "デモ" : "相手")
    }

    private func setARGuidesHidden(_ hidden: Bool) {
        arrowContainer.isHidden = hidden
        dotsContainer.isHidden = hidden
        circleNode.isHidden = hidden
    }

    private func updateGuidance() {
        guard phase == .guiding else { return }
        updateProximityFeedback(distance: latestDistance)

        let focusName = activePeerID.map { name(of: $0) } ?? "相手"
        guard let distance = latestDistance else {
            // The floor view never runs camera assistance, so the convergence
            // sweep copy is wrong there: say what the home line says.
            arHint.text = floorRingsOnly ? guidance(for: focusName).headline
                                         : (sweepHint ?? "iPhoneをゆっくり動かしてください")
            arHint.isHidden = false
            setReadout(distance: nil)
            setARGuidesHidden(true)
            // No reading, no circle. The trail stays.
            possibleRing.isHidden = true
            return
        }

        setReadout(distance: distance)
        updatePossibleRings(distance: distance, closing: trendClosing)
        if floorRingsOnly {
            // No arrow, no dots: the circle is everything the radio can honestly
            // draw, and the crossings do the narrowing. The instruction comes too.
            setARGuidesHidden(true)
            arHint.text = guidance(for: focusName).headline
            arHint.isHidden = false
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
            let worldDir = camNode.simdConvertVector(simd_float3(dir.x, dir.y, dir.z), to: nil)
            var v = worldDir
            v.y = 0
            if simd_length(v) > 0.01 { horizontalDir = simd_normalize(v) }
        }

        guard let camNode = cam, let dir = horizontalDir else {
            arHint.text = sweepHint ?? "iPhoneをゆっくり動かしてください"
            arHint.isHidden = false
            setARGuidesHidden(true)
            return
        }
        arHint.text = distance < nearThreshold ? "顔を上げて周りを見てください" : nil
        arHint.isHidden = arHint.text == nil
        #if DEBUG
        // 実機でカメラ補助が効いているかを、その場で読めるようにする
        let deg = latestHorizontalAngle.map { String(format: "%.0f度", $0 * 180 / .pi) } ?? "なし"
        arHint.text = "水平角=\(deg) 上下=\(latestVerticalEstimate ?? "-") 収束=\(convergenceText)"
        arHint.isHidden = false
        #endif

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

    /// While two phones are measuring, iOS has a better place for it than our own
    /// screen: the island at the top, and the Lock Screen. Same ring, turned
    /// inside out — it fills as the gap closes — and never an arrow, because the
    /// radio still has no idea which way anyone is.
    private func syncLiveActivity(markStale: Bool = false) {
        guard #available(iOS 16.2, *) else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        guard activePeerID != nil, group != nil || isDemo else {
            endLiveActivity()
            return
        }
        let who = activePeerID.map { name(of: $0) } ?? "相手"
        let guide = guidance(for: who)
        // The readout already says 見つけた; the line under it is the advice.
        let instruction = guide.tone == .arrived ? guide.detail : guide.headline
        let arrived = latestDistance != nil && didAnnounceArrival
        let now = CACurrentMediaTime()
        // A metres-only tick inside the throttle window can wait; a new
        // instruction or an arrival cannot.
        if !markStale, meetActivity != nil,
           instruction == lastSentInstruction, arrived == lastSentArrived,
           now - lastActivityUpdate < 0.7 {
            return
        }
        let state = MeetActivityAttributes.ContentState(
            metres: latestDistance.map(Double.init),
            name: who,
            closing: trendClosing,
            arrived: arrived,
            untilText: group.map { untilText($0.expires) } ?? "",
            instruction: instruction)
        // NearbyInteraction stops the moment the app leaves the front, so the
        // island's last line is history from then on: stale now, not in 30 s.
        // In the foreground, half a minute of silence means the same thing.
        let content = ActivityContent(state: state,
                                      staleDate: markStale ? Date() : Date().addingTimeInterval(30))
        lastSentInstruction = instruction
        lastSentArrived = arrived
        // Zero after a background trip: mach time barely moves while the phone
        // sleeps, so the throttle cannot be trusted for the first reading back.
        lastActivityUpdate = markStale ? 0 : now
        if let activity = meetActivity {
            Task { await activity.update(content) }
        } else if !markStale {
            meetActivity = try? Activity.request(attributes: MeetActivityAttributes(name: who),
                                                 content: content, pushType: nil)
        }
    }

    @objc private func appDidEnterBackground() {
        syncLiveActivity(markStale: true)
    }

    /// An island left over from a run that was killed would show a number nobody
    /// is measuring any more. Every launch starts with none; a resumed group makes
    /// a fresh one the moment a distance arrives.
    private func endOrphanedActivities() {
        guard #available(iOS 16.2, *) else { return }
        for activity in Activity<MeetActivityAttributes>.activities {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
    }

    private func endLiveActivity() {
        lastSentInstruction = nil
        lastSentArrived = nil
        guard #available(iOS 16.2, *), let activity = meetActivity else { return }
        meetActivity = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }

    /// The home screen counts too. This used to be gated on the camera screen,
    /// which is switched off, so the beat had never played for anyone.
    private var proximityFeedbackAllowed: Bool {
        hapticsOn && phase != .arrived && (phase == .guiding || (activePeerID != nil && latestDistance != nil))
    }

    private func updateProximityFeedback(distance: Float?) {
        guard proximityFeedbackAllowed, let distance else { return }
        let next = hapticBand(for: distance)
        guard next != currentBand else { return }
        currentBand = next
        applyBandColour(next)

        hapticTimer?.invalidate()
        hapticTimer = nil
        guard next != .arrived else { return }
        proximityGenerator.prepare()
        proximityGenerator.impactOccurred(intensity: next.intensity)
        hapticTimer = Timer.scheduledTimer(withTimeInterval: next.interval, repeats: true) { [weak self] _ in
            guard let self, self.proximityFeedbackAllowed else { return }
            // A rhythm that keeps going after the readings stop is a lie you can
            // feel: 1.2 s of silence on the radio is 1.2 s of silence in the hand.
            guard CACurrentMediaTime() - self.lastDistanceAt < 1.2 else {
                self.stopProximityFeedback()
                return
            }
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
        buildMapFloor()
        homeScreen.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            homeScreen.topAnchor.constraint(equalTo: view.topAnchor),
            homeScreen.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            homeScreen.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            homeScreen.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        let safe = homeScreen.safeAreaLayoutGuide

        // 輪が前に出たときに、地図を一段落とす幕。
        floorDim.backgroundColor = MeetPalette.background.withAlphaComponent(0.86)
        floorDim.isUserInteractionEnabled = false
        floorDim.isHidden = true
        homeScreen.addSubview(floorDim)
        floorDim.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            floorDim.topAnchor.constraint(equalTo: homeScreen.topAnchor),
            floorDim.bottomAnchor.constraint(equalTo: homeScreen.bottomAnchor),
            floorDim.leadingAnchor.constraint(equalTo: homeScreen.leadingAnchor),
            floorDim.trailingAnchor.constraint(equalTo: homeScreen.trailingAnchor),
        ])

        // 地図は画面の床。上に乗る文字が読めるよう、上下に暗がりを置く。
        for (scrim, top) in [(topScrim, true), (bottomScrim, false)] {
            homeScreen.addSubview(scrim)
            scrim.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                scrim.leadingAnchor.constraint(equalTo: homeScreen.leadingAnchor),
                scrim.trailingAnchor.constraint(equalTo: homeScreen.trailingAnchor),
                scrim.heightAnchor.constraint(equalTo: homeScreen.heightAnchor, multiplier: top ? 0.30 : 0.42),
            ])
            if top {
                scrim.topAnchor.constraint(equalTo: homeScreen.topAnchor).isActive = true
            } else {
                scrim.bottomAnchor.constraint(equalTo: homeScreen.bottomAnchor).isActive = true
            }
            scrim.isUserInteractionEnabled = false
            scrim.isHidden = true
        }

        let title = UILabel()
        title.font = Type.appName
        title.attributedText = Type.tracked("ここだよ", font: Type.appName)
        // On a short screen the title was the weakest thing on the column and got
        // squeezed to nothing: the app lost its own name while the card was open.
        title.setContentCompressionResistancePriority(.required, for: .vertical)
        demoButton.setContentCompressionResistancePriority(.required, for: .vertical)
        title.textColor = MeetPalette.primary

        var more = UIButton.Configuration.plain()
        more.image = UIImage(systemName: "ellipsis.circle",
                             withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .regular))
        more.baseForegroundColor = MeetPalette.primary
        more.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8)
        demoButton.configuration = more
        demoButton.accessibilityLabel = "その他"
        demoButton.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] completion in
            completion(self?.moreMenuItems() ?? [])
        }])
        demoButton.showsMenuAsPrimaryAction = true

        roleSwitch.selectedSegmentIndex = 0
        // Neutral, like a system segmented control. It was filled with the accent,
        // which put it in a shouting match with the one button that matters.
        roleSwitch.selectedSegmentTintColor = MeetPalette.primary
        roleSwitch.backgroundColor = MeetPalette.surface
        roleSwitch.setTitleTextAttributes([.foregroundColor: MeetPalette.secondary,
                                           .font: Type.button], for: .normal)
        roleSwitch.setTitleTextAttributes([.foregroundColor: MeetPalette.background,
                                           .font: Type.font(15, .bold, .body)], for: .selected)
        roleSwitch.addTarget(self, action: #selector(roleChanged), for: .valueChanged)
        roleSwitch.isHidden = true

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
                panel.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 18),
                panel.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
                panel.trailingAnchor.constraint(equalTo: safe.trailingAnchor),
                panel.bottomAnchor.constraint(equalTo: safe.bottomAnchor),
            ])
        }

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: safe.topAnchor, constant: 10 + Self.hudInset),
            title.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 20),
            demoButton.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            demoButton.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -20),

            roleSwitch.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 14),
            roleSwitch.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 20),
            roleSwitch.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -20),
            roleSwitch.heightAnchor.constraint(equalToConstant: 40),
        ])
    }

    /// 地図の床。相手の居場所が届いている間だけ敷く。
    /// 画面をもう1枚作らず、いまある地図の画面をそのまま下に埋める。
    private func buildMapFloor() {
        guard mapFloor == nil else { return }
        let vc = MeetMapViewController(peerName: partnerName, myName: Self.myDisplayName, compact: true)
        addChild(vc)
        homeScreen.addSubview(vc.view)
        vc.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            vc.view.topAnchor.constraint(equalTo: homeScreen.topAnchor),
            vc.view.bottomAnchor.constraint(equalTo: homeScreen.bottomAnchor),
            vc.view.leadingAnchor.constraint(equalTo: homeScreen.leadingAnchor),
            vc.view.trailingAnchor.constraint(equalTo: homeScreen.trailingAnchor),
        ])
        vc.didMove(toParent: self)
        vc.view.isHidden = true
        mapFloor = vc
    }

    /// 床の出し入れ。相手の居場所が無い間は、これまでどおりの紺一色。
    private func refreshMapFloor() {
        guard let floor = mapFloor else { return }
        let show = group != nil && theirFix != nil
        if show, floor.view.isHidden { floor.refit() }   // 出た瞬間に2人が入る向きへ
        floor.view.isHidden = !show
        topScrim.isHidden = !show
        bottomScrim.isHidden = !show
        homeScreen.backgroundColor = show ? .clear : bgColour
        guard show else { return }
        floor.rename(peer: partnerName)
        let radio = radioIsFresh() ? latestDistance.map { Double($0) } : nil
        let map = mapDistance()
        floor.update(peerAt: theirFix?.coordinate, meAt: locations.last,
                     metres: radio ?? map?.meters, accuracy: map?.accuracy,
                     byRadio: radio != nil, peerMood: peerMood, myMood: myMood)
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
        peerEmptyLabel.text = "相手に「迎えに行く」を選んでもらってください。"
        peerEmptyLabel.font = Type.label
        peerEmptyLabel.textColor = MeetPalette.secondary
        peerEmptyLabel.numberOfLines = 0

        waiterSelection.axis = .vertical
        waiterSelection.spacing = 8
        waiterSelection.addArrangedSubview(sectionLabel("場所"))
        waiterSelection.addArrangedSubview(kindRow)
        waiterSelection.setCustomSpacing(18, after: kindRow)
        waiterSelection.addArrangedSubview(sectionLabel("目印"))
        waiterSelection.addArrangedSubview(markerRow)
        waiterSelection.setCustomSpacing(18, after: markerRow)
        waiterSelection.addArrangedSubview(sectionLabel("知らせる相手"))
        waiterSelection.addArrangedSubview(peerListStack)
        waiterSelection.addArrangedSubview(peerEmptyLabel)

        sendButton.configuration = primaryConfig(title: "知らせる",
                                                 image: "hand.wave.fill",
                                                 background: actionColour,
                                                 foreground: .black)
        // Who it goes to and what they will see, under the verb.
        sendButton.configuration?.titleAlignment = .center
        sendButton.configuration?.subtitleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in
            var a = attrs
            a.font = Type.caption
            return a
        }
        sendButton.addTarget(self, action: #selector(sendTapped), for: .touchUpInside)
        respondOnPress(sendButton)

        let callConf = primaryConfig(title: "招待を送る",
                                     image: "square.and.arrow.up",
                                     background: actionColour,
                                     foreground: MeetPalette.background)
        callButton.configuration = callConf
        callButton.titleLabel?.font = Type.button
        callButton.addTarget(self, action: #selector(callPartnerTapped), for: .touchUpInside)
        respondOnPress(callButton)

        var cancelConf = UIButton.Configuration.plain()
        cancelConf.title = "終了"
        cancelConf.baseForegroundColor = UIColor.white.withAlphaComponent(0.65)
        cancelButton.configuration = cancelConf
        cancelButton.isHidden = true
        cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        respondOnPress(cancelButton)

        waiterStatus.text = "相手がアプリを持っていない場合は、招待を送れます。"
        waiterStatus.font = Type.caption
        waiterStatus.textColor = MeetPalette.secondary
        waiterStatus.textAlignment = .center
        waiterStatus.numberOfLines = 3


        // One stack instead of four views chained by their edges. Hidden rows
        // collapse on their own, and the whole block keeps its natural height so
        // the dial is what gives way on a short screen.
        waiterControls.axis = .vertical
        waiterControls.spacing = 6
        waiterControls.isLayoutMarginsRelativeArrangement = true
        waiterControls.layoutMargins = UIEdgeInsets(top: 0, left: 24, bottom: 0, right: 24)
        waiterControls.alignment = .fill
        waiterControls.addArrangedSubview(sendButton)
        waiterControls.addArrangedSubview(callButton)
        waiterControls.addArrangedSubview(waiterStatus)
        waiterControls.addArrangedSubview(cancelButton)
        // On the stack itself this does nothing: the squeeze lands on the children.
        // At the default 750 they tied with the dial's preferred size and lost, so
        // "相手を呼ぶ" and the status line were laid out 0pt tall.
        for v in waiterControls.arrangedSubviews {
            v.setContentCompressionResistancePriority(.required, for: .vertical)
        }

        waiterPanel.addSubview(waiterDial)
        waiterDial.translatesAutoresizingMaskIntoConstraints = false
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
        // Centred in whatever the sheet leaves, not in the panel: the sheet's
        // height changes when the choices collapse after sending.
        // The dial sits on the home screen; the sheet is presented over it by
        // UIKit. The screen cannot know the sheet's live height, so the dial keeps
        // clear of the sheet at its smallest resting size and lets the sheet cover
        // it when dragged up — which is what a sheet is for.
        let dialCentre = waiterDial.centerYAnchor.constraint(equalTo: waiterPanel.topAnchor,
                                                             constant: 170)
        dialCentre.priority = .defaultLow
        dialCentre.isActive = true

        // The same ring as the finder's. At low priority it tied with the centring
        // and came out half the size, which read as a lesser screen.
        let dialSize = waiterDial.heightAnchor.constraint(equalToConstant: 260)
        dialSize.priority = .defaultHigh
        dialSize.isActive = true
        // ...but never wider than the screen comfortably allows.
        waiterDial.widthAnchor.constraint(lessThanOrEqualTo: waiterPanel.widthAnchor,
                                          multiplier: 0.72).isActive = true

        NSLayoutConstraint.activate([
            waiterSelection.topAnchor.constraint(equalTo: waiterCard.topAnchor, constant: 0),
            waiterSelection.bottomAnchor.constraint(equalTo: waiterCard.bottomAnchor, constant: -34),
            waiterSelection.leadingAnchor.constraint(equalTo: waiterCard.leadingAnchor, constant: 24),
            waiterSelection.trailingAnchor.constraint(equalTo: waiterCard.trailingAnchor, constant: -24),

            waiterDial.centerXAnchor.constraint(equalTo: waiterPanel.centerXAnchor),
            waiterDial.topAnchor.constraint(greaterThanOrEqualTo: waiterPanel.topAnchor, constant: 8),
            waiterDial.bottomAnchor.constraint(lessThanOrEqualTo: waiterPanel.bottomAnchor,
                                               constant: -Self.closedSheetHeight - 16),
            waiterDial.widthAnchor.constraint(equalTo: waiterDial.heightAnchor),
            waiterDial.heightAnchor.constraint(greaterThanOrEqualToConstant: 0),
        ])
    }

    // MARK: - Finding side

    private func buildFinderPanel() {
        finderChips.axis = .horizontal
        finderChips.spacing = 8
        finderChips.alignment = .center
        finderChips.isHidden = true
        style(chip: finderKindChip, background: MeetPalette.raised, text: MeetPalette.primary)
        style(chip: finderMarkerChip, background: MeetPalette.raised, text: MeetPalette.primary)
        finderKindChip.text = MeetRequest.Kind.here.text
        finderMarkerChip.text = MeetRequest.MarkerHint.wave.text
        finderChips.addArrangedSubview(finderKindChip)
        finderChips.addArrangedSubview(finderMarkerChip)
        finderChips.addArrangedSubview(UIView())

        // 「ここだよ！」 is the one thing to do once you are connected and the
        // number alone is not enough: the other phone buzzes and says look up.
        cameraButton.configuration = primaryConfig(title: "ここだよ！ 合図する",
                                                   image: "hand.wave.fill",
                                                   background: actionColour,
                                                   foreground: .black)
        cameraButton.addTarget(self, action: #selector(pingTapped), for: .touchUpInside)
        respondOnPress(cameraButton)
        cameraButton.isEnabled = false
        cameraButton.alpha = 0.4

        finderStatus.font = Type.caption
        finderStatus.textColor = MeetPalette.secondary
        finderStatus.textAlignment = .center
        finderStatus.numberOfLines = 2

        finderTip.font = Type.caption
        finderTip.textColor = MeetPalette.secondary
        finderTip.textAlignment = .center
        finderTip.numberOfLines = 2
        finderTip.isHidden = true

        // The instruction. Bigger than anything but the number, because it is
        // what you act on; the number is what you check it against.
        finderHeadline.font = Type.font(32, .bold, .title1)
        finderHeadline.textColor = MeetPalette.primary
        finderHeadline.textAlignment = .center
        finderHeadline.numberOfLines = 2
        finderHeadline.adjustsFontSizeToFitWidth = true
        finderHeadline.minimumScaleFactor = 0.7
        finderHeadline.isHidden = true

        connectStack.axis = .vertical
        connectStack.spacing = 10
        friendsStack.axis = .vertical
        friendsStack.spacing = 8

        inviteButton.configuration = primaryConfig(title: "招待リンクを送る",
                                                   image: "square.and.arrow.up",
                                                   background: actionColour,
                                                   foreground: .black)
        inviteButton.addTarget(self, action: #selector(callPartnerTapped), for: .touchUpInside)
        respondOnPress(inviteButton)

        // 主役は合図のボタン。おつかいはその下に、面を落とした形で置く。
        var errandConf = primaryConfig(title: "おつかいを頼む", image: "cart.fill",
                                       background: MeetPalette.raised, foreground: MeetPalette.primary)
        errandConf.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 20, bottom: 14, trailing: 20)
        errandConf.titleAlignment = .leading
        errandConf.subtitleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in
            var a = attrs
            a.font = Type.caption
            a.foregroundColor = MeetPalette.secondary
            return a
        }
        errandButton.configuration = errandConf
        errandButton.addTarget(self, action: #selector(errandTapped), for: .touchUpInside)
        respondOnPress(errandButton)
        errandButton.isHidden = true

        var endConf = UIButton.Configuration.plain()
        endConf.title = "終了"
        endConf.baseForegroundColor = MeetPalette.secondary
        endButton.configuration = endConf
        endButton.addTarget(self, action: #selector(finishMeet), for: .touchUpInside)
        respondOnPress(endButton)

        actionStack.axis = .vertical
        actionStack.spacing = 10
        for v in [connectStack, friendsStack, inviteButton, cameraButton, errandButton, endButton] as [UIView] {
            actionStack.addArrangedSubview(v)
        }

        for v in [finderChips, finderHeadline, finderDial, actionStack, finderTip, finderStatus, toast,
                  floatingButtons] as [UIView] {
            finderPanel.addSubview(v)
            v.translatesAutoresizingMaskIntoConstraints = false
        }

        // 地図の上に置く小さい丸2つ。地図が床のときだけ出る。
        for (button, symbol, action) in [(exploreButton, "binoculars", #selector(dialTapped)),
                                         (switchButton, "camera.viewfinder", #selector(switchTapped))] {
            var conf = UIButton.Configuration.filled()
            conf.image = UIImage(systemName: symbol,
                                 withConfiguration: UIImage.SymbolConfiguration(pointSize: 19, weight: .semibold))
            conf.baseBackgroundColor = MeetPalette.surface
            conf.baseForegroundColor = MeetPalette.primary
            conf.cornerStyle = .capsule
            conf.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 14, bottom: 14, trailing: 14)
            button.configuration = conf
            button.addTarget(self, action: action, for: .touchUpInside)
            respondOnPress(button)
            button.layer.shadowColor = UIColor.black.cgColor
            button.layer.shadowOpacity = 0.35
            button.layer.shadowRadius = 10
            button.layer.shadowOffset = CGSize(width: 0, height: 4)
        }
        floatingButtons.axis = .vertical
        floatingButtons.spacing = 10
        floatingButtons.addArrangedSubview(exploreButton)
        floatingButtons.addArrangedSubview(switchButton)
        floatingButtons.isHidden = true

        // 輪の中が「まわりを見る」のときだけ、輪そのものが押せる。
        finderDial.isUserInteractionEnabled = true
        finderDial.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(dialTapped)))

        // With two or more people connected, the rings take the dial's place.
        friendsRadar.isHidden = true
        friendsRadar.onSelect = { [weak self] id in self?.focus(on: id) }
        radarCaption.text = "近い人ほど内側。向きは表していません"
        radarCaption.font = Type.caption
        radarCaption.textColor = MeetPalette.secondary
        radarCaption.textAlignment = .center
        radarCaption.adjustsFontForContentSizeCategory = true
        radarCaption.isHidden = true
        trendLabel.font = Type.font(17, .semibold, .headline)
        trendLabel.textAlignment = .center
        trendLabel.adjustsFontSizeToFitWidth = true
        trendLabel.minimumScaleFactor = 0.7
        trendLabel.insets = UIEdgeInsets(top: 9, left: 16, bottom: 9, right: 16)
        trendLabel.layer.cornerRadius = 19
        trendLabel.clipsToBounds = true
        trendLabel.isHidden = true
        trendLabel.accessibilityTraits = .updatesFrequently
        for v in [friendsRadar, radarCaption, trendLabel] as [UIView] {
            finderPanel.addSubview(v)
            v.translatesAutoresizingMaskIntoConstraints = false
        }

        // The ring gives way to the actions on a short screen, never the other way.
        let dialCentre = finderDial.centerYAnchor.constraint(equalTo: finderPanel.centerYAnchor, constant: -40)
        dialCentre.priority = .defaultLow
        let dialSize = finderDial.heightAnchor.constraint(equalToConstant: 260)
        dialSize.priority = .defaultHigh

        NSLayoutConstraint.activate([
            finderChips.topAnchor.constraint(equalTo: finderPanel.topAnchor, constant: 4),
            finderChips.leadingAnchor.constraint(equalTo: finderPanel.leadingAnchor, constant: 20),
            finderChips.trailingAnchor.constraint(equalTo: finderPanel.trailingAnchor, constant: -20),

            finderHeadline.bottomAnchor.constraint(equalTo: finderDial.topAnchor, constant: -20),
            finderHeadline.leadingAnchor.constraint(equalTo: finderPanel.leadingAnchor, constant: 24),
            finderHeadline.trailingAnchor.constraint(equalTo: finderPanel.trailingAnchor, constant: -24),

            dialCentre, dialSize,
            finderDial.centerXAnchor.constraint(equalTo: finderPanel.centerXAnchor),
            finderDial.topAnchor.constraint(greaterThanOrEqualTo: finderPanel.topAnchor, constant: 56),
            finderDial.bottomAnchor.constraint(lessThanOrEqualTo: actionStack.topAnchor, constant: -24),
            finderDial.heightAnchor.constraint(lessThanOrEqualToConstant: 260),
            finderDial.widthAnchor.constraint(equalTo: finderDial.heightAnchor),

            finderTip.leadingAnchor.constraint(equalTo: finderPanel.leadingAnchor, constant: 24),
            finderTip.trailingAnchor.constraint(equalTo: finderPanel.trailingAnchor, constant: -24),
            finderTip.bottomAnchor.constraint(equalTo: actionStack.topAnchor, constant: -16),

            actionStack.leadingAnchor.constraint(equalTo: finderPanel.leadingAnchor, constant: 24),
            actionStack.trailingAnchor.constraint(equalTo: finderPanel.trailingAnchor, constant: -24),
            actionStack.bottomAnchor.constraint(equalTo: finderStatus.topAnchor, constant: -12),

            finderStatus.leadingAnchor.constraint(equalTo: finderPanel.leadingAnchor, constant: 24),
            finderStatus.trailingAnchor.constraint(equalTo: finderPanel.trailingAnchor, constant: -24),
            finderStatus.bottomAnchor.constraint(equalTo: finderPanel.bottomAnchor, constant: -10),

            floatingButtons.trailingAnchor.constraint(equalTo: finderPanel.trailingAnchor, constant: -20),
            floatingButtons.bottomAnchor.constraint(equalTo: actionStack.topAnchor, constant: -16),

            // 知らせはボタンの上に浮かせる。下の1行（いま何を共有しているか）は消さない。
            toast.bottomAnchor.constraint(equalTo: actionStack.topAnchor, constant: -14),
            toast.centerXAnchor.constraint(equalTo: finderPanel.centerXAnchor),
            toast.leadingAnchor.constraint(greaterThanOrEqualTo: finderPanel.leadingAnchor, constant: 20),
            toast.trailingAnchor.constraint(lessThanOrEqualTo: finderPanel.trailingAnchor, constant: -20),
        ])
        NSLayoutConstraint.activate([
            // Everything above the buttons: the rings were squeezed into the dial's
            // square and left the top of the screen empty.
            friendsRadar.leadingAnchor.constraint(equalTo: finderPanel.leadingAnchor, constant: 16),
            friendsRadar.trailingAnchor.constraint(equalTo: finderPanel.trailingAnchor, constant: -16),
            friendsRadar.topAnchor.constraint(equalTo: finderPanel.topAnchor, constant: 56),
            friendsRadar.bottomAnchor.constraint(equalTo: radarCaption.topAnchor, constant: -4),
            radarCaption.bottomAnchor.constraint(equalTo: actionStack.topAnchor, constant: -12),
            radarCaption.centerXAnchor.constraint(equalTo: finderPanel.centerXAnchor),
            trendLabel.topAnchor.constraint(equalTo: finderPanel.topAnchor, constant: 6),
            trendLabel.centerXAnchor.constraint(equalTo: finderPanel.centerXAnchor),
            trendLabel.leadingAnchor.constraint(greaterThanOrEqualTo: finderPanel.leadingAnchor, constant: 16),
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
        arMarkerChip.text = MeetRequest.MarkerHint.wave.text
        arMarkerChip.isHidden = true

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
        arDistanceCaption.text = "距離"
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
        putMaterial(behind: arHint, cornerRadius: 12)
        arScreen.sendSubviewToBack(arScrim)
        arScreen.sendSubviewToBack(sceneView)
        arScreen.bringSubviewToFront(close)
    }

    private func buildArrivalOverlay() {
        // The same room, dimmed, with the word in it — not a sheet of colour.
        arrivalOverlay.backgroundColor = MeetPalette.background.withAlphaComponent(0.97)
        arrivalOverlay.isHidden = true
        arScreen.addSubview(arrivalOverlay)
        arrivalOverlay.translatesAutoresizingMaskIntoConstraints = false
        arrivalSeal.translatesAutoresizingMaskIntoConstraints = false
        arrivalOverlay.addSubview(arrivalSeal)

        let headline = UILabel()
        headline.font = Type.display
        headline.attributedText = Type.tracked("見つけた", font: Type.display)
        headline.textColor = MeetPalette.primary
        headline.textAlignment = .center

        let sub = UILabel()
        sub.text = "手を振って合図しましょう"
        sub.font = Type.button
        sub.textColor = MeetPalette.secondary
        sub.textAlignment = .center

        let markerCaption = UILabel()
        markerCaption.text = "目印"
        markerCaption.isHidden = true
        markerCaption.font = Type.caption
        markerCaption.textColor = MeetPalette.secondary
        markerCaption.textAlignment = .center

        arrivalMarker.text = MeetRequest.MarkerHint.wave.text
        arrivalMarker.isHidden = true
        arrivalMarker.font = Type.title
        arrivalMarker.textColor = MeetPalette.primary
        arrivalMarker.textAlignment = .center

        let done = UIButton(type: .system)
        var doneConf = UIButton.Configuration.filled()
        doneConf.title = "終了"
        doneConf.baseBackgroundColor = MeetPalette.raised
        doneConf.baseForegroundColor = MeetPalette.primary
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
            arrivalSeal.centerXAnchor.constraint(equalTo: headline.centerXAnchor),
            arrivalSeal.centerYAnchor.constraint(equalTo: headline.centerYAnchor, constant: 8),
            arrivalSeal.widthAnchor.constraint(equalToConstant: 300),
            arrivalSeal.heightAnchor.constraint(equalToConstant: 300),
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
        mat.diffuse.contents = actionColour.withAlphaComponent(0.95)
        mat.emission.contents = darker(actionColour, 0.5)
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
            dmat.diffuse.contents = actionColour.withAlphaComponent(0.85)
            dmat.emission.contents = darker(actionColour, 0.5)
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
        cmat.diffuse.contents = arrivalColour.withAlphaComponent(0.8)
        cmat.emission.contents = darker(arrivalColour, 0.5)
        tube.materials = [cmat]
        circleMaterial = cmat
        circleNode = SCNNode(geometry: tube)
        circleNode.isHidden = true
        root.addChildNode(circleNode)

        // 48 short rods standing on the floor: the circle of everywhere the
        // friend could be right now, at the distance the radio just measured.
        for _ in 0..<48 {
            let geom = SCNBox(width: 0.035, height: 0.26, length: 0.035, chamferRadius: 0.012)
            let material = SCNMaterial()
            material.lightingModel = .constant
            geom.materials = [material]
            let rod = SCNNode(geometry: geom)
            possibleRing.addChildNode(rod)
            possibleRods.append(rod)
        }
        possibleRing.isHidden = true
        root.addChildNode(possibleRing)
        root.addChildNode(possibleTrail)
    }

    /// Where the circle is now, and where it was. Walking leaves the old circles
    /// standing in the room; where two of them cross is where the friend is.
    private func updatePossibleRings(distance: Float, closing: Bool?) {
        guard let cam = sceneView.pointOfView else { return }
        let eye = cam.simdWorldPosition
        let floor = simd_float3(eye.x, eye.y - floorDrop, eye.z)
        let colour = closing == false ? MeetPalette.drift : actionColour
        possibleRing.isHidden = false
        possibleRing.simdPosition = floor
        for (index, rod) in possibleRods.enumerated() {
            let angle = Float(index) / Float(possibleRods.count) * 2 * .pi
            rod.simdPosition = simd_float3(cos(angle) * distance, 0, sin(angle) * distance)
            rod.geometry?.firstMaterial?.diffuse.contents = colour.withAlphaComponent(0.92)
            rod.geometry?.firstMaterial?.emission.contents = darker(colour, 0.35)
        }
        let moved = lastTrailDrop.map { simd_distance($0, floor) } ?? .greatestFiniteMagnitude
        guard moved > 1.2 else { return }
        lastTrailDrop = floor
        dropTrailRing(at: floor, radius: distance, colour: actionColour)
    }

    private func dropTrailRing(at position: simd_float3, radius: Float, colour: UIColor) {
        let ring = SCNNode()
        for index in 0..<36 {
            let angle = Float(index) / 36 * 2 * .pi
            let geom = SCNBox(width: 0.03, height: 0.2, length: 0.03, chamferRadius: 0.01)
            let material = SCNMaterial()
            material.lightingModel = .constant
            material.diffuse.contents = colour.withAlphaComponent(0.6)
            material.emission.contents = darker(colour, 0.55)
            geom.materials = [material]
            let rod = SCNNode(geometry: geom)
            rod.simdPosition = simd_float3(cos(angle) * radius, 0, sin(angle) * radius)
            ring.addChildNode(rod)
        }
        ring.simdPosition = position
        possibleTrail.addChildNode(ring)
        for older in trailCircles.suffix(5) {
            for point in crossings(older, (position, radius)) { vote(for: point) }
        }
        trailCircles.append((position, radius))
        if trailCircles.count > 8 { trailCircles.removeFirst() }
        // Long enough to walk a few metres and see them cross, short enough that
        // the room does not fill up with old answers.
        ring.runAction(.sequence([.wait(duration: 14), .fadeOut(duration: 10), .removeFromParentNode()]))
    }

    /// Where two measured circles cross, in the plane of the floor. No estimate,
    /// no filter: if both numbers were right, the friend was at one of these two
    /// points. Walk a few metres and the right one keeps being voted for.
    private func crossings(_ a: (centre: simd_float3, radius: Float),
                           _ b: (centre: simd_float3, radius: Float)) -> [simd_float3] {
        let gap = simd_float2(b.centre.x - a.centre.x, b.centre.z - a.centre.z)
        let d = simd_length(gap)
        guard d > 0.3, d < a.radius + b.radius, d > abs(a.radius - b.radius) else { return [] }
        let x = (a.radius * a.radius - b.radius * b.radius + d * d) / (2 * d)
        let h = sqrt(max(0, a.radius * a.radius - x * x))
        let unit = gap / d
        let mid = simd_float2(a.centre.x, a.centre.z) + unit * x
        let perp = simd_float2(-unit.y, unit.x) * h
        return [simd_float3(mid.x + perp.x, a.centre.y, mid.y + perp.y),
                simd_float3(mid.x - perp.x, a.centre.y, mid.y - perp.y)]
    }

    private func vote(for point: simd_float3) {
        if let index = crossingVotes.firstIndex(where: { simd_distance($0.point, point) < 1.6 }) {
            var entry = crossingVotes[index]
            entry.count += 1
            // The average of the crossings that agree, which is the closest thing
            // to an answer this app ever computes — and it is still just measured
            // circles crossing, not a guess about where someone went.
            let weight = Float(entry.count)
            entry.point = (entry.point * (weight - 1) + point) / weight
            entry.node.simdPosition = simd_float3(entry.point.x, entry.point.y, entry.point.z)
            crossingVotes[index] = entry
            style(entry.node, votes: entry.count)
            return
        }
        let pin = SCNNode(geometry: SCNBox(width: 0.06, height: 1, length: 0.06, chamferRadius: 0.02))
        pin.geometry?.firstMaterial?.lightingModel = .constant
        pin.simdPosition = point
        pin.pivot = SCNMatrix4MakeTranslation(0, -0.5, 0)
        possibleTrail.addChildNode(pin)
        crossingVotes.append((point, 1, pin))
        style(pin, votes: 1)
        if crossingVotes.count > 40 {
            crossingVotes.removeFirst().node.removeFromParentNode()
        }
    }

    private func style(_ pin: SCNNode, votes: Int) {
        let height = min(0.35 + 0.3 * Float(votes), 2.2)
        pin.simdScale = simd_float3(1, height, 1)
        let strength = min(0.2 + 0.2 * CGFloat(votes), 1)
        pin.geometry?.firstMaterial?.diffuse.contents = MeetPalette.ink.withAlphaComponent(strength)
        pin.geometry?.firstMaterial?.emission.contents = darker(MeetPalette.ink, 0.6).withAlphaComponent(strength)
    }

    private func clearPossibleRings() {
        possibleRing.isHidden = true
        possibleTrail.childNodes.forEach { $0.removeFromParentNode() }
        lastTrailDrop = nil
        trailCircles.removeAll()
        crossingVotes.removeAll()
    }

    // MARK: - Selection + helper list

    @objc private func kindTapped(_ sender: UIButton) {
        let kinds = MeetRequest.Kind.allCases
        guard sender.tag < kinds.count else { return }
        guard selectedKind != kinds[sender.tag] else { return }
        selectedKind = kinds[sender.tag]
        // Where you wait tends to repeat; the marker is about right now.
        UserDefaults.standard.set(selectedKind.rawValue, forKey: "kokodayo.kind")
        refreshSendButton()
        selectionTick.selectionChanged()
        selectionTick.prepare()
        // 16-tabs-sliding の目盛り（250ms・smooth-out）に合わせる。
        Trans.run(Trans.smoothOut(Trans.fast)) { self.refreshSelectionStyles() }
        popSelected(sender)
    }

    @objc private func markerTapped(_ sender: UIButton) {
        let markers = MeetRequest.MarkerHint.allCases
        guard sender.tag < markers.count else { return }
        guard selectedMarker != markers[sender.tag] else { return }
        selectedMarker = markers[sender.tag]
        refreshSendButton()
        selectionTick.selectionChanged()
        selectionTick.prepare()
        // 16-tabs-sliding の目盛り（250ms・smooth-out）に合わせる。
        Trans.run(Trans.smoothOut(Trans.fast)) { self.refreshSelectionStyles() }
        popSelected(sender)
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
            row.configuration?.subtitle = link.distance.map { formatMeters($0) }
                ?? (link.peerID == activePeerID ? "測定中…" : "接続済み")
            let selected = link.peerID == selectedHelperID
            row.configuration?.baseForegroundColor = selected ? MeetPalette.primary : MeetPalette.secondary
            row.configuration?.image = UIImage(systemName: selected ? "checkmark.circle.fill" : "circle")
            row.configuration?.imagePlacement = .trailing
            row.configuration?.imagePadding = 12
            row.accessibilityValue = selected ? "選択中" : nil
            row.backgroundColor = selected ? MeetPalette.raised : MeetPalette.surface
        }

        peerEmptyLabel.text = guidanceWhenNoPartner()
        peerListStack.isHidden = helpers.isEmpty
        peerEmptyLabel.isHidden = !helpers.isEmpty
        #if DEBUG
        if previewAutoSend, !requestSent, let first = helpers.first {
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
        callButton.isHidden = !helpers.isEmpty || requestSent || links.values.contains { $0.peerRole == "requester" }
        sendButton.isHidden = helpers.isEmpty || requestSent
        refreshSendButton()
        if !requestSent {
            sendButton.isEnabled = !helpers.isEmpty
            sendButton.alpha = 1
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
            waiterStatus.text = "知らせる相手が見つかりません。"
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
        remeasureWaiterSheet()
        if link.isDemo {
            waiterStatus.text = "\(target.displayName)に知らせました（デモ）。"
        } else {
            // Sending is consent: our token goes to this peer and no other.
            ensureLiveSession(for: link)
            sendMeetRequest(request, to: target)
            waiterStatus.text = "\(target.displayName)に知らせました。\n終了するまで、この相手とだけ距離を共有します。"
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
        remeasureWaiterSheet()
        waiterStatus.text = "相手がアプリを持っていない場合は、招待を送れます。"
        waiterDial.reset()
        refreshDials()
    }

    // MARK: - Small builders

    /// The compact rest hugs the head, so it has to follow when a button comes or goes.
    private func remeasureWaiterSheet() {
        guard #available(iOS 16.0, *), let sheet = waiterSheetVC?.sheetPresentationController else { return }
        sheet.animateChanges { sheet.invalidateDetents() }
    }

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
        if let same = links.values.first(where: { $0.peerRole == mine }) {
            // Both sides picked the same thing. Say who, and who should switch.
            let name = same.peerID.displayName
            return role == .requester
                ? "\(name)も「待つ」を選んでいます。向かう人が「迎えに行く」に切り替えてください。"
                : "\(name)も「迎えに行く」を選んでいます。先に着いた人が「待つ」に切り替えてください。"
        }
        return role == .requester
            ? "相手に「迎えに行く」を選んでもらってください。"
            : "相手に「待つ」を選んでもらってください。"
    }

    private func sectionLabel(_ text: String) -> UILabel {
        let label = UILabel()
        // Squeezed to nothing on a real 16 Pro, which left the chips with no
        // question above them.
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        label.text = text
        label.font = Type.captionStrong
        label.textColor = MeetPalette.secondary
        return label
    }

    /// All options visible at once, wrapped onto as many lines as they need.
    /// The horizontal scroller that came before clipped the third choice, so
    /// choosing meant swiping sideways first — the thing that broke the tempo.
    private func chipRow(titles: [String], action: Selector, store: inout [UIButton]) -> UIView {
        let row = WrappingRow()
        for (index, title) in titles.enumerated() {
            let button = CapsuleButton(type: .system)
            var conf = UIButton.Configuration.plain()
            conf.title = title
            conf.contentInsets = NSDirectionalEdgeInsets(top: 13, leading: 16, bottom: 13, trailing: 16)
            conf.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in
                var a = attrs
                a.font = Type.font(14, .semibold, .subheadline)
                return a
            }
            button.configuration = conf
            button.tag = index
            button.layer.borderWidth = 1
            button.addTarget(self, action: action, for: .touchUpInside)
            respondOnPress(button)
            store.append(button)
            row.addSubview(button)
        }
        return row
    }

    /// 選んだ側だけ、11-avatar-group-hover の持ち上がり（1.05倍）を一度かけて戻す。
    private func popSelected(_ button: UIButton) {
        guard !Trans.reduced else { return }
        Trans.run(Trans.smoothOut(Trans.quick)) {
            button.transform = CGAffineTransform(scaleX: Trans.liftScale, y: Trans.liftScale)
        } done: {
            Trans.run(Trans.bounce(Trans.fast)) { button.transform = .identity }
        }
    }

    private func style(chipButton button: UIButton, selected: Bool) {
        // Unselected pills were hairline outlines on black, which reads as
        // unfinished. A filled surface makes them look like something you press.
        button.backgroundColor = selected ? MeetPalette.primary : MeetPalette.raised
        button.layer.borderColor = UIColor.clear.cgColor
        button.configuration?.baseForegroundColor = selected ? MeetPalette.background : MeetPalette.primary
        button.accessibilityValue = selected ? "選択中" : nil
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
        button.layer.cornerRadius = 16
        button.clipsToBounds = true
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
        hud.isHidden = !Self.measurementUIVisible
        view.addSubview(hud)
        hud.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hud.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hud.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            // Top, not bottom: the sheet owns the bottom edge now and would cover
            // the one thing the measuring day depends on.
            hud.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            hud.heightAnchor.constraint(greaterThanOrEqualToConstant: 32),
        ])
        hud.onShare = { [weak self] url in
            let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            self?.presentOnTop(sheet)
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
        if #available(iOS 16.0, *), peerID == activePeerID {
            latestHorizontalAngle = object.horizontalAngle
            latestVerticalEstimate = {
                switch object.verticalDirectionEstimate {
                case .above: return "上"
                case .below: return "下"
                case .same: return "同じ高さ"
                case .aboveOrBelow: return "上か下"
                case .unknown: return "不明"
                @unknown default: return "?"
                }
            }()
        }
        if #available(iOS 16.0, *), cameraAssistance, peerID == activePeerID {
            link.world = session.worldTransform(for: object)
        }

        if peerID == activePeerID {
            updateMeasurement(distance: link.distance, direction: link.direction, world: link.world)
        } else {
            refreshPeerList()
            // Everyone else in the group moves on the rings too.
            if role == .supporter, activeRequest == nil || groupPeers.contains(peerID) { refreshDials() }
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
                sweepHint = "もう少し明るい場所に移動してください"
            } else if reasons.contains(.insufficientMovement) {
                sweepHint = "iPhoneを持って少し歩いてください"
            } else if reasons.contains(.insufficientHorizontalSweep) {
                sweepHint = "iPhoneを左右にゆっくり動かしてください"
            } else if reasons.contains(.insufficientVerticalSweep) {
                sweepHint = "上下にもゆっくり動かしてください"
            } else {
                sweepHint = "そのまま動かし続けてください"
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
            // The peer invalidated their session: they finished, cancelled, or
            // restarted. Since 9/12 ranging is consent-gated, so we do not keep a
            // session alive for them; a new 「ここだよ」 rebuilds everything.
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
            let alert = UIAlertController(title: "距離を測定できません",
                                          message: "相手との距離を測定するには、設定でアクセスを許可してください。",
                                          preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "キャンセル", style: .cancel))
            alert.addAction(UIAlertAction(title: "設定を開く", style: .default) { _ in
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            })
            presentOnTop(alert)
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
                arHint.text = "このiPhoneでは方向を表示できません。距離と目印を頼りに探してください。"
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

/// Lays its children out left to right and wraps to a new line when the next one
/// would not fit. Small and deliberate: a UICollectionView for six pills would be
/// more machinery than the problem.
final class WrappingRow: UIView {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    private var lastHeight: CGFloat = 0

    override func layoutSubviews() {
        super.layoutSubviews()
        let height = layOut(width: bounds.width, apply: true)
        // The intrinsic height depends on the width Auto Layout gives us, which is
        // not known on the first pass. Report it once measured and ask for another.
        if abs(height - lastHeight) > 0.5 {
            lastHeight = height
            invalidateIntrinsicContentSize()
        }
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: lastHeight)
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(width: size.width, height: layOut(width: size.width, apply: false))
    }

    private func layOut(width: CGFloat, apply: Bool) -> CGFloat {
        guard width > 0 else { return 0 }
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
            if x > 0, x + size.width > width {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            if apply { view.frame = CGRect(x: x, y: y, width: min(size.width, width), height: size.height) }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return y + lineHeight
    }

    override func didAddSubview(_ subview: UIView) {
        super.didAddSubview(subview)
        subview.translatesAutoresizingMaskIntoConstraints = true
        invalidateIntrinsicContentSize()
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

/// Carries a view that MeetViewController owns into a real UIKit sheet, so the
/// drag, the detents and the grabber are Apple's rather than ours. The previous
/// hand-rolled panel had a grabber that could not be dragged.
final class SheetCarrier: UIViewController, UISheetPresentationControllerDelegate {

    var onDetentChange: ((String?) -> Void)?

    func sheetPresentationControllerDidChangeSelectedDetentIdentifier(
        _ sheetPresentationController: UISheetPresentationController) {
        let id = sheetPresentationController.selectedDetentIdentifier?.rawValue
        #if DEBUG
        print("SHEET rests at \(id ?? "-") height=\(view.bounds.height)")
        #endif
        onDetentChange?(id)
    }

    /// A closed sheet is 64pt tall and the head is 149pt: showing it there stacks
    /// three lines of text on top of each other. Closed means closed.
    func setHeadVisible(_ visible: Bool) {
        guard head.alpha != (visible ? 1 : 0) else { return }
        Motion.animate(response: 0.25) {
            self.head.alpha = visible ? 1 : 0
        }
        head.isUserInteractionEnabled = visible
        head.accessibilityElementsHidden = !visible
        if !visible { setBodyVisible(false) }
    }

    // Compact shows the action only; details appear when the sheet expands.
    // Otherwise the first option is visibly cut in half at the bottom edge.
    func setBodyVisible(_ visible: Bool) {
        scroll.alpha = visible ? 1 : 0
        scroll.isUserInteractionEnabled = visible
        scroll.accessibilityElementsHidden = !visible
    }

    private let head: UIView
    private let body: UIView

    /// `head` never scrolls. That matters: a sheet whose whole surface is a scroll
    /// view has nowhere left to grab, so the grabber looks broken however the
    /// detents are configured.
    init(head: UIView, body: UIView) {
        self.head = head
        self.body = body
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private let scroll = UIScrollView()

    /// Tapping the head (the grabber strip) opens a closed sheet and closes an
    /// open one, so it works one-handed without a drag.
    var onHeadTap: (() -> Void)?

    @objc private func headTapped(_ g: UITapGestureRecognizer) {
        // Only the strip above the head counts as the tab; taps on the button
        // itself must stay taps on the button.
        guard g.location(in: view).y < 26 || view.bounds.height <= 80 else { return }
        onHeadTap?()
    }

    private var measuredHead: CGFloat = 0

    /// Buttons come and go on the head at moments that can overlap the sheet's own
    /// transitions, where an explicit re-measure was sometimes dropped. Following
    /// the head's real height catches every case.
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard #available(iOS 16.0, *), view.bounds.width > 0 else { return }
        let height = head.systemLayoutSizeFitting(
            CGSize(width: view.bounds.width, height: 0),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel).height
        guard abs(height - measuredHead) > 0.5 else { return }
        measuredHead = height
        DispatchQueue.main.async { [weak self] in
            guard let sheet = self?.sheetPresentationController else { return }
            sheet.animateChanges { sheet.invalidateDetents() }
        }
    }

    /// How tall the fixed head actually is, so the smallest rest can hug it.
    var headHeight: CGFloat {
        view.layoutIfNeeded()
        return head.systemLayoutSizeFitting(
            CGSize(width: view.bounds.width, height: 0),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel).height + 40
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Translucent, so the dial behind stays faintly present and the sheet
        // reads as a layer rather than a lid. Solid when the reader has asked
        // for less transparency.
        if UIAccessibility.isReduceTransparencyEnabled {
            view.backgroundColor = MeetPalette.surface
        } else {
            view.backgroundColor = .clear
            let material = UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterialDark))
            material.frame = view.bounds
            material.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            let tint = UIView(frame: material.bounds)
            tint.backgroundColor = MeetPalette.surface.withAlphaComponent(0.7)
            tint.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            material.contentView.addSubview(tint)
            view.insertSubview(material, at: 0)
        }
        scroll.showsVerticalScrollIndicator = false
        view.addSubview(head)
        view.addSubview(scroll)
        let tap = UITapGestureRecognizer(target: self, action: #selector(headTapped))
        tap.cancelsTouchesInView = false   // buttons on the head still get their taps
        view.addGestureRecognizer(tap)
        scroll.addSubview(body)
        for v in [head, scroll, body] { v.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            head.topAnchor.constraint(equalTo: view.topAnchor, constant: 26),
            head.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            head.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            scroll.topAnchor.constraint(equalTo: head.bottomAnchor, constant: 14),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            // Inside a scroll view the body keeps its natural height instead of
            // being squeezed into whichever detent the sheet is resting at.
            body.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            body.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            body.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            body.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
        ])
    }
}

// MARK: - The rings for a group

/// Everyone you are connected to, on rings by distance. Only the distance is real:
/// the angle is just where each name sits so the names do not overlap. A phone in
/// Japan does not report a direction, so the rings never pretend to know one.
final class FriendsRadar: UIView {
    struct Friend {
        let id: MCPeerID
        let name: String
        let distance: Float?
        let focused: Bool
    }

    var onSelect: ((MCPeerID) -> Void)?
    var arrivalThreshold: Float = 1.0

    private static let ringCandidates: [Float] = [2, 5, 10, 20, 50, 100]
    /// The edge of the rings, a little past whoever is farthest, so a group that
    /// is all within a few metres still spreads out instead of piling on the centre.
    private var scaleMeters: Float = 30
    private let rings = CAShapeLayer()
    private let you = UIView()
    private var ringLabels: [UILabel] = []
    private var chips: [MCPeerID: UIButton] = [:]
    private var friends: [Friend] = []
    private var moveAnimator: UIViewPropertyAnimator?

    override init(frame: CGRect) {
        super.init(frame: frame)
        rings.fillColor = UIColor.clear.cgColor
        rings.strokeColor = UIColor.white.withAlphaComponent(0.12).cgColor
        rings.lineWidth = 1
        layer.addSublayer(rings)
        you.backgroundColor = MeetPalette.primary
        you.layer.cornerRadius = 5
        you.isAccessibilityElement = false
        addSubview(you)
        for _ in 0..<3 {
            let label = UILabel()
            label.font = Type.caption
            label.textColor = MeetPalette.secondary.withAlphaComponent(0.8)
            label.isAccessibilityElement = false
            addSubview(label)
            ringLabels.append(label)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 0 at the centre, 1 at the edge. Square-root, so the last few metres, where
    /// the search actually happens, get most of the room.
    private func radiusFraction(_ meters: Float) -> CGFloat {
        CGFloat(min(1, (max(0, meters) / scaleMeters).squareRoot()))
    }

    private static func format(_ d: Float) -> String {
        d >= 2 ? String(format: "%.0f m", d.rounded()) : String(format: "%.1f m", d)
    }

    func show(_ next: [Friend]) {
        friends = next
        scaleMeters = max(10, (next.compactMap { $0.distance }.max() ?? 10) * 1.15)
        let ids = Set(next.map { $0.id })
        for (id, chip) in chips where !ids.contains(id) {
            chip.removeFromSuperview()
            chips[id] = nil
        }
        for friend in next {
            let chip = chips[friend.id] ?? makeChip(for: friend.id)
            let arrived = (friend.distance ?? .greatestFiniteMagnitude) < arrivalThreshold
            var conf = chip.configuration ?? .filled()
            conf.title = friend.name
            conf.subtitle = friend.distance.map { $0 < arrivalThreshold ? "見つけた" : Self.format($0) } ?? "測定中…"
            conf.baseBackgroundColor = arrived ? MeetPalette.arrival : (friend.focused ? MeetPalette.action : MeetPalette.raised)
            conf.baseForegroundColor = (arrived || friend.focused) ? MeetPalette.background : MeetPalette.primary
            chip.configuration = conf
            chip.accessibilityLabel = "\(friend.name)、\(conf.subtitle ?? "")"
            chip.accessibilityTraits = friend.focused ? [.button, .selected] : .button
        }
        setNeedsLayout()
        // Readings arrive many times a second, so each one re-targets the running
        // spring instead of queuing behind it.
        moveAnimator = Motion.animate(interrupting: moveAnimator) { self.layoutIfNeeded() }
    }

    private func makeChip(for id: MCPeerID) -> UIButton {
        let chip = UIButton(type: .system)
        var conf = UIButton.Configuration.filled()
        conf.cornerStyle = .capsule
        conf.titleAlignment = .center
        conf.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12)
        conf.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in
            var a = attrs
            a.font = Type.chip
            return a
        }
        conf.subtitleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in
            var a = attrs
            a.font = Type.caption
            return a
        }
        chip.configuration = conf
        chip.addAction(UIAction { [weak self] _ in self?.onSelect?(id) }, for: .touchUpInside)
        addSubview(chip)
        chips[id] = chip
        return chip
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let side = min(bounds.width, bounds.height)
        guard side > 60 else { return }
        let centre = CGPoint(x: bounds.midX, y: bounds.midY)
        // Leave room for a name tag sitting on the outer edge.
        let outer = side / 2 - 28
        let path = UIBezierPath()
        // Halfway between the first two names, where no name tag sits.
        let labelAngle = -CGFloat.pi / 2 + .pi / CGFloat(max(friends.count, 1))
        let shown = Array(Self.ringCandidates.filter { $0 < scaleMeters }.suffix(3))
        for (i, label) in ringLabels.enumerated() {
            guard i < shown.count else { label.isHidden = true; continue }
            let r = outer * radiusFraction(shown[i])
            path.append(UIBezierPath(arcCenter: centre, radius: r, startAngle: 0, endAngle: .pi * 2, clockwise: true))
            label.isHidden = false
            label.text = "\(Int(shown[i])) m"
            label.sizeToFit()
            label.center = CGPoint(x: centre.x + cos(labelAngle) * r, y: centre.y + sin(labelAngle) * r)
        }
        rings.frame = bounds
        rings.path = path.cgPath
        you.frame = CGRect(x: centre.x - 5, y: centre.y - 5, width: 10, height: 10)

        // Evenly spaced, in name order, starting at the top: stable, and plainly
        // not a bearing.
        let ordered = friends.sorted { $0.name < $1.name }
        for (i, friend) in ordered.enumerated() {
            guard let chip = chips[friend.id] else { continue }
            let angle = -CGFloat.pi / 2 + CGFloat(i) * 2 * .pi / CGFloat(ordered.count)
            // Never closer to the centre than a tag's width: once several people
            // were within a metre, their tags piled on one spot and none could be read.
            let r = max(outer * 0.32, outer * radiusFraction(friend.distance ?? scaleMeters))
            chip.bounds = CGRect(origin: .zero, size: chip.intrinsicContentSize)
            chip.center = CGPoint(x: centre.x + cos(angle) * r, y: centre.y + sin(angle) * r)
        }
    }
}

// MARK: - Siri, Shortcuts, Spotlight and the Action button

/// Opening the app is the whole action: the home screen already lists whoever is
/// nearby. It cuts the step the first real pair (2026-09-12) called out, that both
/// people had to find and open the app before anything could happen. Connecting
/// stays a tap on the screen, so a voice command never ranges a stranger.
@available(iOS 16.0, *)
struct OpenKokodayoIntent: AppIntent {
    static let title: LocalizedStringResource = "ここだよを開く"
    static let description = IntentDescription("近くでアプリを開いている相手を表示します。")
    static let openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        .result()
    }
}

/// Listed without any setup in Shortcuts, Spotlight and the Action button picker.
@available(iOS 17.0, *)
struct KokodayoShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: OpenKokodayoIntent(),
                    phrases: ["\(.applicationName)",
                              "\(.applicationName)を開く",
                              "\(.applicationName)で待ち合わせ"],
                    shortTitle: "ここだよを開く",
                    systemImageName: "person.2")
    }
}

// MARK: - Welcome

/// The first run: how finding each other works, the one rule that drops the link,
/// and the name the other phone will see.
final class WelcomeViewController: UIViewController, UITextFieldDelegate {
    var onDone: ((String) -> Void)?

    private let field = UITextField()
    private let continueButton = UIButton(type: .system)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = MeetPalette.background
        isModalInPresentation = true   // the name is needed before anything connects

        let title = UILabel()
        title.text = "「ここだよ」へようこそ"
        title.font = Type.font(30, .bold, .largeTitle)
        title.textColor = MeetPalette.primary
        title.textAlignment = .center
        title.numberOfLines = 0

        let features = UIStackView(arrangedSubviews: [
            featureRow(symbol: "link",
                       title: "招待した人とだけつながる",
                       detail: "リンクを受け取り、ホストが許可した人どうしで距離が見えます。朝4時に自動で消えます。"),
            featureRow(symbol: "figure.walk",
                       title: "歩くと向きがわかる",
                       detail: "近づくと「近づいています」、離れると「離れています」と表示されます。"),
            featureRow(symbol: "iphone.radiowaves.left.and.right",
                       title: "2人ともアプリを開いたままに",
                       detail: "アプリを閉じると、接続が切れます。"),
        ])
        features.axis = .vertical
        features.spacing = 22

        let nameTitle = UILabel()
        nameTitle.text = "表示名"
        nameTitle.font = Type.captionStrong
        nameTitle.textColor = MeetPalette.secondary

        field.attributedPlaceholder = NSAttributedString(
            string: "例: たぬま",
            attributes: [.foregroundColor: MeetPalette.secondary.withAlphaComponent(0.7)])
        field.font = Type.body
        field.textColor = MeetPalette.primary
        field.tintColor = MeetPalette.action
        field.backgroundColor = MeetPalette.surface
        field.layer.cornerRadius = 12
        field.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 14, height: 1))
        field.leftViewMode = .always
        field.clearButtonMode = .whileEditing
        field.autocorrectionType = .no
        field.returnKeyType = .done
        field.delegate = self
        field.addTarget(self, action: #selector(nameChanged), for: .editingChanged)
        field.heightAnchor.constraint(equalToConstant: 50).isActive = true

        let nameFooter = UILabel()
        nameFooter.text = "近くの相手にこの名前で表示されます。あとで変更できます。"
        nameFooter.font = Type.caption
        nameFooter.textColor = MeetPalette.secondary
        nameFooter.numberOfLines = 0

        let name = UIStackView(arrangedSubviews: [nameTitle, field, nameFooter])
        name.axis = .vertical
        name.spacing = 8

        let content = UIStackView(arrangedSubviews: [title, features, name])
        content.axis = .vertical
        content.spacing = 40

        let scroll = UIScrollView()
        scroll.keyboardDismissMode = .interactive
        scroll.alwaysBounceVertical = true
        scroll.addSubview(content)

        var conf = UIButton.Configuration.filled()
        conf.title = "続ける"
        conf.baseBackgroundColor = MeetPalette.action
        conf.baseForegroundColor = MeetPalette.background
        conf.cornerStyle = .large
        conf.contentInsets = NSDirectionalEdgeInsets(top: 16, leading: 20, bottom: 16, trailing: 20)
        conf.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in
            var a = attrs
            a.font = Type.font(17, .semibold, .headline)
            return a
        }
        continueButton.configuration = conf
        continueButton.isEnabled = false
        continueButton.addTarget(self, action: #selector(finish), for: .touchUpInside)

        view.addSubview(scroll)
        view.addSubview(continueButton)
        for v in [scroll, content, continueButton] as [UIView] { v.translatesAutoresizingMaskIntoConstraints = false }
        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: safe.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: continueButton.topAnchor, constant: -12),

            content.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 44),
            content.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -16),
            content.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 32),
            content.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -32),
            content.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -64),

            continueButton.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 24),
            continueButton.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -24),
            // Rides up with the keyboard, so 続ける is never under it.
            continueButton.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -16),
        ])
        for label in [title, nameTitle, nameFooter] { label.adjustsFontForContentSizeCategory = true }
    }

    private func featureRow(symbol: String, title: String, detail: String) -> UIView {
        let icon = UIImageView(image: UIImage(systemName: symbol))
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 28, weight: .regular)
        icon.tintColor = MeetPalette.action
        icon.contentMode = .center
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 44).isActive = true

        let heading = UILabel()
        heading.text = title
        heading.font = Type.font(15, .semibold, .headline)
        heading.textColor = MeetPalette.primary
        heading.numberOfLines = 0
        heading.adjustsFontForContentSizeCategory = true

        let body = UILabel()
        body.text = detail
        body.font = Type.font(15, .regular, .subheadline)
        body.textColor = MeetPalette.secondary
        body.numberOfLines = 0
        body.adjustsFontForContentSizeCategory = true

        let words = UIStackView(arrangedSubviews: [heading, body])
        words.axis = .vertical
        words.spacing = 2

        let row = UIStackView(arrangedSubviews: [icon, words])
        row.alignment = .center
        row.spacing = 16
        return row
    }

    @objc private func nameChanged() {
        continueButton.isEnabled = !(field.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if continueButton.isEnabled { finish() }
        return true
    }

    @objc private func finish() {
        view.endEditing(true)
        let name = (field.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let done = onDone
        dismiss(animated: true) { done?(name) }
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
    static var reading: UIFont { font(30, .bold, .title1) }
    /// The screen's whole job is "how far". The number gets to dominate.
    static var dial: UIFont { font(56, .bold, .largeTitle) }
    static var title: UIFont { font(26, .bold, .title2) }          // 到着の目印
    static var headline: UIFont { font(20, .semibold, .title3) }   // 画面の状態
    static var appName: UIFont { font(17, .bold, .headline) }
    static var button: UIFont { font(15, .semibold, .body) }
    static var body: UIFont { font(15, .regular, .body) }
    static var chip: UIFont { font(13, .semibold, .subheadline) }
    static var label: UIFont { font(13, .regular, .subheadline) }
    static var caption: UIFont { font(13, .regular, .caption1) }
    static var captionStrong: UIFont { font(13, .semibold, .caption1) }

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
    /// 目盛りは transitions.dev に合わせた（押し込みは --scale-small 0.98、
    /// 押すのは速く --duration-quick、戻るのは --duration-fast、曲線は smooth-out）。
    /// 薄くするのはやめた。向こうは大きさだけで押した感じを出している。
    static func press(_ view: UIView, down: Bool) {
        guard !reduced else { return }
        Trans.run(Trans.smoothOut(down ? Trans.quick : Trans.fast)) {
            view.transform = down ? CGAffineTransform(scaleX: Trans.pressScale, y: Trans.pressScale) : .identity
            view.alpha = 1
        }
    }
}

// MARK: - Helpers

/// A pressed seal: a thin gold ring that settles in with a small overshoot, and
/// two hairline ripples that go out once. The arrival mark on the camera view.
final class SealMark: UIView {
    private let ring = CAShapeLayer()
    private let ripples: [CAShapeLayer] = [CAShapeLayer(), CAShapeLayer()]

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        ring.fillColor = UIColor.clear.cgColor
        ring.strokeColor = MeetPalette.ink.cgColor
        ring.lineWidth = 1.5
        ring.opacity = 0
        layer.addSublayer(ring)
        for ripple in ripples {
            ripple.fillColor = UIColor.clear.cgColor
            ripple.strokeColor = MeetPalette.ink.cgColor
            ripple.lineWidth = 1
            ripple.opacity = 0
            layer.addSublayer(ripple)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let centre = CGPoint(x: bounds.midX, y: bounds.midY)
        let outer = min(bounds.width, bounds.height) / 2
        ring.path = UIBezierPath(arcCenter: centre, radius: outer * 0.46, startAngle: 0,
                                 endAngle: .pi * 2, clockwise: true).cgPath
        for ripple in ripples {
            ripple.path = UIBezierPath(arcCenter: centre, radius: outer, startAngle: 0,
                                       endAngle: .pi * 2, clockwise: true).cgPath
            ripple.bounds = bounds
            ripple.position = centre
        }
        ring.bounds = bounds
        ring.position = centre
    }

    func press() {
        let press = CAKeyframeAnimation(keyPath: "transform.scale")
        press.values = [0.86, 1.03, 1]
        press.keyTimes = [0, 0.6, 1]
        press.duration = 0.55
        press.timingFunction = CAMediaTimingFunction(name: .easeOut)
        ring.opacity = 1
        ring.add(press, forKey: "press")
        for (index, ripple) in ripples.enumerated() {
            let grow = CABasicAnimation(keyPath: "transform.scale")
            grow.fromValue = 0.2
            grow.toValue = 1.12
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.8
            fade.toValue = 0
            let group = CAAnimationGroup()
            group.animations = [grow, fade]
            group.duration = 1.1
            group.beginTime = CACurrentMediaTime() + 0.2 * Double(index)
            group.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ripple.add(group, forKey: "ripple")
        }
    }
}

class PaddedLabel: UILabel {
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
