//
//  App.swift
//  unzip-drop — drop a zip, extract on-device, push it to a repo.
//

import SwiftUI

@main
struct UnzipDropApp: App {
    @StateObject private var session = Session()
    @StateObject private var config = Config()
    @StateObject private var notifications = NotificationManager.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .task { LocalZSignAPI.shared.startIfNeeded() }
                .environmentObject(session)
                .environmentObject(config)
                .onOpenURL { url in session.receiveIncoming(url) }
        }
        .backgroundTask(.appRefresh("com.mrzefv.airshare.source-scan")) {
            await LocalSourceUpdateWatcher.shared.scanAllSources(reason: "background")
        }
    }
}
