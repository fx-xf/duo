import SwiftUI

// The visual language here — a ring open at the bottom, three-band Wi-Fi, four
// volume dots in the gap, the charging bolt — follows DuoBar by Mikeli7666
// (MIT), split out of one menu bar glyph into separate widgets.

/// What a widget shows. Plain values, so the live shelf and the settings
/// preview draw exactly the same thing.
enum WidgetFace: Equatable {
    case battery(BatteryState)
    case volume(level: Double, muted: Bool)
    case headphones(HeadphoneKind, battery: Double?)
    case network(NetworkState)
}

enum WidgetKind: String, CaseIterable, Hashable, Sendable {
    case battery, volume, headphones, network
}

// MARK: - Bubble

/// One widget: the glyph on a disc of the same glass the Dock is made of.
struct WidgetBubble: View {
    let face: WidgetFace
    let size: CGFloat

    var body: some View {
        DuoGlyph(face: face)
            .frame(width: size * 0.68, height: size * 0.68)
            .frame(width: size, height: size)
            .modifier(GlassDisc())
    }
}

private struct GlassDisc: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: Circle())
        } else {
            content
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
        }
    }
}

// MARK: - Glyph

struct DuoGlyph: View {
    let face: WidgetFace

    var body: some View {
        GeometryReader { geometry in
            let d = min(geometry.size.width, geometry.size.height)
            ZStack {
                DuoRing(progress: ringProgress, color: ringColor, lineWidth: d * 0.085, showsFill: showsFill)
                center(d)
                    .id(centerKey)
                    .transition(.opacity.combined(with: .scale(scale: 0.86)))
                gapContent(d)
            }
            .frame(width: d, height: d)
            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }
        .animation(.spring(response: 0.42, dampingFraction: 0.86), value: face)
    }

    // MARK: ring

    private var ringProgress: Double {
        switch face {
        case .battery(let battery): return battery.level
        case .volume(let level, let muted): return muted ? 0 : level
        case .headphones(_, let battery): return battery ?? 1
        case .network(let state):
            switch state {
            case .wifi(let bars): return Double(bars) / 3
            case .ethernet, .other: return 1
            case .offline: return 0
            }
        }
    }

    private var showsFill: Bool {
        if case .headphones(_, nil) = face { return false }
        return true
    }

    private var ringColor: Color {
        switch face {
        case .battery(let battery):
            if battery.isCharging || (battery.isPluggedIn && battery.level >= 0.99) { return Color(nsColor: .systemGreen) }
            if battery.isLowPower { return Color(nsColor: .systemYellow) }
            if battery.isLow { return Color(nsColor: .systemRed) }
            return .primary
        case .network(.offline):
            return Color(nsColor: .systemOrange)
        default:
            return .primary
        }
    }

    // MARK: centre

    private var centerKey: String {
        switch face {
        case .battery: return "battery"
        case .volume(_, let muted): return muted ? "muted" : "volume"
        case .headphones(let kind, _): return kind.symbol
        case .network(let state):
            switch state {
            case .wifi: return "wifi"
            case .ethernet: return "ethernet"
            case .other: return "other"
            case .offline: return "offline"
            }
        }
    }

    @ViewBuilder
    private func center(_ d: CGFloat) -> some View {
        switch face {
        case .battery(let battery):
            Text("\(Int((battery.level * 100).rounded()))")
                .font(.system(size: d * 0.3, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .foregroundStyle(.primary)
                .offset(y: -d * 0.03)
        case .volume(_, let muted):
            symbol(muted ? "speaker.slash.fill" : "speaker.wave.2.fill", d * 0.27)
                .offset(y: -d * 0.05)
        case .headphones(let kind, _):
            symbol(kind.symbol, d * 0.33)
                .offset(y: -d * 0.03)
        case .network(let state):
            switch state {
            case .wifi(let bars):
                DuoWiFiGlyph(bars: bars)
                    .frame(width: d * 0.44, height: d * 0.32)
                    .offset(y: -d * 0.04)
            case .ethernet:
                symbol("cable.connector.horizontal", d * 0.28)
            case .other:
                symbol("network", d * 0.3)
            case .offline:
                symbol("wifi.slash", d * 0.3)
                    .foregroundStyle(Color(nsColor: .systemOrange))
            }
        }
    }

    private func symbol(_ name: String, _ size: CGFloat) -> some View {
        Image(systemName: name)
            .font(.system(size: size, weight: .semibold))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(.primary)
    }

    // MARK: the gap at the bottom of the ring

    @ViewBuilder
    private func gapContent(_ d: CGFloat) -> some View {
        switch face {
        case .battery(let battery):
            Image(systemName: "bolt.fill")
                .font(.system(size: d * 0.17, weight: .bold))
                .foregroundStyle(Color(nsColor: .systemGreen))
                .scaleEffect(battery.isCharging ? 1 : 0.3)
                .opacity(battery.isCharging ? 1 : 0)
                .offset(y: d * 0.33)
                .animation(.easeOut(duration: 0.43), value: battery.isCharging)
        case .volume(let level, let muted):
            DuoDots(active: muted ? 0 : Int((level * 4).rounded(.up)), d: d)
        case .headphones(_, let battery):
            if let battery {
                Text("\(Int((battery * 100).rounded()))")
                    .font(.system(size: d * 0.13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .offset(y: d * 0.34)
            }
        case .network:
            EmptyView()
        }
    }
}

// MARK: - Ring

/// 240° of arc, open at the bottom; the fill runs from the lower left, over the
/// top, towards the lower right.
struct DuoRing: View {
    var progress: Double
    var color: Color
    var lineWidth: CGFloat
    var showsFill = true

    var body: some View {
        ZStack {
            DuoArc(progress: 1)
                .stroke(color.opacity(0.22), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            if showsFill {
                DuoArc(progress: progress)
                    .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            }
        }
        .padding(lineWidth / 2)
    }
}

struct DuoArc: Shape {
    var progress: Double

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let clamped = min(max(progress, 0), 1)
        guard clamped > 0.001 else { return Path() }
        var path = Path()
        path.addArc(center: CGPoint(x: rect.midX, y: rect.midY),
                    radius: min(rect.width, rect.height) / 2,
                    startAngle: .degrees(150),
                    endAngle: .degrees(150 + 240 * clamped),
                    clockwise: false)
        return path
    }
}

// MARK: - Volume dots

/// Four dots in a slight smile across the ring's gap; lit ones are the volume.
struct DuoDots: View {
    let active: Int
    let d: CGFloat

    private static let xs: [CGFloat] = [-55.25, -19.5, 19.5, 55.25].map { $0 / 230 }
    private static let ys: [CGFloat] = [-6.5, 6.5, 6.5, -6.5].map { $0 / 230 }

    var body: some View {
        ZStack {
            ForEach(0..<4, id: \.self) { index in
                Circle()
                    .fill(.primary)
                    .frame(width: d * 0.094, height: d * 0.094)
                    .opacity(index < active ? 1 : 0.3)
                    .offset(x: d * Self.xs[index], y: d * (0.3 + Self.ys[index]))
            }
        }
        .animation(.easeOut(duration: 0.18), value: active)
    }
}

// MARK: - Wi-Fi

/// Three bands — core, middle, outer — lit from the core out by signal.
struct DuoWiFiGlyph: View {
    let bars: Int

    var body: some View {
        GeometryReader { geometry in
            let line = geometry.size.width * 0.145
            ZStack {
                WiFiBand(kind: .outer)
                    .stroke(style: StrokeStyle(lineWidth: line, lineCap: .round, lineJoin: .round))
                    .opacity(bars >= 3 ? 1 : 0.3)
                WiFiBand(kind: .middle)
                    .stroke(style: StrokeStyle(lineWidth: line, lineCap: .round, lineJoin: .round))
                    .opacity(bars >= 2 ? 1 : 0.3)
                WiFiCore()
                    .fill()
                    .opacity(bars >= 1 ? 1 : 0.3)
            }
            .foregroundStyle(.primary)
        }
        .animation(.easeOut(duration: 0.2), value: bars)
    }
}

private struct WiFiBand: Shape {
    enum Kind { case outer, middle }
    let kind: Kind

    func path(in rect: CGRect) -> Path {
        var path = Path()
        switch kind {
        case .outer:
            path.move(to: CGPoint(x: rect.width * 0.075, y: rect.height * 0.321918))
            path.addQuadCurve(to: CGPoint(x: rect.width * 0.915, y: rect.height * 0.321918),
                              control: CGPoint(x: rect.width * 0.495, y: rect.height * -0.130137))
        case .middle:
            path.move(to: CGPoint(x: rect.width * 0.25, y: rect.height * 0.568493))
            path.addQuadCurve(to: CGPoint(x: rect.width * 0.74, y: rect.height * 0.568493),
                              control: CGPoint(x: rect.width * 0.495, y: rect.height * 0.321918))
        }
        return path
    }
}

private struct WiFiCore: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.width * 0.365, y: rect.height * 0.815068))
        path.addQuadCurve(to: CGPoint(x: rect.width * 0.635, y: rect.height * 0.815068),
                          control: CGPoint(x: rect.width * 0.5, y: rect.height * 0.650685))
        path.addCurve(to: CGPoint(x: rect.width * 0.5, y: rect.height * 0.993151),
                      control1: CGPoint(x: rect.width * 0.635, y: rect.height * 0.883562),
                      control2: CGPoint(x: rect.width * 0.555, y: rect.height * 0.993151))
        path.addCurve(to: CGPoint(x: rect.width * 0.365, y: rect.height * 0.815068),
                      control1: CGPoint(x: rect.width * 0.445, y: rect.height * 0.993151),
                      control2: CGPoint(x: rect.width * 0.365, y: rect.height * 0.883562))
        return path
    }
}
