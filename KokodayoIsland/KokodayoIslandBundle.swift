/*
Abstract:
The widget bundle. One face for now: the meet-up in progress.
*/

import SwiftUI
import WidgetKit

@main
struct KokodayoIslandBundle: WidgetBundle {
    var body: some Widget {
        MeetLiveActivity()
    }
}
