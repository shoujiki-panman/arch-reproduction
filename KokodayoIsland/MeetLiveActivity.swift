/*
Abstract:
The Dynamic Island and Lock Screen faces of a meet-up in progress.

The app's own screen is a ring whose size is the distance. Up here there is no
room for that, so the same idea is turned inside out: the ring fills as the gap
closes. Nothing else moves, and no arrow is ever drawn — the radio does not
measure direction in Japan, and a shape that implied one would be a lie in the
one place the user glances at without thinking.
*/

import ActivityKit
import SwiftUI
import WidgetKit

private enum IslandPalette {
    static let ink = Color(red: 198 / 255, green: 164 / 255, blue: 92 / 255)
    static let action = Color(red: 169 / 255, green: 202 / 255, blue: 255 / 255)
    static let arrival = Color(red: 198 / 255, green: 164 / 255, blue: 92 / 255)
    static let drift = Color(red: 230 / 255, green: 140 / 255, blue: 92 / 255)
    static let secondary = Color(red: 184 / 255, green: 196 / 255, blue: 213 / 255)
}

private func accent(_ state: MeetActivityAttributes.ContentState) -> Color {
    if state.arrived { return IslandPalette.arrival }
    if state.closing == false { return IslandPalette.drift }
    return IslandPalette.action
}

/// The ring, drawn once and reused everywhere it appears.
private struct ClosenessRing: View {
    let state: MeetActivityAttributes.ContentState
    var line: CGFloat = 3
    /// No update for half a minute: the app is not in front, so the number is
    /// history. The ring dims rather than pretending.
    var stale = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.14), lineWidth: line)
            Circle()
                .trim(from: 0, to: max(0.02, state.closeness))
                .stroke(accent(state).opacity(stale ? 0.35 : 1), style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.smooth(duration: 0.45), value: state.closeness)
            if state.arrived, !stale {
                Image(systemName: "sparkles")
                    .font(.system(size: line * 2.6, weight: .semibold))
                    .foregroundStyle(IslandPalette.arrival)
                    .symbolEffect(.variableColor.iterative, options: .repeating)
            }
        }
    }
}

struct MeetLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: MeetActivityAttributes.self) { context in
            // Lock Screen and banner.
            HStack(spacing: 14) {
                ClosenessRing(state: context.state, line: 4, stale: context.isStale)
                    .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.state.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                    Text(caption(for: context.state, stale: context.isStale))
                        .font(.caption)
                        .foregroundStyle(IslandPalette.secondary)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(context.state.readout)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(context.isStale ? IslandPalette.secondary : .white)
                        .contentTransition(.numericText())
                    Text(context.state.untilText)
                        .font(.caption2)
                        .foregroundStyle(IslandPalette.ink)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .activityBackgroundTint(Color(red: 16 / 255, green: 22 / 255, blue: 32 / 255))
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 8) {
                        ClosenessRing(state: context.state, line: 3.5, stale: context.isStale)
                            .frame(width: 30, height: 30)
                        Text(context.state.name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.readout)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(context.isStale ? IslandPalette.secondary : .white)
                        .contentTransition(.numericText())
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(caption(for: context.state, stale: context.isStale))
                        .font(.caption)
                        .foregroundStyle(IslandPalette.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                ClosenessRing(state: context.state, line: 2.6, stale: context.isStale)
                    .frame(width: 18, height: 18)
            } compactTrailing: {
                // A greyed number is too easy to read as a number. Say it.
                Text(context.isStale ? "更新なし" : context.state.readout)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(context.isStale ? IslandPalette.secondary : accent(context.state))
                    .contentTransition(.numericText())
            } minimal: {
                ClosenessRing(state: context.state, line: 2.6, stale: context.isStale)
                    .frame(width: 18, height: 18)
            }
            .keylineTint(accent(context.state))
        }
    }

    private func caption(for state: MeetActivityAttributes.ContentState, stale: Bool) -> String {
        if stale { return "アプリを開くと更新されます" }
        return state.instruction.isEmpty ? "距離を共有中" : state.instruction
    }
}
