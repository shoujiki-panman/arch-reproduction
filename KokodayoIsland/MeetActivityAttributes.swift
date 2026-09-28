/*
Abstract:
What the Dynamic Island and the Lock Screen are told while two phones are
measuring the distance between them.

Only one number ever leaves the app: how far apart the two phones are. No
position, no map, no address — there is nothing else to leak, because the radio
never measured anything else.
*/

import ActivityKit
import Foundation

/// The app still runs on phones older than the island, so the type carries
/// its own availability rather than dragging the whole app forward.
@available(iOS 16.1, *)
struct MeetActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// Nil while the link is up but no reading has arrived: the island says
        /// so rather than holding the last number as if it were still true.
        var metres: Double?
        /// GPSだけで、2台の誤差の内にいる。数字を出さず「すぐ近く」と言う（古い版から来た値は nil）。
        var near: Bool? = nil
        /// The name the host's signed list settled on, never a self-claimed one.
        var name: String
        /// True while the gap is closing, false while it opens, nil when it is
        /// too early to say.
        var closing: Bool?
        var arrived: Bool
        /// 「4:00まで」 — the same promise the group itself makes.
        var untilText: String
        /// What to do right now, decided from both phones. The one line the
        /// island exists to show.
        var instruction: String

        /// Full at arm's length, empty at twenty metres. The island is too small
        /// for a number to be the point; the ring is what you read at a glance.
        var closeness: Double {
            if near == true { return 0.8 }
            guard let metres else { return 0 }
            return max(0, min(1, 1 - metres / 20))
        }

        var readout: String {
            if arrived { return "見つけた" }
            if near == true { return "すぐ近く" }
            guard let metres else { return "—" }
            // 地図で見ているあいだはキロになる。1200 m とは書かない。
            if metres >= 1000 { return String(format: "%.1f km", metres / 1000) }
            return metres >= 2 ? String(format: "%.0f m", metres.rounded()) : String(format: "%.1f m", metres)
        }
    }

    /// Fixed for the life of the activity: who this is about.
    var name: String
}
