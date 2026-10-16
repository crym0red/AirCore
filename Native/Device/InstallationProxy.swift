import Foundation
import Combine
import UIKit
import IDevice

// A completed error response from iOS's installer means the app was rejected,
// rather than the transport failing. Keep its original message for the row.
public struct IDeviceInstallationRejection: LocalizedError {
    private let message: String
    public var errorDescription: String? { message }
    init(message: String) { self.message = message }
}

/// An IPA that arrives in two parts: a prefix that is known up front (uploaded while the app is still
/// being signed) and a tail (changed files + zip directory) that is supplied once signing finishes.
public final class StreamedIPA: @unchecked Sendable {
    public struct Failure: LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
        public init(_ message: String) { self.message = message }
    }
    private let lock = NSLock()
    private let prefixSignal = DispatchSemaphore(value: 0)
    private let tailSignal = DispatchSemaphore(value: 0)
    private var prefix: Result<URL, Error>?
    private var tail: Result<URL, Error>?
    public init() {}

    public func setPrefix(_ r: Result<URL, Error>) {
        lock.lock(); let first = prefix == nil; if first { prefix = r }; lock.unlock()
        if first { prefixSignal.signal() }
    }
    public func setTail(_ r: Result<URL, Error>) {
        lock.lock(); let first = tail == nil; if first { tail = r }; lock.unlock()
        if first { tailSignal.signal() }
    }
    func waitPrefix(_ check: () throws -> Void) throws -> URL {
        while prefixSignal.wait(timeout: .now() + 0.25) == .timedOut { try check() }
        lock.lock(); defer { lock.unlock() }
        return try prefix!.get()
    }
    func waitTail(_ check: () throws -> Void) throws -> URL {
        while tailSignal.wait(timeout: .now() + 0.25) == .timedOut { try check() }
        lock.lock(); defer { lock.unlock() }
        return try tail!.get()
    }
}

public final class InstallationProxy: Identifiable, ObservableObject {
    public let viewModel: InstallerStatusViewModel
    private let cancellation = IDeviceInstallCancellation()
    private var isCurrent: () -> Bool = { true }

    public init(viewModel: InstallerStatusViewModel) { self.viewModel = viewModel }

    // Each proxy is one attempt. Cancellation waits for any native call already
    // in progress to return before releasing resources and its admission slot.
    public func install(at url: URL, suspend: Bool = false, streamed: StreamedIPA? = nil,
                        isCurrent: @escaping () -> Bool = { true }) async throws {
        self.isCurrent = isCurrent
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await IDeviceInstallationWorker.performInstallation { [self] in
                try cancellation.check()
                try installSynchronously(at: url, suspend: suspend, streamed: streamed)
            }
            try cancellation.check()
            await MainActor.run {
                if isCurrent() { viewModel.status = .completed(.success(())) }
            }
        } onCancel: { [cancellation] in cancellation.cancel() }
    }

    private func checkCancellation() throws {
        try cancellation.check()
        if !isCurrent() { throw CancellationError() }
    }

    private func update(_ action: @escaping (InstallerStatusViewModel) -> Void) {
        DispatchQueue.main.async { [self] in
            guard !cancellation.isCancelled, isCurrent() else { return }
            action(viewModel)
        }
    }

    private func check(_ error: UnsafeMutablePointer<IdeviceFfiError>?) throws {
        guard let error else { return }
        defer { idevice_error_free(error) }
        // Pinned idevice: InstallationProxy = 107, OperationFailed = 1.
        // Socket failures remain transport errors, even during installation.
        if error.pointee.code == 107 && error.pointee.sub_code == 1 {
            throw IDeviceInstallationRejection(message: IDeviceSwiftError(error).localizedDescription)
        }
        throw IDeviceSwiftError(error)
    }

    private func installSynchronously(at url: URL, suspend: Bool, streamed: StreamedIPA?) throws {
        let heartbeat = HeartbeatManager.shared
        guard FileManager.default.fileExists(atPath: HeartbeatManager.pairingFile()) else {
            throw IDeviceSwiftError(message: "Pair this device in Installation settings before installing.")
        }
        // Keep a lease on the workflow's shared tunnel until this attempt's
        // clients are freed. Per-app handles stay on this worker thread.
        let connection = heartbeat.isRsd ? try heartbeat.acquireRSDConnection() : nil
        defer { withExtendedLifetime(connection) {} }
        let provider = connection == nil ? try makeLegacyProvider(heartbeat) : nil
        defer { idevice_provider_free(provider) }
        try checkCancellation()
        var afc: OpaquePointer?
        var proxy: OpaquePointer?
        var file: OpaquePointer?
        var remotePath: String?
        defer {
            if let file { idevice_error_free(afc_file_close(file)) }
            if let remotePath { idevice_error_free(afc_remove_path(afc, remotePath)) }
            installation_proxy_client_free(proxy)
            afc_client_free(afc)
        }
        if let connection {
            try connection.withServiceConnection { adapter, handshake in
                try check(afc_client_connect_rsd(adapter, handshake, &afc))
            }
        } else {
            try check(afc_client_connect(provider, &afc))
        }
        // PublicStaging normally exists. Ignore only AFC's OBJECT_EXISTS status.
        if let error = afc_make_directory(afc, "PublicStaging") {
            defer { idevice_error_free(error) }
            guard error.pointee.sub_code == 16 else { throw IDeviceSwiftError(error) }
        }
        let stagingPath = "/PublicStaging/\(UUID().uuidString).ipa"
        remotePath = stagingPath
        try check(afc_file_open(afc, stagingPath, AfcWrOnly, &file))
        // Bound resident upload memory per admitted job: files are streamed in chunks.
        // Chunk size is user-selectable (Settings › Install Method › Connection); each write is one round trip.
        let chosenMB = UserDefaults.standard.integer(forKey: "AirShare.uploadChunkMB")
        let chunkBytes = [1, 2, 4, 8, 16].contains(chosenMB) ? chosenMB * 1_048_576 : 4 * 1_048_576
        var sent: UInt64 = 0
        var knownTotal: UInt64 = 0
        var tailPending = false
        func fileSize(_ u: URL) -> UInt64 {
            ((try? FileManager.default.attributesOfItem(atPath: u.path)[.size] as? NSNumber)?.uint64Value) ?? 0
        }
        func send(_ fileURL: URL) throws {
            let input = try FileHandle(forReadingFrom: fileURL)
            defer { try? input.close() }
            let byteCount = try input.seekToEnd()
            try input.seek(toOffset: 0)
            var offset: UInt64 = 0
            while offset < byteCount {
                try checkCancellation()
                let size = Int(min(UInt64(chunkBytes), byteCount - offset))
                let written = try autoreleasepool { () throws -> Int in
                    guard let data = try input.read(upToCount: size), !data.isEmpty else {
                        throw IDeviceSwiftError(message: "The IPA ended before its upload completed.")
                    }
                    try data.withUnsafeBytes { bytes in
                        try check(afc_file_write(file, bytes.baseAddress!.assumingMemoryBound(to: UInt8.self), data.count))
                    }
                    return data.count
                }
                offset += UInt64(written)
                sent += UInt64(written)
                let denominator = Double(max(knownTotal + (tailPending ? knownTotal / 10 : 0), 1))
                let progress = min(1, Double(sent) / denominator)
                update { $0.uploadProgress = progress }
            }
        }
        update { $0.packageProgress = 1; $0.status = .sendingPayload }
        if let streamed {
            // Upload what's already known while the app is still being signed, then the changed tail.
            let prefixURL = try streamed.waitPrefix { try self.checkCancellation() }
            knownTotal = fileSize(prefixURL); tailPending = true
            try send(prefixURL)
            let tailURL = try streamed.waitTail { try self.checkCancellation() }
            knownTotal += fileSize(tailURL); tailPending = false
            try send(tailURL)
        } else {
            let byteCount = fileSize(url)
            guard byteCount > 0 else { throw IDeviceSwiftError(message: "The IPA is empty.") }
            knownTotal = byteCount
            try send(url)
        }
        let closeResult = afc_file_close(file)
        file = nil // close consumes the handle, including on failure
        try check(closeResult)
        try checkCancellation()
        if let connection {
            try connection.withServiceConnection { adapter, handshake in
                try check(installation_proxy_connect_rsd(adapter, handshake, &proxy))
            }
        } else {
            try check(installation_proxy_connect(provider, &proxy))
        }
        update { $0.status = .installing }
        let context = Unmanaged.passUnretained(self).toOpaque()
        if suspend {
            DispatchQueue.main.async { UIApplication.shared.perform(#selector(NSXPCConnection.suspend)) }
        }
        try check(installation_proxy_install_with_callback(proxy, stagingPath, nil, Self.progressCallback, context))
        try checkCancellation()
    }

    private func makeLegacyProvider(_ heartbeat: HeartbeatManager) throws -> OpaquePointer {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = heartbeat.port.bigEndian
        guard inet_pton(AF_INET, heartbeat.ipAddress, &address.sin_addr) == 1,
              let pairing = heartbeat.getPairing() else {
            throw IDeviceSwiftError(message: "The device pairing or address is unavailable.")
        }
        var provider: OpaquePointer?
        let error = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: idevice_sockaddr.self, capacity: 1) {
                idevice_tcp_provider_new($0, pairing, "AirShare installation", &provider)
            }
        }
        // The constructor consumes pairing on success; the address and label
        // above are valid, so an error leaves that ownership with us.
        if let error {
            idevice_pairing_file_free(pairing)
            try check(error)
        }
        guard let provider else { throw IDeviceSwiftError(message: "Could not create the device connection.") }
        return provider
    }

    private static let progressCallback: @convention(c) (UInt64, UnsafeMutableRawPointer?) -> Void = { progress, context in
        guard let context else { return }
        let operation = Unmanaged<InstallationProxy>.fromOpaque(context).takeUnretainedValue()
        operation.update { $0.installProgress = min(1, Double(progress) / 100) }
    }
}
