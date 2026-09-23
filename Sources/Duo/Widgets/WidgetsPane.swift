import SwiftUI

struct WidgetsPane: View {
    @ObservedObject var prefs: Preferences
    @ObservedObject var shelf: WidgetShelf

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Widgets")
                    .font(.system(size: 15, weight: .semibold))

                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Show system widgets beside the Dock",
                               isOn: $prefs.widgetsEnabled.animation(.spring(response: 0.42, dampingFraction: 0.9)))
                            .toggleStyle(.switch)
                        Text("They sit either side of the Dock — above and below it when it stands on its side — match its size, and bud out of it the way the iPhone Duo's do.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .padding(6)
                }

                if prefs.widgetsEnabled {
                    WidgetPreview()
                        .frame(height: 150)
                        .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))

                    GroupBox {
                        VStack(alignment: .leading, spacing: 9) {
                            rule("circle.dashed", "Duo", "Always. The battery on the ring — green while charging, yellow in Low Power Mode, red when low — the network in the middle, the volume on the four dots.")
                            Divider()
                            rule("airpodspro", "Headphones", "While a Bluetooth headset is the output: its battery on the ring, the buds in blue.")
                        }
                        .padding(6)
                    }
                    .transition(.opacity)

                    GroupBox {
                        HStack(spacing: 10) {
                            Image(systemName: shelf.dockIsExact ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                                .foregroundStyle(shelf.dockIsExact ? Color.green : Color.orange)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Lined up with the Dock")
                                    .font(.system(size: 12))
                                Text(shelf.dockIsExact
                                     ? "Measured exactly, through Accessibility."
                                     : "Estimated from the icons in the Dock. Allow Accessibility for an exact fit.")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if !shelf.dockIsExact {
                                Button("Allow…") { DockProbe.requestTrust() }
                            }
                        }
                        .padding(6)
                    }
                    .transition(.opacity)
                }
            }
            .padding(24)
        }
    }

    private func rule(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .frame(width: 20)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Preview

/// A small desktop with a Dock, running the widgets through their paces with
/// the very views the real shelf uses.
struct WidgetPreview: View {
    @State private var step = 0
    private let clock = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    private static let bubble: CGFloat = 38
    private static let gap: CGFloat = 6

    var body: some View {
        let frame = Self.script[step]
        ZStack(alignment: .bottom) {
            LinearGradient(colors: [Color(red: 0.13, green: 0.16, blue: 0.36),
                                    Color(red: 0.45, green: 0.3, blue: 0.55),
                                    Color(red: 0.93, green: 0.6, blue: 0.45)],
                           startPoint: .top, endPoint: .bottom)

            HStack(spacing: Self.gap + 2) {
                WidgetStack(items: frame.leading, size: Self.bubble, gap: Self.gap, towardDock: .trailing)
                    .frame(width: Self.bubble * 2 + Self.gap + 16, height: Self.bubble + 16)
                MiniDock(height: Self.bubble)
                WidgetStack(items: frame.trailing, size: Self.bubble, gap: Self.gap, towardDock: .leading)
                    .frame(width: Self.bubble * 2 + Self.gap + 16, height: Self.bubble + 16)
            }
            .padding(.bottom, 6)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.08)))
        .onReceive(clock) { _ in step = (step + 1) % Self.script.count }
    }

    private struct Frame {
        var leading: [WidgetItem]
        var trailing: [WidgetItem]
    }

    private static func duo(_ level: Double, charging: Bool = false,
                            network: NetworkState = .wifi(bars: 3), volume: Double = 0.5) -> WidgetItem {
        WidgetItem(kind: .duo, face: .duo(battery: BatteryState(level: level, isCharging: charging,
                                                                isPluggedIn: charging, isLowPower: false),
                                          network: network, volume: volume, muted: false))
    }

    private static func airPods(volume: Double) -> WidgetItem {
        WidgetItem(kind: .headphones, face: .headphones(.airPodsPro, battery: 0.85, volume: volume, muted: false))
    }

    /// Switched on, a volume nudge, AirPods arriving, the network dropping and
    /// coming back, a charger going in, AirPods leaving — then round again.
    private static let script: [Frame] = [
        Frame(leading: [], trailing: []),
        Frame(leading: [duo(0.62)], trailing: []),
        Frame(leading: [duo(0.62, volume: 0.75)], trailing: []),
        Frame(leading: [duo(0.62, volume: 0.75)], trailing: [airPods(volume: 0.75)]),
        Frame(leading: [duo(0.62, network: .offline, volume: 0.75)], trailing: [airPods(volume: 0.75)]),
        Frame(leading: [duo(0.62, volume: 0.75)], trailing: [airPods(volume: 0.75)]),
        Frame(leading: [duo(0.63, charging: true, volume: 0.75)], trailing: [airPods(volume: 0.75)]),
        Frame(leading: [duo(0.64, charging: true, volume: 0.75)], trailing: []),
        Frame(leading: [duo(0.64, volume: 0.5)], trailing: []),
    ]
}

/// A Dock in miniature: the same glass, a handful of icons.
private struct MiniDock: View {
    let height: CGFloat

    private static let icons: [(Color, Color)] = [
        (Color(red: 0.35, green: 0.78, blue: 0.98), Color(red: 0.04, green: 0.52, blue: 1)),
        (.white, Color(red: 0.84, green: 0.84, blue: 0.88)),
        (Color(red: 1, green: 0.84, blue: 0.04), Color(red: 1, green: 0.62, blue: 0.04)),
        (Color(red: 0.19, green: 0.82, blue: 0.35), Color(red: 0.14, green: 0.54, blue: 0.24)),
        (Color(red: 1, green: 0.39, blue: 0.51), Color(red: 0.83, green: 0.19, blue: 0.37)),
        (Color(red: 0.75, green: 0.35, blue: 0.95), Color(red: 0.49, green: 0.23, blue: 0.7)),
    ]

    var body: some View {
        let icon = height * 0.72
        HStack(spacing: height * 0.12) {
            ForEach(0..<Self.icons.count, id: \.self) { index in
                RoundedRectangle(cornerRadius: icon * 0.24, style: .continuous)
                    .fill(LinearGradient(colors: [Self.icons[index].0, Self.icons[index].1],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: icon, height: icon)
            }
        }
        .padding(.horizontal, height * 0.16)
        .frame(height: height)
        .modifier(SystemGlass(shape: RoundedRectangle(cornerRadius: height * 0.38, style: .continuous)))
    }
}
