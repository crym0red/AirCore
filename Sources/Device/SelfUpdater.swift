//
//  SelfUpdater.swift
//  Updates AirShare from the repo's latest successful build: download the
//  unsigned IPA artifact → sign it with the active cert (same bundle ID as the
//  running app) → install it over itself with the Native installer.
//
//  Runs automatically when the app opens or comes to the foreground (Settings ›
//  Install Method › Auto-update), at most every 30 minutes. If the app is sent to
//  the background mid-update it keeps going on iOS background time (~30s) — best
//  effort, not guaranteed.
//

import Foundation
import SwiftUI
import UIKit
import ZIPFoundation

@MainActor
final class SelfUpdater: ObservableObject {
    static let shared = SelfUpdater()
    static let autoKey = "AirShare.autoUpdate"
    private static let lastShaKey = "AirShare.updatedToSha"
    private static let lastCheckKey = "AirShare.lastUpdateCheck"
    private static let workflowPath = ".github/workflows/build-unsigned-ipa.yml"

    enum State: Equatable {
        case idle, checking, upToDate
        case available(String)
        case downloading, signing, installing
        case failed(String)

        var label: String {
            switch self {
            case .idle: return ""
            case .checking: return "Checking for update…"
            case .upToDate: return "AirShare is up to date"
            case .available(let s): return "Update available (\(s))"
            case .downloading: return "Downloading update…"
            case .signing: return "Signing update…"
            case .installing: return "Installing update…"
            case .failed(let m): return m
            }
        }
        var isBusy: Bool {
            switch self { case .checking, .downloading, .signing, .installing: return true; default: return false }
        }
    }

    @Published private(set) var state: State = .idle

    /// Commit this build came from: stamped into Info.plist by build.sh, else the last one we installed.
    var installedSha: String {
        if let s = Bundle.main.object(forInfoDictionaryKey: "AirShareBuildSHA") as? String, s.count >= 7, s != "unknown" { return s }
        return UserDefaults.standard.string(forKey: Self.lastShaKey) ?? ""
    }

    static var autoEnabled: Bool { NativeInstaller.isSelected && UserDefaults.standard.bool(forKey: autoKey) }

    /// Called when the app opens or returns to the foreground.
    func autoCheckIfDue() {
        guard Self.autoEnabled, !state.isBusy, !NativeInstaller.shared.isActive else { return }
        let last = UserDefaults.standard.double(forKey: Self.lastCheckKey)
        guard Date().timeIntervalSince1970 - last > 30 * 60 else { return }
        Task { await run(install: true) }
    }

    /// Settings button: check only.
    func checkNow() { Task { await run(install: false) } }
    /// Settings button: check and install if newer.
    func updateNow() { Task { await run(install: true) } }

    private struct Failure: LocalizedError { let errorDescription: String? ; init(_ m: String) { errorDescription = m } }

    private func run(install: Bool) async {
        guard !state.isBusy, !NativeInstaller.shared.isActive else { return }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastCheckKey)

        var bg: UIBackgroundTaskIdentifier = .invalid
        bg = UIApplication.shared.beginBackgroundTask(withName: "airshare-self-update") {
            if bg != .invalid { UIApplication.shared.endBackgroundTask(bg); bg = .invalid }
        }
        defer { if bg != .invalid { UIApplication.shared.endBackgroundTask(bg) } }

        var downloaded: URL?
        defer { if let downloaded { try? FileManager.default.removeItem(at: downloaded) } }
        let previousSha = UserDefaults.standard.string(forKey: Self.lastShaKey)

        do {
            let d = UserDefaults.standard
            let owner = d.string(forKey: "uzd_owner") ?? "", repo = d.string(forKey: "uzd_repo") ?? ""
            let token = Keychain.get("gh_token") ?? ""
            guard !owner.isEmpty, !repo.isEmpty, !token.isEmpty else { throw Failure("Set your GitHub owner, repo and token first.") }
            let client = ActionsClient(owner: owner, repo: repo, token: token)

            state = .checking
            guard let latest = try await client.latestRun(workflowPath: Self.workflowPath) else { throw Failure("No build found in the repo yet.") }
            let run = latest.run
            guard run.status == "completed", run.conclusion == "success" else {
                state = .upToDate   // newest build still running or failed — nothing safe to install
                return
            }
            if !installedSha.isEmpty, run.headSha == installedSha { state = .upToDate; return }
            guard install else { state = .available(run.shortSha); return }

            guard !CertificateStore.shared.certificates.isEmpty, CertificateStore.shared.active != nil else {
                throw Failure("No active certificate — add one in Settings › Certificates.")
            }
            guard let bundleID = Bundle.main.bundleIdentifier else { throw Failure("Can't read this app's bundle ID.") }

            // 1. Download the artifact zip and pull the IPA out of it.
            state = .downloading
            let arts = try await client.artifacts(runID: run.id).filter { !$0.expired }
            guard let art = arts.first(where: { $0.name.lowercased().contains("ipa") }) ?? arts.first else {
                throw Failure("The latest build has no downloadable IPA (artifact expired?).")
            }
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("selfupdate-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            downloaded = work
            let zip = work.appendingPathComponent("artifact.zip")
            try await client.downloadArtifact(id: art.id, to: zip, progress: { _ in })
            let extracted = work.appendingPathComponent("x", isDirectory: true)
            try FileManager.default.unzipItem(at: zip, to: extracted)
            let ipa = FileManager.default.enumerator(at: extracted, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }.first { $0.pathExtension.lowercased() == "ipa" }
            guard let ipa else { throw Failure("No .ipa inside the build artifact.") }

            // 2. Sign with the active cert, keeping this app's bundle ID so it installs over itself.
            state = .signing
            let material = try CertificateStore.shared.activeMaterial()
            var options = SignOptions()
            options.bundleID = bundleID
            let outcome = try await Task.detached(priority: .userInitiated) {
                try await Signer.signDetached(ipaURL: ipa, material: material, options: options, onLog: nil)
            }.value
            let entry = try SignedStore.shared.add(outcome: outcome, icon: nil, certName: material.name)

            // 3. Native install over ourselves. iOS restarts the app when it finishes.
            state = .installing
            UserDefaults.standard.set(run.headSha, forKey: Self.lastShaKey)
            do {
                try await NativeInstaller.shared.install(entry)
            } catch {
                if let previousSha { UserDefaults.standard.set(previousSha, forKey: Self.lastShaKey) }
                else { UserDefaults.standard.removeObject(forKey: Self.lastShaKey) }
                throw error
            }
            state = .upToDate
        } catch is CancellationError {
            state = .idle
        } catch {
            state = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }
}

// MARK: - Settings card (shown under the Install Method picker in Native mode)

struct SelfUpdateCard: View {
    @ObservedObject private var updater = SelfUpdater.shared
    @AppStorage(SelfUpdater.autoKey) private var auto = false
    private let accent = Color(red: 1.0, green: 0.6, blue: 0.1)
    private var isFailed: Bool { if case .failed = updater.state { return true } else { return false } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("SELF-UPDATE").font(.system(size: 11, weight: .heavy)).kerning(2.2).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: $auto) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Auto-update AirShare").font(.system(size: 15, weight: .semibold))
                        Text("Installs the repo's latest build when you open the app.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                .tint(accent)
                HStack(spacing: 10) {
                    Button { updater.checkNow() } label: { Text("Check").font(.system(size: 13, weight: .semibold)) }
                        .buttonStyle(.bordered).tint(accent).disabled(updater.state.isBusy)
                    Button { updater.updateNow() } label: { Text("Update now").font(.system(size: 13, weight: .semibold)) }
                        .buttonStyle(.borderedProminent).tint(accent).disabled(updater.state.isBusy)
                    if updater.state.isBusy { ProgressView().padding(.leading, 4) }
                    Spacer(minLength: 0)
                }
                if !updater.state.label.isEmpty {
                    Text(updater.state.label).font(.system(size: 12))
                        .foregroundStyle(isFailed ? Color.red : Color.secondary)
                        .lineLimit(4)
                }
            }
            .padding(12)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(accent.opacity(0.35), lineWidth: 1))
        }
    }
}
