//
//  InstallLiveActivity.swift
//  Drives the lock-screen / Dynamic Island progress for downloads, signing and installs.
//  Started and stopped by BackgroundKeepAlive (so it lives exactly as long as the song does).
//

import ActivityKit
import Foundation

@MainActor
final class InstallLiveActivity {
    static let shared = InstallLiveActivity()
    private var activity: Any?            // Activity<AirShareActivityAttributes> (iOS 16.1+)
    private var lastKey: String?
    private init() {}
    var isActive: Bool { activity != nil }

    struct Snapshot {
        var title: String, detail: String, progress: Double, symbol: String
        var accentHex: String = AppTheme.shared.accentHex
    }

    func update(_ s: Snapshot) {
        guard #available(iOS 16.2, *), ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let state = AirShareActivityAttributes.ContentState(title: s.title, detail: s.detail, progress: min(max(s.progress, 0), 1),
                                                           symbol: s.symbol, finished: false, failed: false, accentHex: s.accentHex)
        let key = "\(state.title)|\(state.detail)|\(Int(state.progress * 100))"
        guard key != lastKey else { return }
        lastKey = key
        if let a = activity as? Activity<AirShareActivityAttributes> {
            Task { await a.update(ActivityContent(state: state, staleDate: nil)) }
        } else {
            activity = try? Activity.request(attributes: AirShareActivityAttributes(startedAt: Date()),
                                             content: ActivityContent(state: state, staleDate: nil), pushType: nil)
        }
    }

    func end(title: String, detail: String, failed: Bool) {
        guard #available(iOS 16.2, *), let a = activity as? Activity<AirShareActivityAttributes> else { activity = nil; lastKey = nil; return }
        let state = AirShareActivityAttributes.ContentState(title: title, detail: detail, progress: 1,
                                                           symbol: failed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill",
                                                           finished: !failed, failed: failed, accentHex: AppTheme.shared.accentHex)
        activity = nil; lastKey = nil
        Task { await a.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .after(Date().addingTimeInterval(8))) }
    }
}
