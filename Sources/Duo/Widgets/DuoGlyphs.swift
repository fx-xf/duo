import SwiftUI

// The glyph is DuoBar's, by Mike Li (MIT): the same ring, open at the bottom
// for four volume dots, the same three-band Wi-Fi, the same bolt, drawn from the
// same measurements. Every number below is in DuoBar's 32 pt canvas and scaled
// from there, so the proportions stay exactly its own at any size.

/// What a widget shows. Plain values, so the live shelf and the settings
/// preview draw exactly the same thing.
enum WidgetFace: Equatable {
    /// The Duo glyph proper: the Mac's battery on the ring, the network in the
    /// middle, the volume on the dots.
    case duo(battery: BatteryState?, network: NetworkState, volume: Double, muted: Bool)
    /// A headset: its battery on the ring, the buds in the middle, volume below.
    case headphones(HeadphoneKind, battery: Double?, volume: Double, muted: Bool)
}

enum WidgetKind: String, CaseIterable, Hashable, Sendable {
    case duo, headphones
}

// MARK: - Bubble

/// One widget: the glyph on a disc of the Dock's own glass.
struct WidgetBubble: View {
    let face: WidgetFace
    let size: CGFloat

    var body: some View {
        DuoGlyph(face: face, canvas: size * 0.8)
            .frame(width: size, height: size)
            .modifier(SystemGlass(shape: Circle()))
    }
}

/// The glass the Dock is made of: the standard system glass, left untinted, so
/// it follows the Liquid Glass choice in System Settings exactly as the Dock
/// does, and the glyph on it takes the system's light or dark appearance.
struct SystemGlass<S: Shape>: ViewModifier {
    let shape: S

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content.background(.ultraThinMaterial, in: shape)
        }
    }
}

// MARK: - Glyph

private enum Duo {
    static let canvas: CGFloat = 32
    static let ringDiameter: CGFloat = 26.5
    static let lineWidth: CGFloat = ringDiameter * 18 / 230
    static let pathDiameter: CGFloat = ringDiameter - lineWidth
    static let ringYOffset: CGFloat = -0.8
    static let centerYOffset: CGFloat = -1.25
    static let symbolSize: CGFloat = 12.4
    static let boltSize: CGFloat = ringDiameter * (50 / 1.16) / 230
    static let boltPoint = CGPoint(x: -ringDiameter * 3 / 230,
                                   y: -(pathDiameter / 2 - ringDiameter * 24 / 230) + ringYOffset)
    static let wifiSize = CGSize(width: ringDiameter * 100 / 230, height: ringDiameter * 73 / 230)
    static let wifiYOffset: CGFloat = ringYOffset + ringDiameter * (-15 / 230) - centerYOffset
    static let dotDiameter: CGFloat = ringDiameter * 21.5 / 230
    static let dotRowY: CGFloat = 7.495652174
    static let dotX: [CGFloat] = [-55.25, -19.5, 19.5, 55.25].map { ringDiameter * $0 / 230 }
    static let dotY: [CGFloat] = [-6.5, 6.5, 6.5, -6.5].map { ringDiameter * $0 / 230 }
    static let inactive = 0.28
    static let chargingTrack = 0.24
}

struct DuoGlyph: View {
    let face: WidgetFace
    /// Side of the square the 32 pt canvas is scaled into.
    let canvas: CGFloat

    private var u: CGFloat { canvas / Duo.canvas }

    var body: some View {
        ZStack {
            ring
            bolt
            center
                .id(centerKey)
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
                .offset(y: Duo.centerYOffset * u)
            dots
        }
        .frame(width: canvas, height: canvas)
        .animation(.easeInOut(duration: 0.25), value: centerKey)
        .animation(.easeOut(duration: 0.18), value: face)
    }

    // MARK: ring

    private var ring: some View {
        let style = StrokeStyle(lineWidth: Duo.lineWidth * u, lineCap: .round, lineJoin: .round)
        return ZStack {
            DuoArc(progress: 1)
                .stroke(ringColor, style: style)
                .opacity(trackOpacity)
            DuoArc(progress: ringProgress)
                .stroke(ringColor, style: style)
                .opacity(fillOpacity)
        }
        .frame(width: Duo.pathDiameter * u, height: Duo.pathDiameter * u)
        .offset(y: Duo.ringYOffset * u)
        .animation(.easeOut(duration: 0.32), value: ringColorKey)
    }

    private var ringProgress: Double {
        switch face {
        case .duo(let battery, _, _, _): return battery?.level ?? 1
        case .headphones(_, let battery, _, _): return battery ?? 1
        }
    }

    private var charging: Bool {
        if case .duo(let battery?, _, _, _) = face { return battery.isCharging }
        return false
    }

    /// The unfilled part only ever shows while charging — and, faintly, for a
    /// headset that keeps its battery to itself.
    private var trackOpacity: Double {
        switch face {
        case .duo: return charging ? Duo.chargingTrack : 0
        case .headphones(_, let battery, _, _): return battery == nil ? Duo.inactive : 0
        }
    }

    private var fillOpacity: Double {
        switch face {
        case .duo(let battery, _, _, _): return battery == nil ? Duo.inactive : 1
        case .headphones(_, let battery, _, _): return battery == nil ? 0 : 1
        }
    }

    private var ringColorKey: Int {
        guard case .duo(let battery?, _, _, _) = face else { return 0 }
        if battery.isCharging { return 1 }
        if battery.isLowPower { return 2 }
        if battery.isLow { return 3 }
        return 0
    }

    private var ringColor: Color {
        switch ringColorKey {
        case 1: return Color(nsColor: .systemGreen)
        case 2: return Color(nsColor: .systemYellow)
        case 3: return Color(nsColor: .systemRed)
        default: return .primary
        }
    }

    // MARK: bolt, in the top of the ring

    private var bolt: some View {
        Image(systemName: "bolt.fill")
            .font(.system(size: Duo.boltSize * u, weight: .bold))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(.primary)
            .offset(x: Duo.boltPoint.x * u, y: Duo.boltPoint.y * u)
            .scaleEffect(charging ? 1 : 0.01, anchor: .center)
            .opacity(charging ? 1 : 0)
            .animation(.timingCurve(0.33, 1, 0.68, 1, duration: 0.43), value: charging)
    }

    // MARK: centre

    private var centerKey: String {
        switch face {
        case .duo(_, let network, _, _):
            switch network {
            case .wifi: return "wifi"
            case .ethernet: return "ethernet"
            case .other: return "other"
            case .offline: return "offline"
            }
        case .headphones(let kind, _, _, _): return kind.symbol
        }
    }

    @ViewBuilder
    private var center: some View {
        switch face {
        case .duo(_, let network, _, _):
            switch network {
            case .wifi(let bars):
                DuoWiFiGlyph(bars: bars, lineWidth: Duo.ringDiameter * 14.5 / 230 * u)
                    .frame(width: Duo.wifiSize.width * u, height: Duo.wifiSize.height * u)
                    .offset(y: Duo.wifiYOffset * u)
            case .ethernet:
                symbol("cable.connector.horizontal", scale: 0.92)
            case .other:
                symbol("ellipsis.circle", scale: 0.92)
            case .offline:
                symbol("network.slash", scale: 1)
            }
        case .headphones(let kind, _, _, _):
            symbol(kind.symbol, scale: 0.92)
                .foregroundStyle(Color.accentColor.opacity(0.86))
        }
    }

    private func symbol(_ name: String, scale: CGFloat) -> some View {
        Image(systemName: name)
            .font(.system(size: Duo.symbolSize * scale * u, weight: .semibold))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(.primary)
    }

    // MARK: volume dots, in the gap

    private var activeDots: Int {
        let (volume, muted): (Double, Bool)
        switch face {
        case .duo(_, _, let v, let m): (volume, muted) = (v, m)
        case .headphones(_, _, let v, let m): (volume, muted) = (v, m)
        }
        guard !muted, volume > 0.001 else { return 0 }
        return min(4, max(1, Int((volume * 4).rounded(.up))))
    }

    private var dots: some View {
        ZStack {
            ForEach(0..<4, id: \.self) { index in
                Circle()
                    .fill(.primary)
                    .frame(width: Duo.dotDiameter * u, height: Duo.dotDiameter * u)
                    .opacity(index < activeDots ? 1 : 0.3)
                    .offset(x: Duo.dotX[index] * u, y: (Duo.dotRowY + Duo.dotY[index]) * u)
            }
        }
        .animation(.easeOut(duration: 0.18), value: activeDots)
    }
}

// MARK: - Ring shape

/// 240° of arc, open at the bottom; the fill runs from the lower left, over the
/// top, towards the lower right.
struct DuoArc: Shape {
    var progress: Double

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let clamped = min(max(progress, 0), 1)
        guard clamped > 0.001 else { return Path() }
        let start = 90 + 120.2 / 2
        let end = 450 - 120.2 / 2
        var path = Path()
        path.addArc(center: CGPoint(x: rect.midX, y: rect.midY),
                    radius: min(rect.width, rect.height) / 2,
                    startAngle: .degrees(start),
                    endAngle: .degrees(start + (end - start) * clamped),
                    clockwise: false)
        return path
    }
}

// MARK: - Wi-Fi

/// Core, middle and outer band, lit from the core out by signal strength.
struct DuoWiFiGlyph: View {
    let bars: Int
    let lineWidth: CGFloat

    var body: some View {
        ZStack {
            WiFiBand(kind: .outer)
                .stroke(style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
                .opacity(bars >= 3 ? 1 : 0.28)
            WiFiBand(kind: .middle)
                .stroke(style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
                .opacity(bars >= 2 ? 1 : 0.28)
            WiFiCore()
                .fill()
                .opacity(bars >= 1 ? 1 : 0.28)
        }
        .foregroundStyle(.primary)
        .animation(.easeOut(duration: 0.18), value: bars)
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
