// 動きの目盛り — transitions.dev から写したもの。
//
// 出どころ: https://github.com/Jakubantalik/transitions.dev
//   skills/transitions-dev/_root.css（目盛り）と 22-toast.md（知らせの出方）
//   2026-09-24 に読んだ値をそのまま置いている。数字は自分で決めない。
//
// 向こうはWebのCSS、こちらはUIKit。移せないものが1つある:
//   ぼかし（blur 2px）は、CSSなら1行だがUIKitには動かせる仕組みが無い。
//   ここでは入れていない。ぼかし以外（時間・曲線・距離・大きさ）はそのまま。
//
// 決めごと:
//  - 開くのはゆっくり、閉じるのは速い（届くのは丁寧に、去るのは軽く）
//  - 動きを減らす設定の人には動かさない（向こうの prefers-reduced-motion と同じ）
import UIKit

enum Trans {

    // MARK: - 時間（_root.css の Durations）

    static let stagger: TimeInterval = 0.04
    static let micro: TimeInterval = 0.08
    static let quick: TimeInterval = 0.15      // 文字の入れ替え、閉じる動き
    static let fast: TimeInterval = 0.25       // 開く動き、タブの移動
    static let medium: TimeInterval = 0.35     // 知らせが出る
    static let slow: TimeInterval = 0.40
    static let verySlow: TimeInterval = 0.50

    // MARK: - 距離・大きさ（Distances / Scales）

    static let textSwapDistance: CGFloat = 4
    static let toastDistance: CGFloat = 16
    static let toastScale: CGFloat = 0.97
    static let pressScale: CGFloat = 0.98      // --scale-small
    static let liftScale: CGFloat = 1.05       // アバター列の持ち上がり

    // MARK: - 曲線（Easings）

    /// --ease-smooth-out。開く・閉じる・位置が変わるときの既定。
    static func smoothOut(_ duration: TimeInterval) -> UIViewPropertyAnimator {
        UIViewPropertyAnimator(duration: duration,
                               controlPoint1: CGPoint(x: 0.22, y: 1),
                               controlPoint2: CGPoint(x: 0.36, y: 1))
    }

    /// --ease-bounce。小さく跳ねて止まる（選んだ印など）。
    static func bounce(_ duration: TimeInterval) -> UIViewPropertyAnimator {
        UIViewPropertyAnimator(duration: duration,
                               controlPoint1: CGPoint(x: 0.34, y: 1.36),
                               controlPoint2: CGPoint(x: 0.64, y: 1))
    }

    /// --ease-in-out。文字の入れ替え。
    static func inOut(_ duration: TimeInterval) -> UIViewPropertyAnimator {
        UIViewPropertyAnimator(duration: duration,
                               controlPoint1: CGPoint(x: 0.42, y: 0),
                               controlPoint2: CGPoint(x: 0.58, y: 1))
    }

    static var reduced: Bool { UIAccessibility.isReduceMotionEnabled }

    /// 動きを減らす設定なら、その場で変える。
    static func run(_ animator: @autoclosure () -> UIViewPropertyAnimator,
                    _ changes: @escaping () -> Void,
                    done: (() -> Void)? = nil) {
        guard !reduced else {
            changes()
            done?()
            return
        }
        let a = animator()
        a.addAnimations(changes)
        if let done { a.addCompletion { _ in done() } }
        a.startAnimation()
    }
}

/// 知らせの出方（22-toast.md）。
/// 下から16px上がりながら、薄いところと小さいところ（0.97倍）から戻る。
/// 開きは350ms、閉じは250ms。同じ曲線で、時間だけ変える。
final class ToastView: PaddedLabel {

    private var hideTimer: Timer?
    private var shown = false

    init() {
        super.init(frame: .zero)
        font = Type.captionStrong
        textColor = MeetPalette.primary
        backgroundColor = MeetPalette.raised
        textAlignment = .center
        numberOfLines = 2
        insets = UIEdgeInsets(top: 12, left: 18, bottom: 12, right: 18)
        layer.cornerRadius = 22
        layer.cornerCurve = .continuous
        clipsToBounds = false
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.35
        layer.shadowRadius = 12
        layer.shadowOffset = CGSize(width: 0, height: 6)
        isAccessibilityElement = true
        accessibilityTraits = .staticText
        alpha = 0
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        roundCorners()
    }

    /// 高さが決まってから丸める。隠れている間は高さがほぼ0で、
    /// そのときの値のままだと角が立った四角に見えた。
    private func roundCorners() {
        layer.cornerRadius = max(12, min(22, bounds.height / 2))
    }

    /// 出す。出ている最中に次が来たら、文字だけを入れ替える（出し直さない）。
    func show(_ text: String, for seconds: TimeInterval = 6) {
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            self?.hide()
        }
        UIAccessibility.post(notification: .announcement, argument: text)

        guard shown else {
            self.text = text
            shown = true
            isHidden = false
            superview?.bringSubviewToFront(self)
            superview?.layoutIfNeeded()
            roundCorners()
            alpha = 0
            transform = CGAffineTransform(translationX: 0, y: Trans.toastDistance)
                .scaledBy(x: Trans.toastScale, y: Trans.toastScale)
            Trans.run(Trans.smoothOut(Trans.medium)) {
                self.alpha = 1
                self.transform = .identity
            }
            return
        }
        // 04-text-states-swap: 4px ずらしながら150msで入れ替える。
        guard self.text != text else { return }
        Trans.run(Trans.inOut(Trans.quick)) {
            self.alpha = 0
            self.transform = CGAffineTransform(translationX: 0, y: -Trans.textSwapDistance)
        } done: {
            self.text = text
            self.transform = CGAffineTransform(translationX: 0, y: Trans.textSwapDistance)
            Trans.run(Trans.inOut(Trans.quick)) {
                self.alpha = 1
                self.transform = .identity
            }
        }
    }

    /// 引っ込める。開くより速い。
    func hide() {
        hideTimer?.invalidate()
        hideTimer = nil
        guard shown else { return }
        shown = false
        Trans.run(Trans.smoothOut(Trans.fast)) {
            self.alpha = 0
            self.transform = CGAffineTransform(translationX: 0, y: Trans.toastDistance)
                .scaledBy(x: Trans.toastScale, y: Trans.toastScale)
        } done: {
            self.isHidden = true
            self.transform = .identity
        }
    }
}
