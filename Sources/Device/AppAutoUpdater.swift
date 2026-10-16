//
//  AppAutoUpdater.swift
//  Keeps the apps you installed through AirShare up to date. For every tracked
//  app it checks your sources for a newer version, downloads the IPA, signs it
//  with your active certificate and installs it with the Native installer — no
//  Apple prompt, no taps. Runs when AirShare opens or returns to the foreground.
//
//  Tracked apps = apps AirShare installed natively, plus anything added with
//  "Track apps I've signed". Remove an app from the list to stop updating it.
//

import Foundation
import SwiftUI
import UIKit
import UserNotifications

struct TrackedApp: Codable, Identifiable, Equatable {
    var id: String { bundleID }
    let bundleID: String
    var name: String
    var version: String
}

@MainActor
final class AppAutoUpdater: ObservableObject {
    static let shared = AppAutoUpdater()
    static let enabledKey = "AirShare.autoUpdateApps"
    private static let trackedKey = "AirShare.trackedApps"
    private static let lastCheckKey = "AirShare.lastAppUpdateCheck"

    @Published private(set) var tracked: [TrackedApp] = []
    @Published private(set) var busy = false
    @Published private(set) var status = ""

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.trackedKey),
           let list = try? JSONDecoder().decode([TrackedApp].self, from: data) { tracked = list }
    }

    static var autoEnabled: Bool { NativeInstaller.isSelected && UserDefaults.standard.bool(forKey: enabledKey) }

    // MARK: Tracking

    /// Called by NativeInstaller after every successful install.
    func recordInstalled(bundleID: String, name: String, version: String) {
        guard bundleID != Bundle.main.bundleIdentifier else { return }
        if let i = tracked.firstIndex(where: { $0.bundleID == bundleID }) {
            tracked[i].version = version; tracked[i].name = name
        } else {
            tracked.append(TrackedApp(bundleID: bundleID, name: name, version: version))
        }
        persist()
    }

    func untrack(_ app: TrackedApp) {
        tracked.removeAll { $0.bundleID == app.bundleID }
        persist()
    }

    /// Adds every app you've signed in AirShare (latest signed version of each).
    func trackSignedApps() {
        for e in SignedStore.shared.entries where e.bundleID != Bundle.main.bundleIdentifier {
            guard !tracked.contains(where: { $0.bundleID == e.bundleID }) else { continue }
            tracked.append(TrackedApp(bundleID: e.bundleID, name: e.name, version: e.version))
        }
        persist()
        status = "Tracking \(tracked.count) app\(tracked.count == 1 ? "" : "s")"
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(tracked) { UserDefaults.standard.set(data, forKey: Self.trackedKey) }
    }

    // MARK: Triggers

    func autoCheckIfDue() {
        guard Self.autoEnabled, !busy, !tracked.isEmpty else { return }
        let last = UserDefaults.standard.double(forKey: Self.lastCheckKey)
        guard Date().timeIntervalSince1970 - last > 30 * 60 else { return }
        Task { await run() }
    }

    func updateNow() { Task { await run() } }

    // MARK: Update loop

    private func run() async {
        guard !busy else { return }
        guard !NativeInstaller.shared.isActive, !SelfUpdater.shared.state.isBusy else {
            status = "Waiting — another install is running"
            return
        }
        busy = true
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastCheckKey)

        var bg: UIBackgroundTaskIdentifier = .invalid
        bg = UIApplication.shared.beginBackgroundTask(withName: "airshare-app-updates") {
            if bg != .invalid { UIApplication.shared.endBackgroundTask(bg); bg = .invalid }
        }
        defer {
            busy = false
            if bg != .invalid { UIApplication.shared.endBackgroundTask(bg) }
        }

        status = "Checking sources…"
        var updated = 0, failed = 0
        let trackedNow = tracked

        // Newest version of each tracked app across all your sources.
        var latest: [String: SourceApp] = [:]
        for source in SourceStore.shared.sources {
            guard let repo = try? await SourceStore.shared.fetch(source) else { continue }
            for group in repo.groups {
                let app = group.latest
                guard trackedNow.contains(where: { Self.sourceBundle($0) == app.bundle }) else { continue }
                if let cur = latest[app.bundle], !Self.isNewer(app.version, than: cur.version) { continue }
                latest[app.bundle] = app
            }
        }

        for t in trackedNow {
            let installed = Self.installedSourceVersion(t)
            guard let app = latest[Self.sourceBundle(t)], Self.isNewer(app.version, than: installed) else { continue }
            guard let url = app.downloadURL else { failed += 1; continue }
            status = "Updating \(app.name) \(installed) → \(app.version)…"
            do {
                try await update(app, from: url, tracked: t)
                updated += 1
            } catch {
                failed += 1
                status = "\(app.name): \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
            }
        }

        if updated == 0 && failed == 0 { status = "All tracked apps are up to date" }
        else if failed == 0 { status = "Updated \(updated) app\(updated == 1 ? "" : "s")" }
        else if updated > 0 { status = "Updated \(updated), \(failed) failed" }
        // single failure keeps its specific message
        if updated > 0 { notify("Updated \(updated) app\(updated == 1 ? "" : "s") in AirShare") }
    }

    /// Bundle ID the sources list for this app (differs from the installed one if it was renamed / randomized when signed).
    private static func sourceBundle(_ t: TrackedApp) -> String {
        SignProfileStore.shared.profile(forSigned: t.bundleID)?.sourceBundleID ?? t.bundleID
    }
    /// Version of the source IPA that is installed (not any version override applied at signing).
    private static func installedSourceVersion(_ t: TrackedApp) -> String {
        SignProfileStore.shared.profile(forSigned: t.bundleID)?.sourceVersion ?? t.version
    }

    private func update(_ app: SourceApp, from url: URL, tracked t: TrackedApp) async throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("appupdate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue("AirShare-AutoUpdate", forHTTPHeaderField: "User-Agent")
        let (tmp, resp) = try await URLSession.shared.download(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SourceWatcherError.downloadFailed
        }
        let ipa = work.appendingPathComponent("app.ipa")
        try FileManager.default.moveItem(at: tmp, to: ipa)

        let material = try CertificateStore.shared.activeMaterial()
        // Same options the app was originally signed with (bundle ID, name, icon, dylibs, entitlements…).
        let options: SignOptions
        if let profile = SignProfileStore.shared.profile(forSigned: t.bundleID) {
            options = SignProfileStore.shared.options(for: profile, newVersion: app.version, fallbackName: app.name)
        } else {
            var o = SignOptions()
            o.name = t.name; o.bundleID = t.bundleID; o.version = app.version
            options = o
        }
        let outcome = try await Task.detached(priority: .userInitiated) {
            try await Signer.signDetached(ipaURL: ipa, material: material, options: options, onLog: nil, captureOutput: false)
        }.value
        let icon = (try? IPAMeta.read(outcome.ipaURL).iconPNG) ?? nil
        let entry = try SignedStore.shared.add(outcome: outcome, icon: icon, certName: material.name)
        try await NativeInstaller.shared.install(entry)   // records the new version via recordInstalled
        SignProfileStore.shared.setSourceVersion(app.version, forSigned: t.bundleID)
    }

    private func notify(_ text: String) {
        let c = UNMutableNotificationContent()
        c.title = "AirShare"; c.body = text; c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: "airshare.appupdates", content: c,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)))
    }

    private static func isNewer(_ lhs: String, than rhs: String) -> Bool {
        let a = lhs.split(separator: ".").map { Int($0.filter { $0.isNumber }) ?? 0 }
        let b = rhs.split(separator: ".").map { Int($0.filter { $0.isNumber }) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let av = i < a.count ? a[i] : 0, bv = i < b.count ? b[i] : 0
            if av != bv { return av > bv }
        }
        return false
    }
}

// MARK: - Settings card (under Self-update in Native mode)

struct AppUpdateCard: View {
    @ObservedObject private var updater = AppAutoUpdater.shared
    @AppStorage(AppAutoUpdater.enabledKey) private var auto = false
    private let accent = Color(red: 1.0, green: 0.6, blue: 0.1)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("APP UPDATES").font(.system(size: 11, weight: .heavy)).kerning(2.2).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: $auto) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Auto-update my apps").font(.system(size: 15, weight: .semibold))
                        Text("When you open AirShare, newer versions of your tracked apps are signed and installed automatically.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                .tint(accent)
                HStack(spacing: 10) {
                    Button { updater.updateNow() } label: { Text("Update now").font(.system(size: 13, weight: .semibold)) }
                        .buttonStyle(.borderedProminent).tint(accent).disabled(updater.busy)
                    Button { updater.trackSignedApps() } label: { Text("Track apps I've signed").font(.system(size: 13, weight: .semibold)) }
                        .buttonStyle(.bordered).tint(accent)
                    if updater.busy { ProgressView() }
                    Spacer(minLength: 0)
                }
                if !updater.status.isEmpty {
                    Text(updater.status).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(3)
                }
                if updater.tracked.isEmpty {
                    Text("No tracked apps yet. Apps you install with Native are added automatically.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 0) {
                        ForEach(updater.tracked) { app in
                            HStack {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(app.name).font(.system(size: 14, weight: .medium)).lineLimit(1)
                                    Text("v\(app.version) · \(app.bundleID)").font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                Button { updater.untrack(app) } label: {
                                    Image(systemName: "minus.circle.fill").foregroundStyle(.red.opacity(0.85))
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.vertical, 6)
                            if app.id != updater.tracked.last?.id { Divider().opacity(0.3) }
                        }
                    }
                }
            }
            .padding(12)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(accent.opacity(0.35), lineWidth: 1))
        }
    }
}
