// いま近くで — 災害・もしものとき・避難場所・近くの話題（2026-09-25 本人の依頼）。
//
// 出どころは自分で作らず、公開されているものをそのまま使う:
//  - 地震と警報: 気象庁（地震一覧 JSON・防災情報 XML のフィード。無料・登録なし）
//    ※ よく使われる気象庁の「警報 JSON」は 2026-05-28 で更新が止まっていたので使わない
//  - 避難場所: 国土地理院「指定緊急避難場所」（地理院タイルの GeoJSON。無料・登録なし）
//  - 近くの話題: Yahoo!リアルタイム検索（X の投稿を言葉と時間順で見られる。アプリ内で開くだけ）
//  - 緊急の電話: Arch 期（ハッカソン）と同じく、押す前に必ず確かめる
//  - 警察・消防の知らせ: 警視庁「メールけいしちょう オープンデータ」（東京都・CC BY 4.0）、
//    川崎市消防局「災害情報」（川崎市）。本人は警察無線を聞きたいと言ったが、それはできないので、
//    警察・消防が自分で公開しているものを使う（2026-09-28）
// 画面は iOS 標準の表（insetGrouped）で作る（見た目を自作しない）。
import UIKit
import MapKit
import SafariServices

// MARK: - 都道府県

enum Prefecture {
    /// 都道府県名 → 気象庁・JIS の2桁コード。
    static let codes: [String: String] = [
        "北海道": "01", "青森県": "02", "岩手県": "03", "宮城県": "04", "秋田県": "05", "山形県": "06",
        "福島県": "07", "茨城県": "08", "栃木県": "09", "群馬県": "10", "埼玉県": "11", "千葉県": "12",
        "東京都": "13", "神奈川県": "14", "新潟県": "15", "富山県": "16", "石川県": "17", "福井県": "18",
        "山梨県": "19", "長野県": "20", "岐阜県": "21", "静岡県": "22", "愛知県": "23", "三重県": "24",
        "滋賀県": "25", "京都府": "26", "大阪府": "27", "兵庫県": "28", "奈良県": "29", "和歌山県": "30",
        "鳥取県": "31", "島根県": "32", "岡山県": "33", "広島県": "34", "山口県": "35", "徳島県": "36",
        "香川県": "37", "愛媛県": "38", "高知県": "39", "福岡県": "40", "佐賀県": "41", "長崎県": "42",
        "熊本県": "43", "大分県": "44", "宮崎県": "45", "鹿児島県": "46", "沖縄県": "47",
    ]
}

/// いまいる場所の都道府県と、話題を探す言葉（いちばん近い駅の名前、無ければ市区町村）。
struct Whereabouts {
    var prefecture: String
    var code: String
    var areaWord: String
    /// 区市町村（「港区」「八王子市」「川崎市」）。警察の知らせをこの名前で絞る。
    var city: String = ""
    /// 政令市の区（「川崎区」）。東京23区は city のほうに入るので nil。
    var ward: String? = nil

    /// 画面に出す地名（「港区」「川崎区」）。
    var areaName: String { ward ?? city }
}

enum WhereaboutsFinder {
    private static var cache: (CLLocation, Whereabouts)?

    static func find(_ me: CLLocation) async -> Whereabouts? {
        if let (at, w) = cache, at.distance(from: me) < 2_000 { return w }
        guard let mark = try? await CLGeocoder().reverseGeocodeLocation(me).first,
              let pref = mark.administrativeArea, let code = Prefecture.codes[pref] else { return nil }
        var word = mark.locality ?? pref
        let request = MKLocalPointsOfInterestRequest(center: me.coordinate, radius: 1_200)
        request.pointOfInterestFilter = MKPointOfInterestFilter(including: [.publicTransport])
        if let items = try? await MKLocalSearch(request: request).start().mapItems,
           let station = items.min(by: {
               ($0.placemark.location?.distance(from: me) ?? .greatestFiniteMagnitude)
                   < ($1.placemark.location?.distance(from: me) ?? .greatestFiniteMagnitude)
           })?.name {
            // 「新宿駅 西口」→「新宿」。駅の名前で話題を探すほうが、区の名前より当たる。
            var w = station.components(separatedBy: CharacterSet(charactersIn: " 　(（")).first ?? station
            if let r = w.range(of: "駅") { w = String(w[..<r.lowerBound]) }
            if !w.isEmpty { word = w }
        }
        // 東京23区は locality が区（港区）、川崎市は locality=川崎市・subLocality=川崎区。
        // 東京の subLocality は町名（永田町・芝公園）なので、区として使うのは「市」の中の「区」だけ
        // （2026-09-28 Mac の CLGeocoder で確かめた）。
        let city = mark.locality ?? ""
        let sub = mark.subLocality ?? ""
        let result = Whereabouts(prefecture: pref, code: code, areaWord: word, city: city,
                                 ward: city.hasSuffix("市") && sub.hasSuffix("区") ? sub : nil)
        cache = (me, result)
        return result
    }
}

// MARK: - 気象庁（地震・警報）

struct DisasterNotice: Equatable {
    enum Kind { case quake, warning }
    var id: String
    var kind: Kind
    var title: String
    var detail: String
    var at: Date
    /// 知らせとして出すほどか（震度3以上・警戒レベル以上）。一覧には弱いものも出す。
    var alert: Bool
    var url: URL?
}

enum JMA {
    private static let iso = ISO8601DateFormatter()

    /// 震度の文字を数に。"5-"=5.0, "5+"=5.5, "6-"=6.0 ...
    static func intensity(_ s: String) -> Double {
        switch s {
        case "5-": return 5.0
        case "5+": return 5.5
        case "6-": return 6.0
        case "6+": return 6.5
        default: return Double(s) ?? 0
        }
    }

    static func intensityText(_ s: String) -> String {
        s.replacingOccurrences(of: "-", with: "弱").replacingOccurrences(of: "+", with: "強")
    }

    /// その都道府県で揺れた地震（直近 hours 時間）。震度3以上を知らせにする。
    static func quakes(prefCode: String, prefName: String, hours: Double = 6) async -> [DisasterNotice] {
        guard let url = URL(string: "https://www.jma.go.jp/bosai/quake/data/list.json"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        var seen = Set<String>()
        var out: [DisasterNotice] = []
        for e in list {
            guard let eid = e["eid"] as? String, !seen.contains(eid),
                  let atText = e["at"] as? String, let at = iso.date(from: atText),
                  Date().timeIntervalSince(at) < hours * 3_600,
                  let areas = e["int"] as? [[String: Any]],
                  let mine = areas.first(where: { ($0["code"] as? String) == prefCode }),
                  let maxi = mine["maxi"] as? String else { continue }
            seen.insert(eid)
            let place = e["anm"] as? String ?? "震源不明"
            let mag = (e["mag"] as? String).map { "M\($0)" } ?? ""
            let f = DateFormatter()
            f.dateFormat = "H:mm"
            out.append(DisasterNotice(
                id: "q-\(eid)", kind: .quake,
                title: "震度\(intensityText(maxi))の地震（\(place)）",
                detail: "\(f.string(from: at))・\(prefName)で最大震度\(intensityText(maxi))\(mag.isEmpty ? "" : "・\(mag)")",
                at: at, alert: intensity(maxi) >= 3,
                url: URL(string: "https://www.jma.go.jp/bosai/map.html#contents=earthquake_map")))
        }
        return out
    }

    /// その都道府県の警報・注意報の最新の一文（直近 hours 時間）。「警戒」「特別警報」を知らせにする。
    static func warnings(prefCode: String, prefName: String, hours: Double = 6) async -> [DisasterNotice] {
        guard let url = URL(string: "https://www.data.jma.go.jp/developer/xml/feed/extra.xml"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let xml = String(data: data, encoding: .utf8) else { return [] }
        let entries = xml.components(separatedBy: "<entry>").dropFirst()
        var latest: DisasterNotice?
        for entry in entries {
            guard let title = tag("title", in: entry), title.contains("警報"),
                  let content = tag("content", in: entry), content.hasPrefix("【\(prefName)"),
                  let updated = tag("updated", in: entry), let at = iso.date(from: updated),
                  Date().timeIntervalSince(at) < hours * 3_600 else { continue }
            guard latest == nil || at > latest!.at else { continue }
            let body = content.components(separatedBy: "】").dropFirst().joined(separator: "】")
            let strong = body.contains("警戒") || body.contains("特別警報")
            latest = DisasterNotice(
                id: "w-\(updated)-\(prefCode)", kind: .warning,
                title: body.contains("特別警報") ? "\(prefName)に特別警報" : strong ? "\(prefName)に警報" : "\(prefName)の注意報",
                detail: body.isEmpty ? content : body,
                at: at, alert: strong && !body.contains("解除"),
                url: URL(string: "https://www.jma.go.jp/bosai/warning/#area_type=offices&area_code=\(prefCode)0000"))
        }
        return latest.map { [$0] } ?? []
    }

    private static func tag(_ name: String, in text: String) -> String? {
        guard let open = text.range(of: "<\(name)"),
              let start = text.range(of: ">", range: open.upperBound..<text.endIndex),
              let close = text.range(of: "</\(name)>", range: start.upperBound..<text.endIndex) else { return nil }
        return String(text[start.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - 避難場所（国土地理院）

struct Shelter {
    var name: String
    var address: String
    var coordinate: CLLocationCoordinate2D
    var hazards: Set<Int>

    static let hazardNames: [Int: String] = [
        1: "洪水", 2: "がけ崩れ", 3: "高潮", 4: "地震", 5: "津波", 6: "大火事", 7: "内水氾濫", 8: "火山",
    ]

    var hazardText: String {
        hazards.sorted().compactMap { Self.hazardNames[$0] }.joined(separator: "・")
    }

    var mapItem: MKMapItem {
        let item = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
        item.name = name
        return item
    }
}

enum Shelters {
    private static var tiles: [String: [Shelter]] = [:]

    /// 近い順。地理院タイル（z=10）の、いまいるタイルと、端に近ければ隣のタイルも読む。
    static func near(_ me: CLLocation, limit: Int = 5) async -> [Shelter] {
        let z = 10.0
        let n = pow(2, z)
        let lat = me.coordinate.latitude * .pi / 180
        let fx = (me.coordinate.longitude + 180) / 360 * n
        let fy = (1 - log(tan(lat) + 1 / cos(lat)) / .pi) / 2 * n
        let x = Int(fx), y = Int(fy)
        var xs = [x], ys = [y]
        if fx - Double(x) < 0.1 { xs.append(x - 1) } else if fx - Double(x) > 0.9 { xs.append(x + 1) }
        if fy - Double(y) < 0.1 { ys.append(y - 1) } else if fy - Double(y) > 0.9 { ys.append(y + 1) }
        var all: [Shelter] = []
        for tx in xs { for ty in ys { all += await tile(x: tx, y: ty) } }
        // 同じ場所が災害の種類ごとに入っているので、名前と位置でまとめる。
        var merged: [String: Shelter] = [:]
        for s in all {
            let key = "\(s.name)|\(Int(s.coordinate.latitude * 10_000))|\(Int(s.coordinate.longitude * 10_000))"
            if var existing = merged[key] {
                existing.hazards.formUnion(s.hazards)
                merged[key] = existing
            } else {
                merged[key] = s
            }
        }
        return merged.values.sorted {
            CLLocation(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude).distance(from: me)
                < CLLocation(latitude: $1.coordinate.latitude, longitude: $1.coordinate.longitude).distance(from: me)
        }.prefix(limit).map { $0 }
    }

    private static func tile(x: Int, y: Int) async -> [Shelter] {
        let key = "\(x)/\(y)"
        if let cached = tiles[key] { return cached }
        let found = await withTaskGroup(of: [Shelter].self) { group -> [Shelter] in
            for kind in 1...8 {
                group.addTask {
                    let path = String(format: "https://cyberjapandata.gsi.go.jp/xyz/skhb%02d/10/%d/%d.geojson", kind, x, y)
                    guard let url = URL(string: path),
                          let (data, _) = try? await URLSession.shared.data(from: url),
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let features = json["features"] as? [[String: Any]] else { return [] }
                    return features.compactMap { f in
                        guard let geometry = f["geometry"] as? [String: Any],
                              let c = geometry["coordinates"] as? [Double], c.count >= 2,
                              let p = f["properties"] as? [String: Any],
                              let name = p["name"] as? String else { return nil }
                        var hazards: Set<Int> = [kind]
                        for i in 1...8 where (p["disaster\(i)"] as? Int) == 1 { hazards.insert(i) }
                        return Shelter(name: name, address: p["address"] as? String ?? "",
                                       coordinate: CLLocationCoordinate2D(latitude: c[1], longitude: c[0]),
                                       hazards: hazards)
                    }
                }
            }
            var out: [Shelter] = []
            for await part in group { out += part }
            return out
        }
        tiles[key] = found
        return found
    }
}

// MARK: - 緊急の電話

struct EmergencyContact {
    var number: String
    var title: String
    var detail: String
    var tel: String

    static let all: [EmergencyContact] = [
        .init(number: "119", title: "火事・救急", detail: "火事や、命にかかわるけが・病気", tel: "119"),
        .init(number: "110", title: "警察", detail: "事件・事故", tel: "110"),
        .init(number: "#7119", title: "救急相談", detail: "救急車を呼ぶか迷ったら（実施している地域のみ）", tel: "%237119"),
        .init(number: "171", title: "災害用伝言ダイヤル", detail: "大きな災害のとき、声の伝言を残す・聞く", tel: "171"),
    ]
}

// MARK: - 警察・消防の知らせ
//
// 警察・消防が自分で公開しているものを、区市町村で絞って出す（2026-09-28 本人の依頼。出どころは手で確かめた）。
// ここから「ここまで」の行までは Foundation だけで書く（Mac で切り出して、実物のデータで試験するため）。

/// どこの知らせを使うか。いまは東京都（警視庁）と川崎市（川崎市消防局）だけ。
enum AreaNotices {
    enum Source { case tokyoPolice, kawasakiFire, unsupported }

    static func source(prefecture: String, city: String) -> Source {
        if prefecture == "東京都", !city.isEmpty { return .tokyoPolice }
        if prefecture == "神奈川県", city == "川崎市" { return .kawasakiFire }
        return .unsupported
    }
}

/// 警視庁「メールけいしちょう オープンデータ」。CC BY 4.0 なので、画面に出典を出す。
/// 利用規約に「事実と異なる内容への編集及び加工等はご遠慮ください」とあるので、
/// 一覧には一文から取り出した「いつ・どこ」だけを出し、押したら本文を手を加えずに見せる。
enum PoliceMail {
    static let topURL = URL(string: "https://mail.keishicho.metro.tokyo.lg.jp/opendata/")!
    static let downloadURL = URL(string: "https://mail.keishicho.metro.tokyo.lg.jp/opendata/download")!

    /// 配信されたメール1通（JSON の1件そのまま）。
    struct Item: Equatable {
        /// "2026-09-24 07:03:54"（日本時間）
        var sentAt: String
        var subject: String
        var message: String
        var sentBy: String
    }

    /// 画面の1行にするために読み取ったもの。
    struct Notice: Equatable {
        /// 「声かけ等」「強盗未遂」「詐欺の電話に注意」
        var kind: String
        /// 「9月23日 午後11時20分ころ」（元の言い方のまま）
        var when: String
        /// 「八王子市廿里町の路上」
        var place: String
        var item: Item
    }

    /// 採用の催しや交通安全の呼びかけは、その場所で起きたことではないので出さない（件名で見分ける）。
    static let skipWords = ["イベント", "からのお知らせ", "交通安全"]

    /// JSON の配列を読む。形が違えば nil（空の配列は「知らせなし」なので空で返す）。
    static func parse(json data: Data) -> [Item]? {
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        return list.compactMap { e in
            guard let sentAt = e["send_at"] as? String, let subject = e["subject"] as? String,
                  let message = e["message"] as? String else { return nil }
            return Item(sentAt: sentAt, subject: subject, message: message, sentBy: e["send_by"] as? String ?? "")
        }
    }

    /// 全角の数字とかっこだけを半角に（「９月２５日（金）」→「9月25日(金)」）。カタカナなどは変えない。
    static func narrow(_ s: String) -> String {
        String(s.map { c -> Character in
            guard c.unicodeScalars.count == 1, let v = c.unicodeScalars.first?.value else { return c }
            if (0xFF10...0xFF19).contains(v), let u = UnicodeScalar(v - 0xFF10 + 0x30) { return Character(u) }
            if v == 0xFF08 { return "(" }
            if v == 0xFF09 { return ")" }
            return c
        })
    }

    /// 本文の最初の一文。「【このメールは…配信しています。】」「【文京区で発生した情報です】」のような見出しの行は飛ばす。
    static func firstSentence(_ message: String) -> String {
        for raw in message.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || (line.hasPrefix("【") && line.hasSuffix("】")) { continue }
            return narrow(line.components(separatedBy: "。").first ?? line)
        }
        return ""
    }

    /// 件名から「声かけ等」「強盗未遂」のような種類を取る。件名の形がいくつもある（2026-09-25〜27 の実データ）:
    ///  「高尾警察署(声かけ等)」「野方警察署(子供(声かけ等))」「練馬警察署（強盗未遂）」→ かっこの中
    ///  「【アポ電入電中】詐欺の電話に注意(高井戸警察署)」「クマの目撃情報について（五日市警察署）」→ かっこの前
    static func kind(subject: String) -> String {
        var s = narrow(subject).trimmingCharacters(in: .whitespaces)
        if s.hasSuffix(")"), let open = openParen(matchingLastIn: s) {
            let inner = String(s[s.index(after: open)..<s.index(before: s.endIndex)])
            let outer = String(s[..<open]).trimmingCharacters(in: .whitespaces)
            if inner.hasSuffix("警察署") { s = outer } else if outer.hasSuffix("警察署") { s = inner }
        }
        // 「【アポ電入電中】オレオレ詐欺」→「オレオレ詐欺」。見出しだけなら見出しの中身。
        if s.hasPrefix("【"), let close = s.firstIndex(of: "】") {
            let head = String(s[s.index(after: s.startIndex)..<close])
            let rest = String(s[s.index(after: close)...]).trimmingCharacters(in: .whitespaces)
            s = rest.isEmpty ? head : rest
        }
        if s.hasSuffix("で発生した情報です") { return "発生情報" }
        if s.hasSuffix("について"), s.count > 4 { s = String(s.dropLast(4)) }
        return s
    }

    private static func openParen(matchingLastIn s: String) -> String.Index? {
        var depth = 0
        var i = s.endIndex
        while i > s.startIndex {
            i = s.index(before: i)
            if s[i] == ")" {
                depth += 1
            } else if s[i] == "(" {
                depth -= 1
                if depth == 0 { return i }
            }
        }
        return nil
    }

    /// 一文から「9月23日 午後11時20分ころ」を取る。書き方は「2026年9月23日(水)、午後11時20分ころ」
    /// 「令和8年9月25日午後3時54分頃」「本日(9月25日(金))」などいろいろ。日付が無ければ配信の日時にする。
    static func when(sentence: String, sentAt: String) -> String {
        let pattern = #"(\d{1,2})月(\d{1,2})日(?:\([^)]*\))?\)?[、\s]*((?:午前|午後)?\d{1,2}時(?:\d{1,2}分)?(?:ころ|頃)?)?"#
        let ns = sentence as NSString
        if let re = try? NSRegularExpression(pattern: pattern),
           let m = re.firstMatch(in: sentence, range: NSRange(location: 0, length: ns.length)) {
            let day = "\(ns.substring(with: m.range(at: 1)))月\(ns.substring(with: m.range(at: 2)))日"
            let time = m.range(at: 3).location == NSNotFound ? "" : " \(ns.substring(with: m.range(at: 3)))"
            return day + time
        }
        // "2026-09-24 07:03:54" → "9月24日 7:03配信"
        let parts = sentAt.split(whereSeparator: { $0 == "-" || $0 == " " || $0 == ":" }).compactMap { Int($0) }
        guard parts.count >= 5 else { return sentAt }
        return "\(parts[1])月\(parts[2])日 \(parts[3]):\(String(format: "%02d", parts[4]))配信"
    }

    /// 一文から、区市町村の名前から始まる場所を取る（「八王子市廿里町の路上」「港区内」）。
    /// その区市町村の名前が一文に無ければ nil（＝よその知らせ）。
    /// 「あきる野市乙津（…駐在所から北方約１キロメートル）の山林において」のように、かっこの中の「から」では切らない。
    static func place(sentence: String, city: String) -> String? {
        guard !city.isEmpty, let start = sentence.range(of: city) else { return nil }
        let rest = sentence[start.lowerBound...]
        let ends = ["において", "にて", "で、", "から", "に、"]
        var depth = 0
        var i = rest.startIndex
        while i < rest.endIndex {
            let c = rest[i]
            if "(「『".contains(c) {
                depth += 1
            } else if ")」』".contains(c) {
                depth = max(0, depth - 1)
            } else if depth == 0, ends.contains(where: { rest[i...].hasPrefix($0) }) {
                break
            }
            i = rest.index(after: i)
        }
        let p = String(rest[..<i])
        return p.count > 40 ? String(p.prefix(40)) + "…" : p
    }

    /// 1通を画面の1行に。よその区市町村の知らせ・催しや交通安全の呼びかけは nil。
    static func notice(_ item: Item, city: String) -> Notice? {
        guard !skipWords.contains(where: { item.subject.contains($0) }) else { return nil }
        let sentence = firstSentence(item.message)
        guard let place = place(sentence: sentence, city: city) else { return nil }
        return Notice(kind: kind(subject: item.subject), when: when(sentence: sentence, sentAt: item.sentAt),
                      place: place, item: item)
    }

    /// いまいる区市町村の知らせだけを、新しい順に。
    static func filter(_ items: [Item], city: String) -> [Notice] {
        items.compactMap { notice($0, city: city) }.sorted { $0.item.sentAt > $1.item.sentAt }
    }

    /// 取る期間（日本時間の "yyyyMMdd"）。終わりの日は含まれず（「指定期間の0時から0時まで」）、
    /// 今日より先を終わりにすると 400 になる（2026-09-28 実測）。なので今日を終わりにして、前日までの days 日分。
    static func dateRange(now: Date, days: Int = 3) -> (start: String, end: String) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let f = DateFormatter()
        f.calendar = cal
        f.timeZone = cal.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd"
        let start = cal.date(byAdding: .day, value: -days, to: now) ?? now
        return (f.string(from: start), f.string(from: now))
    }

    /// 取れなかったときは ok=false（「知らせなし」と見分けるため）。
    /// 先にトップを開いて Cookie をもらってから POST する。Cookie 無しだと 200 で空の [] が返り、
    /// 「知らせなし」と見分けがつかない（2026-09-28 実測）。
    static func fetch(city: String, now: Date = Date()) async -> (notices: [Notice], ok: Bool) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        guard let (_, top) = try? await session.data(from: topURL),
              (top as? HTTPURLResponse)?.statusCode == 200 else { return ([], false) }
        let (start, end) = dateRange(now: now)
        var request = URLRequest(url: downloadURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(topURL.absoluteString, forHTTPHeaderField: "Referer")
        request.httpBody = "format=json&sdate=\(start)&edate=\(end)&topic=&region=".data(using: .utf8)
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let items = parse(json: data) else { return ([], false) }
        return (filter(items, city: city), true)
    }
}

/// 川崎市消防局「災害情報」。いま出場している消防車を1行ずつ書いたページ（Shift_JIS）。
/// 「９月２７日　２３時３８分　頃　川崎区　東田町　付近より　災害の通報　があり、消防車が出場しています」
enum KawasakiFire {
    static let pageURL = URL(string: "https://sc.city.kawasaki.jp/saigai/index.htm")!

    struct Dispatch: Equatable {
        /// 「9月27日 23時38分頃」
        var time: String
        /// 「川崎区」
        var ward: String
        /// 「東田町」「下小田中3丁目」
        var town: String
        /// 「災害の通報」
        var what: String
    }

    /// 出場の行を全部。出場が無いときは空。「頃」「があり」の前の空白は、あったり無かったりする（2026-09-28 実物）。
    static func parse(html: String) -> [Dispatch] {
        let text = PoliceMail.narrow(html)
        let pattern = #"(\d{1,2}月\d{1,2}日)[\s　]*(\d{1,2}時\d{1,2}分)[\s　]*(頃)?[\s　]*(\S+?区)[\s　]+(\S+?)[\s　]+付近より[\s　]*(\S+?)[\s　]*があり"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { m in
            func group(_ i: Int) -> String {
                m.range(at: i).location == NSNotFound ? "" : ns.substring(with: m.range(at: i))
            }
            return Dispatch(time: "\(group(1)) \(group(2))\(group(3))", ward: group(4), town: group(5), what: group(6))
        }
    }

    /// いまいる区を先に。同じ区どうしはページの並びのまま。
    static func mineFirst(_ list: [Dispatch], ward: String?) -> [Dispatch] {
        guard let ward else { return list }
        return list.filter { $0.ward == ward } + list.filter { $0.ward != ward }
    }

    /// Shift_JIS と書いてあるが、Windows の文字（①・髙 など）が混ざっても読めるよう、まず CP932 で読む。
    static func decode(_ data: Data) -> String? {
        let cp932 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.dosJapanese.rawValue)))
        return String(data: data, encoding: cp932) ?? String(data: data, encoding: .shiftJIS)
    }

    /// 取れなかったときは ok=false（「出場なし」と見分けるため）。
    static func fetch() async -> (dispatches: [Dispatch], ok: Bool) {
        let request = URLRequest(url: pageURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let html = decode(data), html.contains("災害情報") else { return ([], false) }
        return (parse(html: html), true)
    }
}

// 警察・消防の知らせ ここまで（Foundation だけの部分）

// MARK: - 好きなもの（話題を探す言葉）

enum Favorites {
    private static let key = "kokodayo.favorites"
    static var all: [String] {
        get { UserDefaults.standard.stringArray(forKey: key) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    static func realtimeURL(_ word: String) -> URL? {
        var c = URLComponents(string: "https://search.yahoo.co.jp/realtime/search")
        c?.queryItems = [URLQueryItem(name: "p", value: word)]
        return c?.url
    }
}

// MARK: - いま近くで（画面）

final class NearbyNowViewController: UITableViewController {

    private enum Section: Int, CaseIterable { case disaster, police, emergency, shelters, talk }

    private let me: CLLocation?
    /// 避難場所を押したら、アプリの中の経路へ。
    var onRoute: ((MKMapItem) -> Void)?
    private var whereabouts: Whereabouts?
    private var notices: [DisasterNotice] = []
    private var shelters: [Shelter] = []
    private var loadingDisaster = true
    private var loadingShelters = true
    private var policeSource: AreaNotices.Source?
    private var policeNotices: [PoliceMail.Notice] = []
    private var fireDispatches: [KawasakiFire.Dispatch] = []
    private var loadingPolice = true
    /// 取りに行って失敗した（「知らせなし」とは分けて出す）。
    private var policeFailed = false
    private var policeCount: Int { policeSource == .kawasakiFire ? fireDispatches.count : policeNotices.count }

    /// 何の画面として開くか。「いまの話題」は別の入口から開く（本人 9/28「今話題は別のところから開けるようにして」）。
    enum Focus { case safety, talk }
    private let focus: Focus
    /// この画面に並べる区切り。
    private var sections: [Section] { focus == .talk ? [.talk] : [.disaster, .police, .emergency, .shelters] }

    init(me: CLLocation?, focus: Focus = .safety) {
        self.me = me
        self.focus = focus
        super.init(style: .insetGrouped)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = focus == .talk ? "いまの話題" : "いま近くで"
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
        load()
    }

    private func load() {
        guard let me else {
            loadingDisaster = false
            loadingShelters = false
            loadingPolice = false
            tableView.reloadData()
            return
        }
        Task { @MainActor in
            self.whereabouts = await WhereaboutsFinder.find(me)
            self.loadPolice()
            if let w = self.whereabouts {
                async let q = JMA.quakes(prefCode: w.code, prefName: w.prefecture, hours: 24)
                async let wn = JMA.warnings(prefCode: w.code, prefName: w.prefecture, hours: 24)
                self.notices = (await wn) + (await q)
            }
            self.loadingDisaster = false
            self.tableView.reloadData()
        }
        Task { @MainActor in
            self.shelters = await Shelters.near(me)
            self.loadingShelters = false
            self.reload(.shelters)
        }
    }

    /// 警察・消防の知らせ。場所（区市町村）が分かったら、気象庁を待たずに取りに行く。
    private func loadPolice() {
        guard let w = whereabouts else {
            loadingPolice = false
            reload(.police)
            return
        }
        let source = AreaNotices.source(prefecture: w.prefecture, city: w.city)
        policeSource = source
        Task { @MainActor in
            switch source {
            case .tokyoPolice:
                let r = await PoliceMail.fetch(city: w.city)
                self.policeNotices = r.notices
                self.policeFailed = !r.ok
            case .kawasakiFire:
                // 川崎市のサイトの決まりは「無断で複製・転用は禁止、リンクは自由」。中身は写さず、公式ページへのリンクだけ出す。
                self.fireDispatches = []
                self.policeFailed = false
            case .unsupported:
                break
            }
            self.loadingPolice = false
            self.reload(.police)
        }
    }

    override func numberOfSections(in tableView: UITableView) -> Int { sections.count }

    /// 区切りを表の何番目に置いているか（この画面に無ければ nil）。
    private func index(of section: Section) -> Int? { sections.firstIndex(of: section) }

    private func reload(_ section: Section) {
        guard let i = index(of: section) else { return }
        tableView.reloadSections(IndexSet(integer: i), with: .automatic)
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch sections[section] {
        case .disaster: return whereabouts.map { "\($0.prefecture)の災害情報（気象庁）" } ?? "災害情報（気象庁）"
        case .police:
            guard let name = whereabouts?.areaName, !name.isEmpty else { return "警察・消防の知らせ" }
            return "警察・消防の知らせ（\(name)）"
        case .emergency: return "もしものとき"
        case .shelters: return "近くの避難場所（国土地理院）"
        case .talk: return "いまの話題（X・Yahoo!リアルタイム検索）"
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch sections[section] {
        case .emergency: return "押すと、かける前に確かめます。"
        case .shelters: return "指定緊急避難場所。どの災害のときに使えるかを右に出しています。"
        case .police:
            // 警視庁のデータは CC BY 4.0。出典を出すのが使う条件。
            switch policeSource {
            case .tokyoPolice?:
                return "出典：警視庁 メールけいしちょう オープンデータ（CC BY 4.0）。前日までの3日分です。押すと全文を出します。"
            case .kawasakiFire?:
                return "川崎市消防局の公式ページを開きます（サイトの決まりに合わせて、中身はアプリに写していません）。"
            default:
                return nil
            }
        default: return nil
        }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch sections[section] {
        case .disaster: return loadingDisaster || notices.isEmpty ? 1 : notices.count
        case .police: return loadingPolice || policeCount == 0 ? 1 : policeCount
        case .emergency: return EmergencyContact.all.count
        case .shelters: return loadingShelters || shelters.isEmpty ? 1 : shelters.count
        case .talk: return 1 + Favorites.all.count + 1
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()
        content.secondaryTextProperties.color = .secondaryLabel
        switch sections[indexPath.section] {
        case .disaster:
            if loadingDisaster {
                content.text = "読み込んでいます…"
            } else if notices.isEmpty {
                content.text = "直近24時間、この都道府県の警報・揺れはありません"
                content.image = UIImage(systemName: "checkmark.shield")
            } else {
                let n = notices[indexPath.row]
                content.text = n.title
                content.secondaryText = n.detail
                content.image = UIImage(systemName: n.kind == .quake ? "waveform.path.ecg" : "exclamationmark.triangle.fill")
                content.imageProperties.tintColor = n.alert ? .systemRed : .systemOrange
                cell.accessoryType = .disclosureIndicator
            }
        case .police:
            let area = whereabouts?.areaName ?? ""
            if loadingPolice {
                content.text = "読み込んでいます…"
            } else if me == nil {
                content.text = "いまいる場所がまだ分かりません"
            } else if whereabouts == nil || area.isEmpty {
                content.text = "いまいる場所の区市町村が分かりませんでした"
            } else if policeSource == .unsupported {
                content.text = "この地域の警察・消防の知らせには、まだ対応していません"
            } else if policeFailed {
                content.text = "知らせを取れませんでした"
                content.secondaryText = "通信の具合を確かめて、開き直してください"
                content.image = UIImage(systemName: "wifi.exclamationmark")
                content.imageProperties.tintColor = .systemGray
            } else if policeSource == .kawasakiFire {
                if fireDispatches.isEmpty {
                    content.text = "川崎市消防局の災害情報を見る"
                    content.secondaryText = "いま消防車が出ている場所（公式ページ）"
                    content.image = UIImage(systemName: "flame.fill")
                    content.imageProperties.tintColor = .systemOrange
                    cell.accessoryType = .disclosureIndicator
                } else {
                    let d = fireDispatches[indexPath.row]
                    let mine = d.ward == whereabouts?.ward
                    content.text = "\(d.what)・\(d.time)"
                    content.secondaryText = "\(d.ward)\(d.town)付近" + (mine ? "（いまいる区）" : "")
                    content.image = UIImage(systemName: "flame.fill")
                    content.imageProperties.tintColor = mine ? .systemRed : .systemOrange
                    cell.accessoryType = .disclosureIndicator
                }
            } else if policeNotices.isEmpty {
                content.text = "この3日、\(area)の知らせはありません"
                content.image = UIImage(systemName: "checkmark.shield")
            } else {
                let n = policeNotices[indexPath.row]
                content.text = "\(n.kind)・\(n.when)"
                content.secondaryText = n.place
                content.image = UIImage(systemName: "shield.lefthalf.filled")
                content.imageProperties.tintColor = .systemBlue
                cell.accessoryType = .disclosureIndicator
            }
        case .emergency:
            let c = EmergencyContact.all[indexPath.row]
            content.text = "\(c.number)　\(c.title)"
            content.secondaryText = c.detail
            content.image = UIImage(systemName: "phone.fill")
            content.imageProperties.tintColor = c.number == "119" ? .systemRed : .systemBlue
        case .shelters:
            if loadingShelters {
                content.text = "読み込んでいます…"
            } else if shelters.isEmpty {
                content.text = me == nil ? "いまいる場所がまだ分かりません" : "近くに見つかりませんでした"
            } else {
                let s = shelters[indexPath.row]
                let d = me.map { CLLocation(latitude: s.coordinate.latitude, longitude: s.coordinate.longitude).distance(from: $0) }
                content.text = s.name
                content.secondaryText = [d.map { "\(NearbyAlert.text($0))・\(NearbyAlert.walkText($0))" }, s.hazardText]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "　")
                content.image = UIImage(systemName: "figure.walk.motion")
                content.imageProperties.tintColor = .systemGreen
                cell.accessoryType = .disclosureIndicator
            }
        case .talk:
            let favorites = Favorites.all
            if indexPath.row == 0 {
                content.text = "近くの話題：\(whereabouts?.areaWord ?? "…")"
                content.secondaryText = "いまの様子・遅れ・混雑など"
                content.image = UIImage(systemName: "text.bubble")
            } else if indexPath.row <= favorites.count {
                content.text = favorites[indexPath.row - 1]
                content.secondaryText = "好きなもの"
                content.image = UIImage(systemName: "star.fill")
                content.imageProperties.tintColor = .systemYellow
            } else {
                content.text = "好きなものを足す（例: ハリポタ）"
                content.image = UIImage(systemName: "plus.circle")
                content.textProperties.color = .systemBlue
            }
            if indexPath.row <= favorites.count { cell.accessoryType = .disclosureIndicator }
        }
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch sections[indexPath.section] {
        case .disaster:
            guard !notices.isEmpty, let url = notices[indexPath.row].url else { return }
            present(SFSafariViewController(url: url), animated: true)
        case .police:
            guard !loadingPolice else { return }
            if policeSource == .tokyoPolice, !policeNotices.isEmpty {
                let item = policeNotices[indexPath.row].item
                navigationController?.pushViewController(PoliceMailViewController(item: item), animated: true)
            } else if policeSource == .kawasakiFire {
                present(SFSafariViewController(url: KawasakiFire.pageURL), animated: true)
            }
        case .emergency:
            confirmCall(EmergencyContact.all[indexPath.row])
        case .shelters:
            guard !shelters.isEmpty else { return }
            let item = shelters[indexPath.row].mapItem
            // 経路の通信は、閉じるのと同時に始める。
            onRoute?(item)
            dismiss(animated: true)
        case .talk:
            let favorites = Favorites.all
            if indexPath.row == 0 {
                guard let word = whereabouts?.areaWord, let url = Favorites.realtimeURL(word) else { return }
                present(SFSafariViewController(url: url), animated: true)
            } else if indexPath.row <= favorites.count {
                guard let url = Favorites.realtimeURL(favorites[indexPath.row - 1]) else { return }
                present(SFSafariViewController(url: url), animated: true)
            } else {
                addFavorite()
            }
        }
    }

    override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        sections[indexPath.section] == .talk && indexPath.row >= 1 && indexPath.row <= Favorites.all.count
    }

    override func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle,
                            forRowAt indexPath: IndexPath) {
        guard editingStyle == .delete else { return }
        var list = Favorites.all
        list.remove(at: indexPath.row - 1)
        Favorites.all = list
        reload(.talk)
    }

    /// 電話は、かける前に必ず確かめる（Arch 期の #7119 と同じ。誤発信を防ぐ）。
    private func confirmCall(_ c: EmergencyContact) {
        let alert = UIAlertController(title: "\(c.number) に電話しますか？", message: "\(c.title)：\(c.detail)",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "やめる", style: .cancel))
        alert.addAction(UIAlertAction(title: "電話する", style: .destructive) { _ in
            if let url = URL(string: "tel://\(c.tel)") { UIApplication.shared.open(url) }
        })
        present(alert, animated: true)
    }

    private func addFavorite() {
        let alert = UIAlertController(title: "好きなもの", message: "Xの話題を探す言葉です", preferredStyle: .alert)
        alert.addTextField { $0.placeholder = "例: ハリポタ" }
        alert.addAction(UIAlertAction(title: "やめる", style: .cancel))
        alert.addAction(UIAlertAction(title: "足す", style: .default) { [weak self] _ in
            let word = cleanName(alert.textFields?.first?.text ?? "")
            guard !word.isEmpty, !Favorites.all.contains(word) else { return }
            Favorites.all.append(word)
            self?.reload(.talk)
        })
        present(alert, animated: true)
    }
}

/// 警察の知らせの全文。手を加えずにそのまま見せる
/// （警視庁の利用規約「事実と異なる内容への編集及び加工等はご遠慮ください」）。
/// 電話番号は押せるようにしない（この画面の電話は、かける前に必ず確かめるため）。
private final class PoliceMailViewController: UIViewController {
    private let item: PoliceMail.Item

    init(item: PoliceMail.Item) {
        self.item = item
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = item.subject
        view.backgroundColor = .systemBackground
        let text = UITextView(frame: view.bounds)
        text.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        text.isEditable = false
        text.dataDetectorTypes = [.link]
        text.font = .preferredFont(forTextStyle: .body)
        text.adjustsFontForContentSizeCategory = true
        text.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 24, right: 12)
        text.text = "\(item.sentAt)　\(item.sentBy)\n\n" + item.message.replacingOccurrences(of: "\r\n", with: "\n")
        view.addSubview(text)
    }
}
