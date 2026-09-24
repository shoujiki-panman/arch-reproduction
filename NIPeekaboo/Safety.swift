// いま近くで — 災害・もしものとき・避難場所・近くの話題（2026-09-25 本人の依頼）。
//
// 出どころは自分で作らず、公開されているものをそのまま使う:
//  - 地震と警報: 気象庁（地震一覧 JSON・防災情報 XML のフィード。無料・登録なし）
//    ※ よく使われる気象庁の「警報 JSON」は 2026-05-28 で更新が止まっていたので使わない
//  - 避難場所: 国土地理院「指定緊急避難場所」（地理院タイルの GeoJSON。無料・登録なし）
//  - 近くの話題: Yahoo!リアルタイム検索（X の投稿を言葉と時間順で見られる。アプリ内で開くだけ）
//  - 緊急の電話: Arch 期（ハッカソン）と同じく、押す前に必ず確かめる
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
        let result = Whereabouts(prefecture: pref, code: code, areaWord: word)
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

    private enum Section: Int, CaseIterable { case disaster, emergency, shelters, talk }

    private let me: CLLocation?
    /// 避難場所を押したら、アプリの中の経路へ。
    var onRoute: ((MKMapItem) -> Void)?
    private var whereabouts: Whereabouts?
    private var notices: [DisasterNotice] = []
    private var shelters: [Shelter] = []
    private var loadingDisaster = true
    private var loadingShelters = true

    init(me: CLLocation?) {
        self.me = me
        super.init(style: .insetGrouped)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "いま近くで"
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
        load()
    }

    private func load() {
        guard let me else {
            loadingDisaster = false
            loadingShelters = false
            tableView.reloadData()
            return
        }
        Task { @MainActor in
            self.whereabouts = await WhereaboutsFinder.find(me)
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
            self.tableView.reloadSections(IndexSet(integer: Section.shelters.rawValue), with: .automatic)
        }
    }

    override func numberOfSections(in tableView: UITableView) -> Int { Section.allCases.count }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch Section(rawValue: section)! {
        case .disaster: return whereabouts.map { "\($0.prefecture)の災害情報（気象庁）" } ?? "災害情報（気象庁）"
        case .emergency: return "もしものとき"
        case .shelters: return "近くの避難場所（国土地理院）"
        case .talk: return "いまの話題（X・Yahoo!リアルタイム検索）"
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch Section(rawValue: section)! {
        case .emergency: return "押すと、かける前に確かめます。"
        case .shelters: return "指定緊急避難場所。どの災害のときに使えるかを右に出しています。"
        default: return nil
        }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section)! {
        case .disaster: return loadingDisaster || notices.isEmpty ? 1 : notices.count
        case .emergency: return EmergencyContact.all.count
        case .shelters: return loadingShelters || shelters.isEmpty ? 1 : shelters.count
        case .talk: return 1 + Favorites.all.count + 1
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()
        content.secondaryTextProperties.color = .secondaryLabel
        switch Section(rawValue: indexPath.section)! {
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
        switch Section(rawValue: indexPath.section)! {
        case .disaster:
            guard !notices.isEmpty, let url = notices[indexPath.row].url else { return }
            present(SFSafariViewController(url: url), animated: true)
        case .emergency:
            confirmCall(EmergencyContact.all[indexPath.row])
        case .shelters:
            guard !shelters.isEmpty else { return }
            let item = shelters[indexPath.row].mapItem
            dismiss(animated: true) { [onRoute] in onRoute?(item) }
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
        indexPath.section == Section.talk.rawValue && indexPath.row >= 1 && indexPath.row <= Favorites.all.count
    }

    override func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle,
                            forRowAt indexPath: IndexPath) {
        guard editingStyle == .delete else { return }
        var list = Favorites.all
        list.remove(at: indexPath.row - 1)
        Favorites.all = list
        tableView.reloadSections(IndexSet(integer: Section.talk.rawValue), with: .automatic)
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
            self?.tableView.reloadSections(IndexSet(integer: Section.talk.rawValue), with: .automatic)
        })
        present(alert, animated: true)
    }
}
