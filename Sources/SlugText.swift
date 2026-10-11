//
//  SlugText.swift
//  AirShare
//
//  Rich AirShare onboarding adapted from the AVX512 onboarding UI.
//  Identity remains local to AirShare through MDIDManager; no backend
//  registration is required to complete onboarding.
//

import SwiftUI
import UIKit
import AVFoundation
import ImageIO

// MARK: - Onboarding gate

@MainActor
final class Onboarding: ObservableObject {
    static let shared = Onboarding()
    private let key = "uzd_onboarded_v1"
    @Published var needsOnboarding: Bool

    private init() {
        needsOnboarding = !UserDefaults.standard.bool(forKey: key)
    }

    func complete() {
        UserDefaults.standard.set(true, forKey: key)
        needsOnboarding = false
    }
}

// MARK: - Phase

private enum AirShareOnboardingPhase: Equatable {
    case detecting
    case welcome
    case registering
    case success
    case error
}

// MARK: - Main onboarding

struct OnboardingView: View {
    var onDone: () -> Void

    @State private var phase: AirShareOnboardingPhase = .detecting
    @State private var deviceDescription = ""
    @State private var dotPhase = 0
    @State private var dotTimer: Timer?
    @State private var logoScale: CGFloat = 0.80
    @State private var logoOpacity = 0.0
    @State private var featuresOffset: CGFloat = 50
    @State private var featuresOpacity = 0.0
    @State private var buttonScale: CGFloat = 0.90
    @State private var buttonOpacity = 0.0
    @State private var errorMessage = ""
    @State private var confettiPieces: [AirShareConfettiPiece] = []

    private let maxRetries = 3
    @State private var attempts = 0

    private var accent: Color { Theme.accent }
    private var mdid: String { MDID.current }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            Group {
                switch phase {
                case .detecting:
                    detectingScreen
                case .welcome:
                    welcomeScreen
                case .registering:
                    loadingScreen
                case .success:
                    successScreen
                case .error:
                    errorScreen
                }
            }
            .transition(.opacity.combined(with: .scale(scale: 0.97)))
            .animation(.spring(response: 0.5, dampingFraction: 0.82), value: phase)
        }
        .onAppear(perform: startDetection)
        .onDisappear { dotTimer?.invalidate() }
        .preferredColorScheme(AppTheme.shared.colorScheme)
    }

    // MARK: Detecting

    private var detectingScreen: some View {
        VStack(spacing: 30) {
            Spacer()

            ZStack {
                Circle()
                    .fill(accent.opacity(0.10))
                    .frame(width: 116, height: 116)
                Circle()
                    .strokeBorder(accent.opacity(0.28), lineWidth: 1.5)
                    .frame(width: 116, height: 116)
                Image(systemName: "touchid")
                    .font(.system(size: 54, weight: .ultraLight))
                    .foregroundStyle(accent)
            }

            VStack(spacing: 9) {
                Text("Scanning your device")
                    .font(.system(size: 23, weight: .semibold))
                    .foregroundStyle(.white)

                Text(deviceDescription.isEmpty ? "Preparing your local AirShare identity…" : deviceDescription)
                    .font(.system(size: 13))
                    .foregroundStyle(.gray)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }

            HStack(spacing: 7) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(i == dotPhase ? accent : Color.gray.opacity(0.3))
                        .frame(width: 8, height: 8)
                        .scaleEffect(i == dotPhase ? 1.35 : 1)
                        .animation(.easeInOut(duration: 0.3), value: dotPhase)
                }
            }

            Spacer()

            Text("AirShare · MRzefv · DELvEK.net")
                .font(.system(size: 12))
                .foregroundStyle(.gray.opacity(0.55))
                .padding(.bottom, 38)
        }
    }

    // MARK: Welcome

    private var welcomeScreen: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
                Spacer().frame(height: 34)

                brandHeader
                    .padding(.bottom, 28)

                Text("Welcome to AirShare")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)

                Text("Your signing environment lives on this device.")
                    .font(.system(size: 15))
                    .foregroundStyle(.gray)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)
                    .padding(.top, 6)
                    .padding(.bottom, 24)

                deviceInfoCard
                    .padding(.horizontal, 28)
                    .padding(.bottom, 25)

                VStack(spacing: 14) {
                    AirShareAutoRow(icon: "clock.arrow.circlepath", color: .green,
                                 text: "Your local signing history stays on this device")
                    AirShareAutoRow(icon: "bolt.fill", color: .orange,
                                 text: "Fast local ZSign engine — no signing request leaves this device")
                    AirShareAutoRow(icon: "lock.shield.fill", color: .blue,
                                 text: "Certificates remain protected by the existing certificate store")
                }
                .padding(.horizontal, 36)
                .padding(.bottom, 28)

                Button(action: handleGetStarted) {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.right.circle.fill")
                            .font(.system(size: 18))
                        Text("Continue")
                            .font(.system(size: 18, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background(
                        LinearGradient(colors: [accent, accent.opacity(0.78)],
                                       startPoint: .leading,
                                       endPoint: .trailing)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                }
                .scaleEffect(buttonScale)
                .opacity(buttonOpacity)
                .padding(.horizontal, 32)

                VStack(spacing: 4) {
                    Text("No account required to start signing")
                        .font(.system(size: 13))
                        .foregroundStyle(.gray)
                    Text("AirShare · Local ZSign API · AirShare")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(accent.opacity(0.9))
                }
                .padding(.top, 18)
                .padding(.bottom, 34)
            }
        }
    }

    private var brandHeader: some View {
        VStack(spacing: 15) {
            Group {
                if let image = UIImage(named: "airshare_logo") {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else if let image = loadResourceImage("AirShareLogo", ext: "png") {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 36)
                            .fill(accent.opacity(0.15))
                        Image(systemName: "signature")
                            .font(.system(size: 58, weight: .bold))
                            .foregroundStyle(accent)
                    }
                }
            }
            .frame(width: 180, height: 180)
            .clipShape(RoundedRectangle(cornerRadius: 36, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 36, style: .continuous)
                    .strokeBorder(accent.opacity(0.32), lineWidth: 1)
            )
            .shadow(color: accent.opacity(0.35), radius: 24, x: 0, y: 8)
            .scaleEffect(logoScale)
            .opacity(logoOpacity)

            Text("AirShare")
                .font(.system(size: 42, weight: .bold))
                .foregroundStyle(.white)
                .opacity(logoOpacity)

            HStack(spacing: 6) {
                Circle().fill(accent).frame(width: 6, height: 6)
                Text("LOCAL SIGNING READY")
                    .font(.system(size: 10, weight: .heavy, design: .monospaced))
                    .foregroundStyle(accent)
                    .tracking(0.8)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Capsule().fill(accent.opacity(0.12)))
            .overlay(Capsule().stroke(accent.opacity(0.3), lineWidth: 1))
            .opacity(logoOpacity)
        }
    }

    private var deviceInfoCard: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(accent.opacity(0.10))
                    .frame(width: 56, height: 56)
                Image(systemName: "iphone.gen3")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(accent)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(mdid)
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                    .tracking(1.5)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                HStack(spacing: 5) {
                    Circle().fill(.green).frame(width: 6, height: 6)
                    Text("Local identity detected")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.green)
                }

                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 10))
                        .foregroundStyle(.gray.opacity(0.7))
                    Text(deviceDescription)
                        .font(.system(size: 11))
                        .foregroundStyle(.gray)
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(Color.green.opacity(0.20), lineWidth: 1)
                )
        )
    }

    // MARK: Loading

    private var loadingScreen: some View {
        VStack(spacing: 24) {
            ProgressView()
                .scaleEffect(1.5)
                .tint(accent)

            Text("Preparing AirShare…")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))

            Text(mdid)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(accent.opacity(0.9))
                .tracking(2)
        }
    }

    // MARK: Success

    private var successScreen: some View {
        ZStack {
            ForEach(confettiPieces) { piece in
                Circle()
                    .fill(piece.color)
                    .frame(width: 9, height: 9)
                    .scaleEffect(piece.scale)
                    .position(x: piece.x, y: piece.y)
            }

            VStack(spacing: 22) {
                Spacer().frame(height: 24)

                Group {
                    if let animated = AnimatedImage.named("airshare_anim") {
                        animated
                    } else {
                        LoopingVideoPlayer(resource: "airshare_anim", ext: "mp4")
                    }
                }
                .frame(width: 180, height: 176)
                .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 32, style: .continuous)
                        .strokeBorder(accent.opacity(0.3), lineWidth: 1)
                )
                .shadow(color: accent.opacity(0.45), radius: 24, x: 0, y: 8)

                VStack(spacing: 10) {
                    Text(mdid)
                        .font(.system(size: 18, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white)
                        .tracking(2)

                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(accent)
                        Text("Local identity ready")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Color.white.opacity(0.1)))
                }

                Text("You're all set!")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(.white)

                Text("AirShare is ready to sign, package and install apps locally.")
                    .font(.system(size: 13))
                    .foregroundStyle(.gray)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 34)

                Button(action: finish) {
                    Text("Continue to app")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                }
                .padding(.top, 6)

                Spacer(minLength: 0)

                VStack(spacing: 4) {
                    HStack(spacing: 4) {
                        Text("Made by").foregroundStyle(.gray)
                        Text("ᴹᴿ𝐙𝐄𝐅𝐯").foregroundStyle(.white)
                    }
                    .font(.system(size: 13))

                    HStack(spacing: 6) {
                        Text("Powered by").foregroundStyle(.gray)
                        Text("DELvEK.net")
                            .fontWeight(.bold)
                            .foregroundStyle(accent)
                    }
                    .font(.system(size: 12))
                }
                .padding(.bottom, 30)
            }
        }
    }

    // MARK: Error

    private var errorScreen: some View {
        VStack(spacing: 28) {
            Spacer()

            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 72))
                .foregroundStyle(.orange)

            VStack(spacing: 8) {
                Text("Setup Failed")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.white)
                Text(errorMessage)
                    .font(.system(size: 15))
                    .foregroundStyle(.gray)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            if attempts < maxRetries {
                Button(action: startDetection) {
                    Text("Retry (\(attempts)/\(maxRetries))")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 200, height: 56)
                        .background(RoundedRectangle(cornerRadius: 16).fill(accent))
                }
            } else {
                Button(action: finish) {
                    Text("Continue Anyway")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 200, height: 56)
                        .background(RoundedRectangle(cornerRadius: 16).fill(accent))
                }
            }

            Spacer()
        }
    }

    // MARK: Actions

    private func startDetection() {
        attempts += 1
        dotTimer?.invalidate()
        dotTimer = Timer.scheduledTimer(withTimeInterval: 0.42, repeats: true) { _ in
            dotPhase = (dotPhase + 1) % 3
        }

        let device = UIDevice.current
        let bounds = UIScreen.main.nativeBounds
        deviceDescription = "\(device.model) · iOS \(device.systemVersion) · \(Int(bounds.width))×\(Int(bounds.height))"

        // The ADID is already created/persisted locally by MDIDManager.
        _ = MDID.current

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.15) {
            dotTimer?.invalidate()
            withAnimation { phase = .welcome }
            animateWelcome()
        }
    }

    private func animateWelcome() {
        withAnimation(.spring(response: 0.8, dampingFraction: 0.7).delay(0.05)) {
            logoScale = 1
            logoOpacity = 1
        }
        withAnimation(.spring(response: 0.8, dampingFraction: 0.8).delay(0.25)) {
            featuresOffset = 0
            featuresOpacity = 1
        }
        withAnimation(.spring(response: 0.6, dampingFraction: 0.7).delay(0.5)) {
            buttonScale = 1
            buttonOpacity = 1
        }
    }

    private func handleGetStarted() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        withAnimation { phase = .registering }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            completeSetup()
        }
    }

    private func completeSetup() {
        guard !mdid.isEmpty else {
            errorMessage = "AirShare could not create a local device identity."
            withAnimation { phase = .error }
            return
        }

        withAnimation { phase = .success }
        generateConfetti()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
        onDone()
    }

    private func generateConfetti() {
        let colors: [Color] = [.red, .orange, .yellow, .green, .blue, .purple, .pink]
        let w = UIScreen.main.bounds.width
        let h = UIScreen.main.bounds.height
        confettiPieces = (0..<52).map { _ in
            AirShareConfettiPiece(
                x: .random(in: 0...w),
                y: -50,
                color: colors.randomElement() ?? accent,
                scale: .random(in: 0.5...1.3)
            )
        }
        for i in confettiPieces.indices {
            withAnimation(.easeIn(duration: .random(in: 1.8...3.5))) {
                confettiPieces[i].y = h + 100
            }
        }
    }

    private func loadResourceImage(_ name: String, ext: String) -> UIImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext),
              let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }
}

// MARK: - Supporting rows

private struct AirShareAutoRow: View {
    let icon: String
    let color: Color
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 28)
            Text(text)
                .font(.system(size: 14))
                .foregroundStyle(.gray)
            Spacer()
        }
    }
}

private struct AirShareConfettiPiece: Identifiable {
    let id = UUID()
    var x: CGFloat
    var y: CGFloat
    let color: Color
    let scale: CGFloat
}

// MARK: - Looping animation

struct LoopingVideoPlayer: UIViewRepresentable {
    let resource: String
    let ext: String
    var muted: Bool = true

    func makeUIView(context: Context) -> UIView {
        let view = AirShareLoopingPlayerView()
        view.configure(resource: resource, ext: ext, muted: muted)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

private final class AirShareLoopingPlayerView: UIView {
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private let playerLayer = AVPlayerLayer()

    func configure(resource: String, ext: String, muted: Bool) {
        guard let url = Bundle.main.url(forResource: resource, withExtension: ext) else { return }
        let item = AVPlayerItem(url: url)
        let queue = AVQueuePlayer()
        let looper = AVPlayerLooper(player: queue, templateItem: item)
        queue.isMuted = muted
        queue.actionAtItemEnd = .none
        playerLayer.player = queue
        playerLayer.videoGravity = .resizeAspectFill
        layer.addSublayer(playerLayer)
        backgroundColor = .clear
        player = queue
        self.looper = looper
        queue.play()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        playerLayer.frame = bounds
    }
}

// MARK: - Lightweight GIF renderer

struct AnimatedImage: UIViewRepresentable {
    let frames: [UIImage]
    let duration: TimeInterval

    static func named(_ name: String) -> AnimatedImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "gif"),
              let data = try? Data(contentsOf: url),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }

        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return nil }

        var images: [UIImage] = []
        var total: TimeInterval = 0
        images.reserveCapacity(count)

        for i in 0..<count {
            guard let cg = CGImageSourceCreateImageAtIndex(source, i, nil) else { continue }
            images.append(UIImage(cgImage: cg))
            let props = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any]
            let gif = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
                ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double)
                ?? 0.08
            total += max(delay, 0.02)
        }

        guard !images.isEmpty else { return nil }
        return AnimatedImage(frames: images, duration: total)
    }

    func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView()
        view.contentMode = .scaleAspectFill
        view.animationImages = frames
        view.animationDuration = duration
        view.image = frames.first
        view.startAnimating()
        return view
    }

    func updateUIView(_ uiView: UIImageView, context: Context) {}
}
