//
//  BackgroundKeepAlive.swift
//  Keeps AirShare running while an install is in progress, so you can leave the app mid-install.
//
//  While at least one install workflow is active, a silent audio loop plays (UIBackgroundModes = audio,
//  mixes with whatever else is playing). While you're outside the app it also keeps one quiet banner
//  up to date ("Installing 4 Apps · 60% · Dynamic Lyrics") and posts "Installed …" when it's done.
//  Nothing runs when no install is active, so idle battery cost is zero.
//

import AVFoundation
import Combine
import UIKit
import UserNotifications

@MainActor
final class BackgroundKeepAlive: ObservableObject {
    static let shared = BackgroundKeepAlive()
    static let enabledKey = "AirShare.keepAlive"
    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
    private static let bannerID = "airshare.install.progress"
    static let songKey = "AirShare.installSongFile"
    static let songTitleKey = "AirShare.installSongTitle"

    @Published private(set) var isHolding = false
    @Published private(set) var isPreviewing = false
    private var songPlayer: AVAudioPlayer?
    private var previewPlayer: AVAudioPlayer?

    private var holds = Set<String>()
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var graphBuilt = false
    private var observers: [NSObjectProtocol] = []
    private var ticker: AnyCancellable?
    private var lastPercent = -1
    private var lastBody = ""
    private var idleSince: Date?

    private init() {}

    // MARK: Install song (your own track instead of silence)

    struct SongError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static var songURL: URL? {
        guard let name = UserDefaults.standard.string(forKey: songKey) else { return nil }
        let u = AppPaths.dir("install-song").appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    /// Copies the picked file into AirShare's own storage and remembers it.
    func setSong(from picked: URL) throws {
        let fm = FileManager.default
        let dir = AppPaths.dir("install-song")
        let ext = picked.pathExtension.isEmpty ? "m4a" : picked.pathExtension.lowercased()
        let dest = dir.appendingPathComponent("song-\(UUID().uuidString.prefix(8)).\(ext)")
        try fm.copyItem(at: picked, to: dest)
        guard (try? AVAudioPlayer(contentsOf: dest)) != nil else {
            try? fm.removeItem(at: dest)
            throw SongError(message: "That file can't be played. Try an MP3, M4A, WAV or AAC file.")
        }
        stopPreview()
        for f in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] where f.lastPathComponent != dest.lastPathComponent { try? fm.removeItem(at: f) }   // compare names: /var vs /private/var URLs differ and used to delete the new song too
        UserDefaults.standard.set(dest.lastPathComponent, forKey: Self.songKey)
        UserDefaults.standard.set(picked.deletingPathExtension().lastPathComponent, forKey: Self.songTitleKey)
    }

    func removeSong() {
        stopPreview()
        let fm = FileManager.default
        let dir = AppPaths.dir("install-song")
        for f in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] { try? fm.removeItem(at: f) }
        UserDefaults.standard.removeObject(forKey: Self.songKey)
        UserDefaults.standard.removeObject(forKey: Self.songTitleKey)
    }

    /// Plays up to 15 seconds of the chosen song so you can check it.
    func togglePreview() {
        if isPreviewing { stopPreview(); return }
        guard !isHolding, let url = Self.songURL, let p = try? AVAudioPlayer(contentsOf: url) else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        p.prepareToPlay(); p.play()
        previewPlayer = p
        isPreviewing = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            if self?.previewPlayer === p { self?.stopPreview() }
        }
    }

    func stopPreview() {
        guard isPreviewing || previewPlayer != nil else { return }
        previewPlayer?.stop(); previewPlayer = nil; isPreviewing = false
        if !isHolding { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
    }

    // MARK: Hold / release (called with every install workflow)

    func start(_ id: String) {
        guard Self.enabled else { return }
        let first = holds.isEmpty
        holds.insert(id)
        guard first else { return }
        stopPreview()
        beginAudio()
        lastPercent = -1; lastBody = ""; idleSince = nil
        ticker = Timer.publish(every: 2, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        isHolding = true
    }

    func stop(_ id: String) {
        guard holds.remove(id) != nil, holds.isEmpty else { return }
        teardown(announceFinish: true)
    }

    private func teardown(announceFinish: Bool) {
        holds.removeAll()
        ticker = nil
        endAudio()
        isHolding = false
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.bannerID])
        guard announceFinish, UIApplication.shared.applicationState != .active else { return }
        let installer = NativeInstaller.shared
        // Batches and automatic updates post their own summary.
        guard !NativeBatchInstaller.shared.isRunning, !AppAutoUpdater.shared.busy,
              installer.stage == .done, let name = installer.job?.name else { return }
        post(id: "airshare.install.done", title: "Installed \(name)", body: "It's on your Home Screen.", quiet: false)
    }

    // MARK: Silent audio

    private func beginAudio() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true)
        if !graphBuilt, let fmt = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1) {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: fmt)
            graphBuilt = true
        }
        playBackground()
        observers = [
            NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
                let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                guard raw == AVAudioSession.InterruptionType.ended.rawValue else { return }
                Task { @MainActor in self?.resumeAudio() }
            },
            NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.resumeAudio() }
            },
        ]
    }

    /// Your song (looping) if you picked one, otherwise silence.
    private func playBackground() {
        if let url = Self.songURL, let p = try? AVAudioPlayer(contentsOf: url) {
            p.numberOfLoops = -1
            p.volume = 1
            p.prepareToPlay()
            if p.play() { songPlayer = p; return }
        }
        songPlayer = nil
        playSilence()
    }

    private func playSilence() {
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 44100) else { return }
        buffer.frameLength = 44100                      // all zeros = silence
        if !engine.isRunning { try? engine.start() }
        player.stop()
        player.scheduleBuffer(buffer, at: nil, options: .loops)
        player.play()
    }

    /// After a phone call / Siri / alarm took the audio session.
    private func resumeAudio() {
        guard !holds.isEmpty else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        if let p = songPlayer { p.play() } else { playSilence() }
    }

    private func endAudio() {
        player.stop()
        engine.stop()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        if let fading = songPlayer {
            // Let the song fade out instead of cutting off.
            songPlayer = nil
            fading.setVolume(0, fadeDuration: 0.8)
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 900_000_000)
                fading.stop()
                if self?.holds.isEmpty ?? true {
                    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                }
            }
        } else {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    // MARK: Progress banner (only while you're outside AirShare)

    private func tick() {
        guard !holds.isEmpty else { return }
        let installer = NativeInstaller.shared
        let batch = NativeBatchInstaller.shared
        let working = installer.isActive || batch.isRunning || AppAutoUpdater.shared.busy
            || DeviceInstallationManager.shared.pendingOperations > 0

        // Safety net: if nothing is happening for two minutes, never keep the audio session alive for nothing.
        if working { idleSince = nil }
        else if let t = idleSince, Date().timeIntervalSince(t) > 120 { teardown(announceFinish: false); return }
        else if idleSince == nil { idleSince = Date() }

        guard UIApplication.shared.applicationState != .active else { lastPercent = -1; return }

        let title: String, percent: Int, body: String
        if batch.isRunning {
            title = "Installing \(batch.items.count) App\(batch.items.count == 1 ? "" : "s")"
            percent = Int((batch.fraction * 100).rounded())
            let current = batch.items.first { $0.status == .installing }?.entry.name
            body = current.map { "\(percent)% · \($0)" } ?? "\(percent)%"
        } else if installer.isActive, let job = installer.job {
            title = "Installing \(job.name)"
            percent = Int((min(max(installer.progress, 0), 1) * 100).rounded())
            body = "\(percent)% · \(installer.stage.label.replacingOccurrences(of: "…", with: ""))"
        } else { return }

        guard percent != lastPercent || body != lastBody else { return }
        lastPercent = percent; lastBody = body
        post(id: Self.bannerID, title: title, body: body, quiet: true)
    }

    private func post(id: String, title: String, body: String, quiet: Bool) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        if quiet {
            if #available(iOS 15.0, *) { c.interruptionLevel = .passive }
        } else {
            c.sound = .default
        }
        let request = UNNotificationRequest(identifier: id, content: c, trigger: nil)
        Task { try? await UNUserNotificationCenter.current().add(request) }
    }
}
