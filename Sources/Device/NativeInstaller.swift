//
//  NativeInstaller.swift
//  On-device installation through AirShare's built-in local VPN + pairing
//  (iDevice). Same call shape as OTAInstaller so every install entry point can
//  route here when "Install method" is set to Native in Settings.
//

import Combine
import Foundation
import IDeviceSwift
import SwiftUI

@MainActor
final class NativeInstaller: ObservableObject {
    static let shared = NativeInstaller()
    static let methodKey = "AirShare.installMethod"   // "ota" (default) | "native"

    static var isSelected: Bool {
        UserDefaults.standard.string(forKey: methodKey) == "native"
    }

    struct Job: Identifiable, Equatable {
        let id = UUID()
        let name: String
        let bundleID: String
    }

    enum Stage: Equatable {
        case idle, connecting, uploading, installing, done, failed(String)
        var label: String {
            switch self {
            case .idle: return ""
            case .connecting: return "Connecting to this device…"
            case .uploading: return "Sending IPA…"
            case .installing: return "Installing…"
            case .done: return "Installed"
            case .failed(let m): return m
            }
        }
    }

    @Published private(set) var job: Job?
    @Published private(set) var stage: Stage = .idle
    @Published private(set) var progress: Double = 0

    var isActive: Bool {
        switch stage { case .connecting, .uploading, .installing: return true; default: return false }
    }

    private var observer: AnyCancellable?
    private var workflowID: UUID?
    private init() {}

    enum InstallError: LocalizedError {
        case ipaMissing, busy
        var errorDescription: String? {
            switch self {
            case .ipaMissing: return "Signed IPA not found on disk."
            case .busy: return "A native install is already running."
            }
        }
    }

    func install(_ app: SignedEntry) async throws {
        try await install(ipaURL: app.ipaURL, bundleID: app.bundleID, name: app.name, version: app.version)
    }

    func install(ipaURL: URL, bundleID: String, name: String, version: String) async throws {
        guard FileManager.default.fileExists(atPath: ipaURL.path) else { throw InstallError.ipaMissing }
        guard !isActive else { throw InstallError.busy }

        let manager = DeviceInstallationManager.shared
        let viewModel = InstallerStatusViewModel(isIdevice: true)
        let id = UUID()
        workflowID = id
        job = Job(name: name, bundleID: bundleID)
        stage = .connecting
        progress = 0

        observer = viewModel.objectWillChange.sink { [weak self, weak viewModel] _ in
            // objectWillChange fires before the value lands; read on the next turn.
            DispatchQueue.main.async {
                guard let self, let viewModel, self.workflowID == id else { return }
                self.progress = viewModel.overallProgress
                switch viewModel.status {
                case .sendingManifest, .sendingPayload: self.stage = .uploading
                case .installing: self.stage = .installing
                default: break
                }
            }
        }

        manager.retainWorkflow(id)
        defer {
            manager.releaseWorkflow(id)
            observer = nil
            workflowID = nil
        }
        do {
            try await manager.install(at: ipaURL, viewModel: viewModel,
                                      suspend: bundleID == Bundle.main.bundleIdentifier,
                                      mode: manager.mode, bundleIdentifier: bundleID,
                                      isCurrent: { true })
            progress = 1
            stage = .done
            ZefvVPS.report(bundle: bundleID, version: version, name: name, stage: "installed")
        } catch is CancellationError {
            stage = .idle
            job = nil
            throw CancellationError()
        } catch {
            stage = .failed(error.localizedDescription)
            throw error
        }
    }

    func dismiss() {
        guard !isActive else { return }
        stage = .idle
        job = nil
        progress = 0
    }
}

// MARK: - Progress banner (shown over any tab while a native install runs)

struct NativeInstallBanner: View {
    @ObservedObject private var installer = NativeInstaller.shared
    @ObservedObject private var reconnect = VPNReconnectCoordinator.shared
    @ObservedObject private var manager = DeviceInstallationManager.shared
    @ObservedObject private var pairing = DevicePairingService.shared

    var body: some View {
        VStack(spacing: 8) {
            if let job = installer.job, installer.stage != .idle {
                card(job)
            }
            if reconnect.pendingShortcutName != nil, !installer.isActive {
                Button {
                    Task { await reconnect.runPendingShortcut() }
                } label: {
                    Label("Reconnect VPN", systemImage: "network").font(.footnote.weight(.semibold))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .disabled(!manager.canReconnectVPN)
            }
        }
        .padding(.top, 6)
        .animation(.easeInOut(duration: 0.2), value: installer.stage)
    }

    private func card(_ job: NativeInstaller.Job) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                icon
                Text(job.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 8)
                if !installer.isActive {
                    Button { installer.dismiss() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                }
            }
            if case .failed = installer.stage {
                Text(installer.stage.label).font(.caption).foregroundStyle(.red).lineLimit(4)
            } else if manager.phase == .pairing {
                if let pin = pairing.pin {
                    Text("Pairing code \(pin) — enter it in Settings › Developer Mode.")
                        .font(.caption.monospacedDigit())
                } else {
                    Text("Open Settings › Privacy & Security › Developer Mode and choose Pair with AirShare.")
                        .font(.caption)
                }
            } else {
                Text(installer.stage.label).font(.caption).foregroundStyle(.secondary)
                if installer.isActive { ProgressView(value: installer.progress) }
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 14)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    @ViewBuilder private var icon: some View {
        switch installer.stage {
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        default: Image(systemName: "arrow.down.app.fill")
        }
    }
}

// MARK: - Install method picker (signing sheet)

/// Drop-down shown in the signing sheet. Same setting as Settings › Install Method.
struct InstallMethodPicker: View {
    @AppStorage(NativeInstaller.methodKey) private var method: String = "ota"
    private let accent = Color(red: 1.0, green: 0.6, blue: 0.1)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("INSTALL METHOD").font(.system(size: 11, weight: .heavy)).kerning(2.2).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Image(systemName: method == "native" ? "point.3.connected.trianglepath.dotted" : "globe")
                    .font(.system(size: 18, weight: .bold)).foregroundStyle(accent)
                    .frame(width: 40, height: 40)
                    .background(accent.opacity(0.16), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(method == "native" ? "Native · built-in VPN" : "OTA · itms-services")
                        .font(.system(size: 16, weight: .semibold))
                    Text(method == "native" ? "Installs straight to this device. No domain or TLS cert."
                                            : "Installs through your AirShare domain and cert.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 0)
                Menu {
                    Button { method = "ota" } label: {
                        Label("OTA · itms-services", systemImage: method == "ota" ? "checkmark" : "globe")
                    }
                    Button { method = "native" } label: {
                        Label("Native · built-in VPN", systemImage: method == "native" ? "checkmark" : "point.3.connected.trianglepath.dotted")
                    }
                } label: {
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 14, weight: .bold)).foregroundStyle(accent)
                        .frame(width: 40, height: 40)
                        .background(accent.opacity(0.14), in: Circle())
                }
            }
            .padding(12)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(accent.opacity(0.35), lineWidth: 1))
        }
    }
}

/// Hides OTA-only UI (domain / TLS cert tiles) while Native install is selected.
struct HiddenWhenNative<Content: View>: View {
    @AppStorage(NativeInstaller.methodKey) private var method: String = "ota"
    @ViewBuilder var content: () -> Content
    var body: some View {
        if method != "native" { content() }
    }
}
