//
//  AirShareLiveActivity.swift
//  Lock-screen banner + Dynamic Island for AirShare downloads, signing and installs.
//

import ActivityKit
import SwiftUI
import WidgetKit

@main
struct AirShareLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        if #available(iOS 16.1, *) { AirShareLiveActivityWidget() }
    }
}

@available(iOS 16.1, *)
struct AirShareLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AirShareActivityAttributes.self) { context in
            LockScreenView(state: context.state)
                .activityBackgroundTint(Color.black.opacity(0.85))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let s = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: s.symbol).font(.title2).foregroundStyle(tint(s))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("\(Int((s.progress * 100).rounded()))%").font(.title3.weight(.bold)).monospacedDigit()
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(s.title).font(.headline).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: min(max(s.progress, 0), 1)).tint(tint(s))
                        Text(s.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            } compactLeading: {
                Image(systemName: s.symbol).foregroundStyle(tint(s))
            } compactTrailing: {
                Text("\(Int((s.progress * 100).rounded()))%").font(.caption2.weight(.bold)).monospacedDigit()
            } minimal: {
                Image(systemName: s.symbol).foregroundStyle(tint(s))
            }
        }
    }
}

@available(iOS 16.1, *)
private func tint(_ s: AirShareActivityAttributes.ContentState) -> Color {
    s.failed ? .orange : (s.finished ? .green : Color(red: 0.25, green: 0.6, blue: 1))
}

@available(iOS 16.1, *)
private struct LockScreenView: View {
    let state: AirShareActivityAttributes.ContentState
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: state.symbol).font(.system(size: 26)).foregroundStyle(tint(state)).frame(width: 34)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(state.title).font(.system(size: 15, weight: .bold)).lineLimit(1)
                    Spacer()
                    Text("\(Int((state.progress * 100).rounded()))%").font(.system(size: 15, weight: .bold)).monospacedDigit()
                }
                ProgressView(value: min(max(state.progress, 0), 1)).tint(tint(state))
                Text(state.detail).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(16)
    }
}
