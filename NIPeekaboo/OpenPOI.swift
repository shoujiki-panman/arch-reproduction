/*
See LICENSE folder for this sample's licensing information.

Abstract:
OpenPOI API（日本全国の施設 約337万件・キー不要）で、Appleマップの検索が取りこぼす店を足す。
*/

import Foundation
import MapKit

/// Appleマップの検索だけだと「ラーメン」「カラオケ」で近くの店を取りこぼした（9/26・9/27 本人）。
/// OpenPOI API は Overture Maps と保健所の食品営業許可データを合わせたもので、
/// 店の名前に入っている言葉なら近くをよく拾う（9/29 川崎駅で実測：ラーメン5件・カラオケ5件、どれも300m以内）。
/// ただし名前で探すだけなので、「ランチ」はペッパーランチや「フランチャイズ募集」を返し、
/// 「ラゾーナ」は施設そのものではなく中の店を返した。だから種類の言葉のうち、
/// 店の名前に入る言葉のときだけ使う。
/// 利用条件（docs.openpoiapi.com）：キー不要・商用可・出典「OpenPOI API」と出典ページへのリンクを出す。
enum OpenPOI {
    static let attributionURL = URL(string: "https://openpoiapi.com/attribution.html")!
    static let creditText = "一部の場所の出典：OpenPOI API"

    /// 店の名前にはまず入らない言葉。名前で探すと関係ない店が出る。
    private static let notInNames: Set<String> = [
        "ごはん", "ランチ", "ディナー", "食事", "レストラン", "休憩", "コンビニ", "ファミレス",
        "ゲーセン", "ATM", "トイレ", "駅", "スーパー", "ドラッグストア",
    ]

    /// この言葉なら OpenPOI で足してよいか。種類の言葉（AskParser.isGeneric）で、名前に入る言葉だけ。
    static func usable(for query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard AskParser.isGeneric(q) else { return false }
        let base = AskParser.genericWords.first { w in [w, w + "屋", w + "屋さん", w + "店", w + "場"].contains(q) } ?? q
        return !notInNames.contains(base)
    }

    struct Hit: Equatable {
        var name: String
        var latitude: Double
        var longitude: Double
        var address: String
    }

    /// 返事の JSON から、名前と座標のそろった行だけを取り出す（座標は数値でも文字でも来る）。
    static func parse(_ data: Data) -> [Hit] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = root["results"] as? [[String: Any]] else { return [] }
        return results.compactMap { r in
            guard let name = r["name"] as? String, !name.isEmpty,
                  let lat = number(r["lat"]), let lng = number(r["lng"]) else { return nil }
            // 番地の欄は空のことが多い（9/29 実測）。空なら都道府県＋市区町村まで。
            let street = r["address"] as? String ?? ""
            let line = street.isEmpty
                ? [r["prefecture"], r["city"]].compactMap { $0 as? String }.joined()
                : street
            return Hit(name: name, latitude: lat, longitude: lng, address: line)
        }
    }

    private static func number(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) }
        return nil
    }

    /// Appleマップの結果と同じ店（名前が同じか、50m以内で名前の頭2文字が同じ）は足さない。
    static func isDuplicate(_ hit: Hit, of names: [(name: String, location: CLLocation)]) -> Bool {
        let here = CLLocation(latitude: hit.latitude, longitude: hit.longitude)
        let key = normalized(hit.name)
        return names.contains { other in
            let otherKey = normalized(other.name)
            if otherKey == key { return true }
            guard other.location.distance(from: here) < 50 else { return false }
            // 「神座ラーメン川崎駅北口」と「神座 川崎店」のように、表記は違っても頭2文字は同じ。
            return otherKey.prefix(2) == key.prefix(2)
        }
    }

    private static func normalized(_ s: String) -> String {
        s.applyingTransform(.fullwidthToHalfwidth, reverse: false)?
            .lowercased().replacingOccurrences(of: " ", with: "") ?? s
    }

    /// まわりで探す。5秒で返事が無ければ空（Appleマップの結果だけで進む）。
    static func search(_ query: String, near me: CLLocation, radius: Int = 1500, limit: Int = 20) async -> [Hit] {
        var c = URLComponents(string: "https://api.openpoiapi.com/v1/search")!
        c.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "center", value: "\(me.coordinate.longitude),\(me.coordinate.latitude)"),
            URLQueryItem(name: "radius", value: String(radius)),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        guard let url = c.url else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        return parse(data)
    }

    /// OpenPOI から来た場所。一覧に出典を出すかどうかを、これで見分ける。
    private static let fromOpenPOI = NSHashTable<MKMapItem>.weakObjects()

    static func mapItem(_ hit: Hit) -> MKMapItem {
        let placemark = MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: hit.latitude, longitude: hit.longitude))
        let item = MKMapItem(placemark: placemark)
        item.name = hit.name
        fromOpenPOI.add(item)
        return item
    }

    static func isFromOpenPOI(_ item: MKMapItem) -> Bool { fromOpenPOI.contains(item) }
}
