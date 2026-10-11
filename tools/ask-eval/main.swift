// 「AIに頼む」の読み取りを測る。A = 言葉の規則だけ、B = アプリと同じ（規則 → 残りをAI）。
// 10/2: 前の言い方17文（本人が実際に使った言い方）＋新しい言い方15文＋守り2文。
import Foundation

struct Case {
    let text: String; let kind: AskIntent.Kind; var check: ((AskIntent) -> Bool)? = nil; let group: String
    /// true なら「kind ではない」ことを確かめる（守り）。
    var not = false
}
func q(_ s: String) -> (AskIntent) -> Bool { { $0.query.contains(s) } }
func go(_ s: String) -> (AskIntent) -> Bool { { $0.go && $0.query.contains(s) } }
func near(_ w: String, _ n: String) -> (AskIntent) -> Bool { { $0.query.contains(w) && $0.near.contains(n) } }
func items(_ xs: [String]) -> (AskIntent) -> Bool { { i in xs.allSatisfy { x in i.items.contains { $0.contains(x) } } } }
let partner = "たぬき"
let cases: [Case] = [
    Case(text: "ちょっと遅れるって言っといて", kind: .mood, group: "前"),
    Case(text: "改札の前で待ってると伝えて", kind: .mood, group: "前"),
    Case(text: "ラゾーナに案内して", kind: .place, check: go("ラゾーナ"), group: "前"),
    Case(text: "東京駅に連れてって", kind: .place, check: go("東京駅"), group: "前"),
    Case(text: "いちばん近い駅", kind: .place, check: q("駅"), group: "前"),
    Case(text: "なんからーめん食べたい", kind: .place, check: q("ラーメン"), group: "前"),
    Case(text: "カラオケ行きたいな", kind: .place, check: q("カラオケ"), group: "前"),
    Case(text: "赤坂駅付近ランチ", kind: .place, check: near("ランチ", "赤坂"), group: "前"),
    Case(text: "渋谷でラーメン", kind: .place, check: near("ラーメン", "渋谷"), group: "前"),
    Case(text: "雨でも静かに作業できるところ", kind: .place, group: "前"),
    Case(text: "帰りにパンとお茶買ってきて", kind: .errand, check: items(["パン", "お茶"]), group: "前"),
    Case(text: "たぬきと中間で会いたい、カフェで", kind: .meet, group: "前"),
    Case(text: "たぬきのところへの行き方", kind: .route, group: "前"),
    Case(text: "7時までに来なかったら教えて", kind: .watch, group: "前"),
    Case(text: "2時間ひまつぶし", kind: .killTime, group: "前"),
    Case(text: "スタバ何時まで？", kind: .placeInfo, group: "前"),
    Case(text: "途中でコーヒー買える所", kind: .onTheWay, group: "前"),
    Case(text: "お腹ぺこぺこ、なんか食べたい", kind: .place, check: q("ごはん"), group: "新"),
    Case(text: "ちょい遅刻しそう", kind: .mood, group: "新"),
    Case(text: "先に着いたから店の前にいるねって送っといて", kind: .mood, group: "新"),
    Case(text: "牛乳切れてたから帰り寄ってもらえる？", kind: .errand, check: items(["牛乳"]), group: "新"),
    Case(text: "たぬきってどうやって行けばいい？", kind: .route, group: "新"),
    Case(text: "どっかで落ち合おう", kind: .meet, group: "新"),
    Case(text: "疲れたから座って休めるとこ", kind: .place, group: "新"),
    Case(text: "ドンキまで道案内お願い", kind: .place, check: go("ドンキ"), group: "新"),
    Case(text: "8時過ぎても来ないなら知らせて", kind: .watch, group: "新"),
    Case(text: "映画まで40分あるけど何しよう", kind: .killTime, group: "新"),
    Case(text: "ラゾーナって何時に閉まる？", kind: .placeInfo, group: "新"),
    Case(text: "新宿駅の近くで焼肉", kind: .place, check: near("焼肉", "新宿"), group: "新"),
    Case(text: "たぬきに今起きたって伝えといて", kind: .mood, group: "新"),
    Case(text: "卵と納豆おつかい頼む", kind: .errand, check: items(["卵", "納豆"]), group: "新"),
    Case(text: "駅前で待ち合わせしよう", kind: .meet, group: "新"),
    // 10/11 実機：店の名前だけの頼み（AIは「駅で会う」と読んだ）。
    Case(text: "一蘭", kind: .place, check: q("一蘭"), group: "名"),
    Case(text: "一蘭どこ", kind: .place, check: q("一蘭"), group: "名"),
    Case(text: "一蘭食べたい", kind: .place, check: q("一蘭"), group: "名"),
    Case(text: "一蘭行きたい", kind: .place, check: q("一蘭"), group: "名"),
    Case(text: "スタバ", kind: .place, check: q("スタバ"), group: "名"),
    // 守り：足した言葉が、別の頼みを横取りしないか。
    Case(text: "パン食べたいから買ってきて", kind: .errand, check: items(["パン"]), group: "守"),
    // 車で送ってほしい頼み。アプリにその機能は無いが、相手への伝言（mood）に化けないこと。
    Case(text: "駅まで送って", kind: .mood, group: "守", not: true),
]
func ok(_ i: AskIntent, _ c: Case) -> Bool { c.not ? i.kind != c.kind : (i.kind == c.kind && (c.check?(i) ?? true)) }
func show(_ i: AskIntent) -> String { "\(i.kind.rawValue) q=\(i.query) near=\(i.near) go=\(i.go) items=\(i.items) mood=\(i.mood)" }

let done = DispatchSemaphore(value: 0)
Task {
    var a: [String: Int] = [:], b: [String: Int] = [:], n: [String: Int] = [:]
    for c in cases {
        let ra = AskParser.keywordParse(c.text, partner: partner)
        let (rb, usedAI) = await AskParser.parse(c.text, partner: partner)
        n[c.group, default: 0] += 1
        if ok(ra, c) { a[c.group, default: 0] += 1 }
        if ok(rb, c) { b[c.group, default: 0] += 1 }
        if !ok(rb, c) || !ok(ra, c) {
            print("[\(c.group)] \(c.text)\n  A\(ok(ra, c) ? "○" : "×") \(show(ra))\n  B\(ok(rb, c) ? "○" : "×")\(usedAI ? "(AI)" : "") \(show(rb))")
        }
    }
    for g in ["前", "新", "名", "守"] {
        print("\(g): A \(a[g, default: 0])/\(n[g]!)  B \(b[g, default: 0])/\(n[g]!)")
    }
    done.signal()
}
done.wait()
