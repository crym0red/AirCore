//
//  AirShareActivityAttributes.swift
//  Shared by the app and the Live Activity widget extension (compiled into both targets).
//

import ActivityKit
import Foundation

@available(iOS 16.1, *)
struct AirShareActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var title: String        // "Installing 3 Apps"
        var detail: String       // "2/3 · Signing Dynamic Lyrics"
        var progress: Double     // 0...1
        var symbol: String       // SF Symbol for the current step
        var finished: Bool
        var failed: Bool
    }
    var startedAt: Date
}
