//
//  ThemeKit.swift
//  Live theme state (accent · appearance · background), the palette dropdown
//  shown from the top bar, and the particle-network background.
//

import SwiftUI

// MARK: - State

enum ThemeBackground: String, CaseIterable, Identifiable {
    case particles, grid, none
    var id: String { rawValue }
    var title: String {
        switch self { case .particles: return "Particles"; case .grid: return "Grid"; case .none: return "Plain" }
    }
    var icon: String {
        switch self { case .particles: return "sparkles"; case .grid: return "square.grid.3x3"; case .none: return "rectangle" }
    }
}

@MainActor
final class AppTheme: ObservableObject {
    static let shared = AppTheme()
    private let d = UserDefaults.standard

    /// Bumped on every change; RootView re-ids the tab content so every view re-reads Theme.*.
    @Published private(set) var revision = 0
    @Published var panelShown = false

    @Published var accentHex: String { didSet { d.set(accentHex, forKey: Theme.keyAccent); bump() } }
    @Published var isDark: Bool { didSet { d.set(isDark, forKey: Theme.keyDark); bump() } }
    @Published var background: ThemeBackground { didSet { d.set(background.rawValue, forKey: Theme.keyBackground); bump() } }

    private init() {
        accentHex  = Theme.accentHex
        isDark     = Theme.isDark
        background = ThemeBackground(rawValue: d.string(forKey: Theme.keyBackground) ?? "") ?? .particles
    }
    private func bump() { revision &+= 1 }

    var accent: Color { Color(hex: accentHex) }
    var colorScheme: ColorScheme { isDark ? .dark : .light }

    static let presets: [String] = ["FF9A1F", "2ED9C3", "FFA773", "64CCFF", "B366FF", "FF66B2", "90EE90", "FFCC00", "FF453A", "FFFFFF"]
}

// MARK: - Palette button (top bar)

struct ThemePaletteButton: View {
    @ObservedObject private var theme = AppTheme.shared
    var body: some View {
        Button {
            UISelectionFeedbackGenerator().selectionChanged()
            theme.panelShown.toggle()
        } label: {
            Image(systemName: "paintpalette.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Theme")
    }
}

// MARK: - Dropdown panel (compact)

struct ThemePanel: View {
    @ObservedObject private var theme = AppTheme.shared
    @State private var wheelShown = false
    @State private var hexText = ""
    @State private var hue: Double = 0
    @State private var sat: Double = 1
    @State private var bri: Double = 1
    @FocusState private var hexFocus: Bool
    @State private var lastLive = Date.distantPast

    private var draft: Color { Color(hue: hue, saturation: sat, brightness: bri) }

    var body: some View {
        VStack(spacing: 8) {
            // Square color box · hex input · chevron
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(wheelShown ? draft : theme.accent)
                    .frame(width: 30, height: 30)
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.white.opacity(0.35), lineWidth: 1))
                HStack(spacing: 2) {
                    Text("#").font(.system(size: 14, weight: .bold, design: .monospaced)).foregroundStyle(Theme.subtle)
                    TextField("FF9A1F", text: $hexText)
                        .font(.system(size: 14, weight: .bold, design: .monospaced)).foregroundStyle(Theme.text)
                        .textInputAutocapitalization(.characters).autocorrectionDisabled()
                        .focused($hexFocus).submitLabel(.done)
                        .onSubmit { commitHex() }
                        .onChange(of: hexText) { v in
                            let c = String(v.uppercased().filter { $0.isHexDigit }.prefix(6))
                            if c != v { hexText = c }
                        }
                }
                .padding(.horizontal, 8).frame(height: 30)
                .background(Color.white.opacity(0.07)).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                Button {
                    hexFocus = false
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { wheelShown.toggle() }
                } label: {
                    Image(systemName: "chevron.down").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.accent)
                        .rotationEffect(.degrees(wheelShown ? 180 : 0)).frame(width: 28, height: 30)
                }
                .buttonStyle(.plain)
            }

            if wheelShown {
                VStack(spacing: 10) {
                    HueWheel(hue: $hue, sat: $sat, bri: bri, onChange: { commitLive() }, onEnd: { commitDraft() })
                        .frame(width: 150, height: 150)
                    HStack(spacing: 8) {
                        Image(systemName: "sun.min").font(.system(size: 11)).foregroundStyle(Theme.subtle)
                        Slider(value: $bri, in: 0.15...1) { editing in if !editing { commitDraft() } }.tint(Theme.accent)
                            .onChange(of: bri) { _ in commitLive() }
                        Image(systemName: "sun.max.fill").font(.system(size: 11)).foregroundStyle(Theme.subtle)
                    }
                    HStack(spacing: 7) {
                        ForEach(AppTheme.presets.prefix(8), id: \.self) { hex in
                            Button { theme.accentHex = hex; sync() } label: {
                                Circle().fill(Color(hex: hex)).frame(width: 16, height: 16)
                                    .overlay(Circle().stroke(Color.white.opacity(theme.accentHex.uppercased() == hex ? 0.95 : 0.15), lineWidth: 1.5))
                            }.buttonStyle(.plain)
                        }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Divider().overlay(Theme.stroke)

            // Dynamic backgrounds dropdown
            Menu {
                ForEach(ThemeBackground.allCases) { b in
                    Button { theme.background = b } label: {
                        Label(b.title, systemImage: b == theme.background ? "checkmark" : b.icon)
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: theme.background.icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.accent).frame(width: 18)
                    Text("Background").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.subtle)
                    Spacer(minLength: 4)
                    Text(theme.background.title).font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.text)
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.subtle)
                }
                .padding(.horizontal, 6).frame(height: 28).contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Light / dark
            HStack(spacing: 8) {
                Image(systemName: theme.isDark ? "moon.fill" : "sun.max.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.accent).frame(width: 18)
                Text(theme.isDark ? "Dark" : "Light").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.subtle)
                Spacer()
                Toggle("", isOn: $theme.isDark).labelsHidden().tint(Theme.accent).scaleEffect(0.8)
            }
            .padding(.horizontal, 6).frame(height: 26)
        }
        .padding(12)
        .frame(width: 230)
        .background(Theme.bg)
        .onAppear { sync() }
    }

    private func sync() {
        hexText = theme.accentHex.uppercased()
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(Color(hex: theme.accentHex)).getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        hue = Double(h); sat = Double(s); bri = Double(b)
    }

    private func commitHex() {
        hexFocus = false
        let c = hexText.uppercased()
        guard c.count == 6 || c.count == 3 else { hexText = theme.accentHex.uppercased(); return }
        let full = c.count == 3 ? c.map { "\($0)\($0)" }.joined() : c
        theme.accentHex = full
        sync()
    }

    /// Live update while dragging (throttled to ~20/s so the re-skin stays smooth).
    private func commitLive() {
        let now = Date()
        guard now.timeIntervalSince(lastLive) > 0.05 else { return }
        lastLive = now
        commitDraft()
    }

    private func commitDraft() {
        if let h = draft.hexString() {
            theme.accentHex = h.replacingOccurrences(of: "#", with: "").uppercased()
            hexText = theme.accentHex
        }
    }
}

/// Hue (angle) / saturation (radius) wheel. Updates the accent live while dragging.
private struct HueWheel: View {
    @Binding var hue: Double
    @Binding var sat: Double
    let bri: Double
    let onChange: () -> Void
    let onEnd: () -> Void

    var body: some View {
        GeometryReader { g in
            let d = Swift.min(g.size.width, g.size.height), r = d / 2
            ZStack {
                Circle().fill(AngularGradient(gradient: Gradient(colors: (0...12).map { Color(hue: Double($0) / 12, saturation: 1, brightness: 1) }), center: .center))
                Circle().fill(RadialGradient(colors: [.white, .white.opacity(0)], center: .center, startRadius: 0, endRadius: r))
                Circle().fill(Color.black.opacity(1 - bri))
                Circle().fill(Color(hue: hue, saturation: sat, brightness: bri)).frame(width: 18, height: 18)
                    .overlay(Circle().stroke(Color.white, lineWidth: 2))
                    .shadow(color: .black.opacity(0.4), radius: 2)
                    .position(x: r + CGFloat(sat) * r * CGFloat(cos(hue * 2 * .pi)),
                              y: r + CGFloat(sat) * r * CGFloat(sin(hue * 2 * .pi)))
            }
            .frame(width: d, height: d)
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    let dx = v.location.x - r, dy = v.location.y - r
                    var a = atan2(dy, dx) / (2 * .pi); if a < 0 { a += 1 }
                    hue = Double(a)
                    sat = Double(Swift.min(sqrt(dx * dx + dy * dy) / r, 1))
                    onChange()
                }
                .onEnded { _ in onEnd() })
        }
    }
}

// MARK: - Backgrounds

/// Drifting node network (AirShare look) tinted with the accent. Non-interactive.
struct ParticleBackground: View {
    var accent: Color = Theme.accent
    var count: Int = 44
    var linkDistance: CGFloat = 120

    /// Reference box so the Canvas closure can advance the simulation without state churn.
    private final class Sim {
        struct Node { var x: CGFloat; var y: CGFloat; var vx: CGFloat; var vy: CGFloat }
        var nodes: [Node] = []
        var last: Date = .now

        func step(to date: Date, in size: CGSize, count: Int) -> [Node] {
            if nodes.count != count {
                nodes = (0..<count).map { _ in
                    Node(x: .random(in: 0...max(size.width, 1)), y: .random(in: 0...max(size.height, 1)),
                         vx: .random(in: -14...14), vy: .random(in: -14...14))
                }
            }
            let dt = CGFloat(min(max(date.timeIntervalSince(last), 0), 0.1))
            last = date
            for i in nodes.indices {
                nodes[i].x += nodes[i].vx * dt; nodes[i].y += nodes[i].vy * dt
                if nodes[i].x < 0 || nodes[i].x > size.width  { nodes[i].vx.negate(); nodes[i].x = min(max(nodes[i].x, 0), size.width) }
                if nodes[i].y < 0 || nodes[i].y > size.height { nodes[i].vy.negate(); nodes[i].y = min(max(nodes[i].y, 0), size.height) }
            }
            return nodes
        }
    }
    @State private var sim = Sim()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { tl in
            Canvas { ctx, size in
                let ns = sim.step(to: tl.date, in: size, count: count)
                var lines = Path()
                for i in 0..<ns.count {
                    for j in (i + 1)..<ns.count {
                        let dx = ns[i].x - ns[j].x, dy = ns[i].y - ns[j].y
                        let dist = sqrt(dx * dx + dy * dy)
                        guard dist < linkDistance else { continue }
                        lines.move(to: CGPoint(x: ns[i].x, y: ns[i].y))
                        lines.addLine(to: CGPoint(x: ns[j].x, y: ns[j].y))
                    }
                }
                ctx.stroke(lines, with: .color(accent.opacity(0.22)), lineWidth: 0.6)
                for n in ns {
                    let r: CGFloat = 2.2
                    ctx.fill(Path(ellipseIn: CGRect(x: n.x - r, y: n.y - r, width: r * 2, height: r * 2)), with: .color(accent.opacity(0.85)))
                }
            }
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }
}

/// Static hairline grid.
struct GridBackground: View {
    var accent: Color = Theme.accent
    var body: some View {
        Canvas { ctx, size in
            var p = Path()
            let step: CGFloat = 28
            var x: CGFloat = 0; while x <= size.width { p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height)); x += step }
            var y: CGFloat = 0; while y <= size.height { p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y)); y += step }
            ctx.stroke(p, with: .color(accent.opacity(0.07)), lineWidth: 0.5)
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }
}

/// Picks the configured background overlay.
struct ThemeBackgroundLayer: View {
    @ObservedObject private var theme = AppTheme.shared
    var body: some View {
        switch theme.background {
        case .particles: ParticleBackground(accent: theme.accent)
        case .grid:      GridBackground(accent: theme.accent)
        case .none:      EmptyView()
        }
    }
}
