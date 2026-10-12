// アプリの「決め方」の網羅テスト。画面や電波を使わず、決めるだけの小さな関数をアプリのコードのまま確かめる。
// 実機で本人が見つけた食い違いを、二度と戻さないために置く（どれも日付と元の報告をコメントに残す）。
// 「AIに頼む」をAIで読む部分は、iPhoneと同じ内蔵AIが要るのでここでは回さない（tools/ask-eval/run.sh を手元で）。
import XCTest
import CoreLocation
@testable import NIPeekaboo

final class GPSAndDistanceTests: XCTestCase {
    /// 9/29 実機：本当は2mなのに15mと出た。GPSの誤差の内は数字を出さず「すぐ近く」。
    func testWithinGPSError() {
        XCTAssertTrue(NearbyAlert.withinGPSError(metres: 15, accuracy: 10))
        XCTAssertTrue(NearbyAlert.withinGPSError(metres: 19, accuracy: 5), "下限20m")
        XCTAssertFalse(NearbyAlert.withinGPSError(metres: 60, accuracy: 10))
        XCTAssertTrue(NearbyAlert.withinGPSError(metres: 60, accuracy: 35), "誤差×2まで")
    }

    func testDistanceWords() {
        XCTAssertEqual(NearbyAlert.text(15), "15m")
        XCTAssertEqual(NearbyAlert.text(1000), "1km")
        XCTAssertEqual(NearbyAlert.text(2400), "2.4km")
        XCTAssertEqual(NearbyAlert.walkText(10), "歩いて約1分", "最低1分")
        XCTAssertEqual(NearbyAlert.walkText(800), "歩いて約10分")
    }

    /// 9/27「相手との位置が大きくズレる」：古い位置・誤差の大きい位置は使わない。
    func testLocationUsable() {
        let now = Date()
        let start = now.addingTimeInterval(-5)
        func loc(acc: Double, age: TimeInterval) -> CLLocation {
            CLLocation(coordinate: .init(latitude: 35.53, longitude: 139.69), altitude: 0,
                       horizontalAccuracy: acc, verticalAccuracy: 5, timestamp: now.addingTimeInterval(-age))
        }
        XCTAssertTrue(LocationPlan.usable(loc(acc: 10, age: 1), last: nil, startedAt: start, now: now))
        XCTAssertFalse(LocationPlan.usable(loc(acc: -1, age: 1), last: nil, startedAt: start, now: now), "無効")
        XCTAssertFalse(LocationPlan.usable(loc(acc: 10, age: 30), last: nil, startedAt: start, now: now), "取り置きの古い位置")
        XCTAssertFalse(LocationPlan.usable(loc(acc: 300, age: 1), last: nil, startedAt: start, now: now), "取り始めは粗いのを待つ")
    }

    /// 遠いあいだは粗く・間をあけて取る（電池）。案内中だけ細かく。
    func testLocationPlanByDistance() {
        XCTAssertEqual(LocationPlan.settings(partnerMetres: 50, navigating: true).filter, 2)
        XCTAssertEqual(LocationPlan.settings(partnerMetres: 100, navigating: false).filter, 5)
        XCTAssertEqual(LocationPlan.settings(partnerMetres: 1500, navigating: false).filter, 15)
        XCTAssertEqual(LocationPlan.settings(partnerMetres: 5000, navigating: false).accuracy, kCLLocationAccuracyHundredMeters)
    }
}

final class NearbyNoticeTests: XCTestCase {
    private let room = "test-\(UUID().uuidString)"
    override func tearDown() { ApproachWatcher.forget(room: room) }

    /// 10/3 段3：閉じていても近づいたら知らせる。読み直しても（裏の起動でも）二度は鳴らない。
    func testApproachFiresOnceAcrossReloads() {
        var w = ApproachWatcher.load(room: room)
        XCTAssertFalse(w.step(metres: 5000, threshold: 3000))
        w.save(room: room)
        var w2 = ApproachWatcher.load(room: room)
        XCTAssertTrue(w2.step(metres: 2800, threshold: 3000))
        w2.save(room: room)
        var w3 = ApproachWatcher.load(room: room)
        XCTAssertFalse(w3.step(metres: 2500, threshold: 3000))
    }

    /// つないだ時に既に近ければ鳴らさない。
    func testAlreadyNearDoesNotFire() {
        var w = ApproachWatcher()
        XCTAssertFalse(w.step(metres: 1000, threshold: 3000))
    }

    /// 相手の端末がもう2人に知らせていたら（2時間以内）黙る。
    func testPartnerAlreadyTold() {
        let now = Date()
        XCTAssertTrue(ApproachWatcher.shouldTell(fired: true, partnerAlertAt: nil) == (true, true))
        XCTAssertTrue(ApproachWatcher.shouldTell(fired: true, partnerAlertAt: (now.timeIntervalSince1970 - 600) * 1000, now: now) == (false, false))
        XCTAssertTrue(ApproachWatcher.shouldTell(fired: true, partnerAlertAt: (now.timeIntervalSince1970 - 3 * 3600) * 1000, now: now) == (true, true))
        XCTAssertTrue(ApproachWatcher.shouldTell(fired: false, partnerAlertAt: nil) == (false, false))
    }

    /// 10/3「近くならマップ側ではない機能使って」：近づいたら探す画面へ。閉じたら離れるまで開き直さない。
    func testAutoFind() {
        XCTAssertTrue(NearbyAlert.autoFind(near: true, far: false, latched: false, busy: false) == (true, true))
        XCTAssertTrue(NearbyAlert.autoFind(near: true, far: false, latched: true, busy: false) == (false, true))
        XCTAssertTrue(NearbyAlert.autoFind(near: false, far: true, latched: true, busy: false) == (false, false))
        XCTAssertTrue(NearbyAlert.autoFind(near: true, far: false, latched: false, busy: true) == (false, false))
    }

    /// 前の版が残した居場所（alert の欄が無い）も読める。
    func testOldRemoteFixDecodes() throws {
        let old = #"{"lat":35.5,"lon":139.7,"acc":10,"at":1790000000000}"#.data(using: .utf8)!
        let fix = try JSONDecoder().decode(RemoteFix.self, from: old)
        XCTAssertNil(fix.alert)
    }

    /// 10/3「一回繋いだら解除しない限りは繋いでていい」：友だちとのつながりは「やめるまで」。
    func testUntilStopped() {
        XCTAssertTrue(MeetViewController.isUntilStopped(MeetViewController.untilStopped))
        XCTAssertFalse(MeetViewController.isUntilStopped(Date().addingTimeInterval(24 * 3600)))
    }
}

final class ErrandTests: XCTestCase {
    /// 10/3「買わずに近づいたら通知して」：遠くから1kmに入ったら1回。頼んだ時に既に近ければ鳴らさない。
    func testReminder() {
        var r = ErrandReminder.step(left: 2, metres: 1500, armed: false, reminded: false)
        XCTAssertFalse(r.remind); XCTAssertTrue(r.armed)
        r = ErrandReminder.step(left: 2, metres: 900, armed: r.armed, reminded: false)
        XCTAssertTrue(r.remind)
        XCTAssertFalse(ErrandReminder.step(left: 2, metres: 800, armed: true, reminded: true).remind, "二度目は無い")
        XCTAssertFalse(ErrandReminder.step(left: 2, metres: 500, armed: false, reminded: false).remind, "頼んだ時に既に近い")
        XCTAssertFalse(ErrandReminder.step(left: 0, metres: 900, armed: true, reminded: false).remind, "全部買った")
    }
}

final class FloorMapTests: XCTestCase {
    /// 9/29：半径220mのままだと15m先の相手が自分の三角の下に隠れた。近いほど寄る。
    func testRadius() {
        XCTAssertEqual(GroundMap.radius(toPeer: nil), 220)
        XCTAssertEqual(GroundMap.radius(toPeer: 15), 40)
        XCTAssertEqual(GroundMap.radius(toPeer: 50), 125)
        XCTAssertEqual(GroundMap.radius(toPeer: 500), 220)
    }

    func testRedraw() {
        XCTAssertTrue(GroundMap.needsRedraw(moved: 0, radius: 220, shownRadius: 0, headingChange: 0, routeChanged: false))
        XCTAssertFalse(GroundMap.needsRedraw(moved: 2, radius: 40, shownRadius: 40, headingChange: 20, routeChanged: false))
        XCTAssertTrue(GroundMap.needsRedraw(moved: 0, radius: 40, shownRadius: 40, headingChange: 40, routeChanged: false))
        XCTAssertTrue(GroundMap.needsRedraw(moved: 0, radius: 40, shownRadius: 220, headingChange: 0, routeChanged: false))
        XCTAssertEqual(GroundMap.angleGap(350, 10), 20)
        XCTAssertEqual(GroundMap.angleGap(0, 180), 180)
    }
}

final class OpenPOITests: XCTestCase {
    /// 10/2：OpenPOIは名前で探すので、店の名前に入る種類の言葉だけで使う（「ランチ」で「フランチャイズ募集」が出た）。
    func testUsable() {
        XCTAssertTrue(OpenPOI.usable(for: "ラーメン"))
        XCTAssertTrue(OpenPOI.usable(for: "カラオケ"))
        XCTAssertTrue(OpenPOI.usable(for: "ラーメン屋"))
        XCTAssertFalse(OpenPOI.usable(for: "ランチ"))
        XCTAssertFalse(OpenPOI.usable(for: "コンビニ"))
        XCTAssertFalse(OpenPOI.usable(for: "ラゾーナ"), "施設の名前には使わない")
    }

    func testParse() {
        let json = #"{"count":2,"results":[{"name":"春木屋","prefecture":"神奈川県","city":"川崎市","address":"","lat":35.53,"lng":"139.69"},{"name":"","lat":1,"lng":2}]}"#
        let hits = OpenPOI.parse(json.data(using: .utf8)!)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.longitude, 139.69)
        XCTAssertEqual(hits.first?.address, "神奈川県川崎市")
    }

    func testDuplicate() {
        let here = CLLocation(latitude: 35.53, longitude: 139.69)
        XCTAssertTrue(OpenPOI.isDuplicate(.init(name: "春木屋", latitude: 35.6, longitude: 139.7, address: ""), of: [("春木屋", here)]))
        XCTAssertTrue(OpenPOI.isDuplicate(.init(name: "神座ラーメン川崎駅北口", latitude: 35.5301, longitude: 139.69, address: ""),
                                          of: [("神座 川崎店", here)]))
        XCTAssertFalse(OpenPOI.isDuplicate(.init(name: "舎鈴", latitude: 35.5301, longitude: 139.69, address: ""), of: [("春木屋", here)]))
    }
}

final class AskRuleTests: XCTestCase {
    /// AIを使わない「言葉の規則」だけで決まるもの。本人が実際に使った言い方と、10/2 に直した3つ。
    private func read(_ text: String) -> AskIntent { AskParser.keywordParse(text, partner: "たぬき") }

    func testKinds() {
        XCTAssertEqual(read("ちょっと遅れるって言っといて").kind, .mood)
        XCTAssertEqual(read("7時までに来なかったら教えて").kind, .watch)
        XCTAssertEqual(read("2時間ひまつぶし").kind, .killTime)
        XCTAssertEqual(read("スタバ何時まで？").kind, .placeInfo)
        XCTAssertEqual(read("途中でコーヒー買える所").kind, .onTheWay)
        XCTAssertEqual(read("たぬきのところへの行き方").kind, .route)
        XCTAssertEqual(read("帰りにパンとお茶買ってきて").items, ["パン", "お茶"])
    }

    func testGoAndQuery() {
        let laz = read("ラゾーナに案内して")
        XCTAssertTrue(laz.go); XCTAssertEqual(laz.query, "ラゾーナ")
        XCTAssertEqual(read("なんからーめん食べたい").query, "ラーメン")
        XCTAssertEqual(read("カラオケ行きたいな").query, "カラオケ")
    }

    /// 10/2 に直した3つ（Macの内蔵AIで測って、AIが読み違えたもの）。
    func testFixedOn1002() {
        XCTAssertEqual(read("お腹ぺこぺこ、なんか食べたい").query, "ごはん")
        XCTAssertEqual(read("先に着いたから店の前にいるねって送っといて").kind, .mood)
        let donki = read("ドンキまで道案内お願い")
        XCTAssertTrue(donki.go); XCTAssertEqual(donki.query, "ドンキ")
        XCTAssertNotEqual(read("駅まで送って").kind, .mood, "送っては伝言に化けない")
        XCTAssertEqual(read("パン食べたいから買ってきて").kind, .errand, "食べたいがおつかいを横取りしない")
    }

    /// 10/11 実機：「一蘭」を探しても出てこなかった。店の名前は名前のまま探す。
    func testShopNames() {
        XCTAssertEqual(read("一蘭").query, "一蘭")
        XCTAssertEqual(read("一蘭どこ").query, "一蘭")
        XCTAssertEqual(read("一蘭食べたい").query, "一蘭", "食べたいで「ごはん」に化けない")
        XCTAssertEqual(read("お腹ぺこぺこ、なんか食べたい").query, "ごはん")
        XCTAssertTrue(AskParser.looksLikeName("一蘭"))
        XCTAssertTrue(AskParser.looksLikeName("ラゾーナ川崎"))
        XCTAssertFalse(AskParser.looksLikeName("で落ち合おう"))
        XCTAssertFalse(AskParser.looksLikeName("疲れたから座って休めるとこ"))
    }

    /// 10/11 本人が実際に頼んだ言葉。
    func testRealRequestsOn1011() {
        XCTAssertEqual(read("ラーメン食べたい一蘭").query, "一蘭")
        let bento = read("お弁当を買いたいんよ")
        XCTAssertEqual(bento.kind, .place); XCTAssertEqual(bento.query, "お弁当")
        let hacchou = read("八丁畷駅の周りに10時過ぎまでやってるお弁当屋さんとかある？")
        XCTAssertEqual(hacchou.kind, .place); XCTAssertEqual(hacchou.near, "八丁畷駅"); XCTAssertTrue(hacchou.query.contains("弁当"))
        XCTAssertFalse(read("ねむい").words.isEmpty, "休める所を探す")
        XCTAssertEqual(read("帰りにパンとお茶買ってきて").kind, .errand, "買ってきてはおつかいのまま")
    }
}

final class NearbyConnectionTests: XCTestCase {
    /// 10/11 実機：2台が同時に招待し合うとつながりが落ち着かない。招待するのは必ず片方だけ。
    func testExactlyOneSideInvites() {
        let pairs = [("k1A2B3C4D", "k5ECBB103"), ("kFFFFFFFF", "k00000000"), ("kabc", "kabd")]
        for (a, b) in pairs {
            XCTAssertNotEqual(MPCSession.shouldInvite(local: a, remote: b), MPCSession.shouldInvite(local: b, remote: a),
                              "\(a) と \(b) のどちらか一方だけが招待する")
        }
    }
}

/// 10/11 本人「歩くとカクカクする」：1人のとき、地図の中心が自分に少しずつ付いていく。
final class WalkFollowTests: XCTestCase {
    private let start = CLLocationCoordinate2D(latitude: 35.5313, longitude: 139.6966)

    private func metres(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }

    func testEaseDoesNotDependOnFrameRate() {
        // 60回/秒で1秒と、120回/秒で1秒は、ほぼ同じだけ近づく。
        var at60 = 1.0, at120 = 1.0
        for _ in 0..<60 { at60 *= 1 - MeetMapViewController.ease(dt: 1.0 / 60, tau: 0.25) }
        for _ in 0..<120 { at120 *= 1 - MeetMapViewController.ease(dt: 1.0 / 120, tau: 0.25) }
        XCTAssertEqual(at60, at120, accuracy: 0.001)
        XCTAssertEqual(MeetMapViewController.ease(dt: 0, tau: 0.25), 1)
    }

    func testWalkingStepIsSpreadOverFrames() {
        // 歩いて5m先の位置が届いても、1回の描き直しで飛ぶのは1m未満。
        let target = MeetMapViewController.offset(start, bearing: 0, metres: 5)
        var center = start
        let k = MeetMapViewController.ease(dt: 1.0 / 60, tau: 0.25)
        var biggest = 0.0
        for _ in 0..<60 {
            let next = MeetMapViewController.followCenter(from: center, to: target, fraction: k)
            biggest = max(biggest, metres(center, next))
            center = next
        }
        XCTAssertLessThan(biggest, 1)
        XCTAssertLessThan(metres(center, target), 0.3, "1秒で追いつく")
    }

    func testFarAwayJumpsAtOnce() {
        let far = MeetMapViewController.offset(start, bearing: 90, metres: 500)
        let next = MeetMapViewController.followCenter(from: start, to: far, fraction: 0.1)
        XCTAssertLessThan(metres(next, far), 0.01)
    }
}

/// 10/12 本人「歩数とかで距離とかわかるといいかも」（今日歩いた分）。
final class TodayWalkTests: XCTestCase {
    func testText() {
        XCTAssertEqual(TodayWalk.text(steps: 7938, metres: 5612), "今日 7,938歩・5.6km")
        XCTAssertEqual(TodayWalk.text(steps: 812, metres: 590.4), "今日 812歩・590m")
        // 距離を iPhone が持っていなければ、歩数だけ（こちらで歩幅を掛けて作らない）。
        XCTAssertEqual(TodayWalk.text(steps: 120, metres: nil), "今日 120歩")
        XCTAssertNil(TodayWalk.text(steps: 0, metres: 0), "まだ歩いていなければ行を出さない")
    }
}

/// 10/13：相手の位置が届くたびに板を丸ごと作り直していた（提案の見出しに「あと◯km」が入っていて、
/// 「形が同じなら作り直さない」がすり抜けていた）。歩いて距離が変わっただけなら、形は同じ。
final class SheetShapeTests: XCTestCase {
    private let home = CLLocation(latitude: 35.5313, longitude: 139.6966)

    private func state(apart metres: Double) -> ProactiveState {
        let c = MeetMapViewController.offset(home.coordinate, bearing: 0, metres: metres)
        return ProactiveState(partner: "たぬき", connected: true, me: home,
                              peer: CLLocation(latitude: c.latitude, longitude: c.longitude),
                              peerAge: 10, store: nil, errandActive: false, pin: nil, radioNear: false)
    }

    private func shape(_ s: Suggestion?, detail: String) -> String {
        let peer = HomeSheetView.Peer(name: "たぬき", face: nil, detail: detail, mood: nil,
                                      radioNear: false, pinName: nil, errandText: nil)
        return HomeSheetView.shape(of: .peer(peer, canInvite: false), suggestion: s)
    }

    func testWalkingCloserKeepsShape() {
        let far = Proactive.decide(state(apart: 1_200))
        let near = Proactive.decide(state(apart: 900))
        XCTAssertNotNil(far)
        XCTAssertNotEqual(far?.title, near?.title, "見出しの距離は変わる")
        XCTAssertEqual(shape(far, detail: "1.2km"), shape(near, detail: "900m"), "形は同じ（作り直さない）")
    }

    func testSuggestionAppearingChangesShape() {
        XCTAssertNotEqual(shape(nil, detail: "1.2km"), shape(Proactive.decide(state(apart: 1_200)), detail: "1.2km"))
    }
}
