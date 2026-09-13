import SwiftUI
import ServiceManagement

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, appearance, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .appearance: return "Appearance"
        case .about: return "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "paintbrush"
        case .about: return "info.circle"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var prefs = Preferences.shared
    @ObservedObject var engine: BendEngine
    @State private var selection: SettingsPane = .appearance

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                row(.general)
                Section("Settings") { row(.appearance) }
                Section("Duo") { row(.about) }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 170, ideal: 178, max: 200)
        } detail: {
            Group {
                switch selection {
                case .general: GeneralPane(prefs: prefs, engine: engine)
                case .appearance: AppearancePane(prefs: prefs, engine: engine)
                case .about: AboutPane(prefs: prefs)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(width: 720, height: 520)
    }

    private func row(_ pane: SettingsPane) -> some View {
        Label(pane.title, systemImage: pane.symbol).tag(pane)
    }
}

// MARK: - Appearance

struct AppearancePane: View {
    @ObservedObject var prefs: Preferences
    @ObservedObject var engine: BendEngine

    private var previewProgress: Double {
        if prefs.followLid { return engine.progress }
        let start = max(prefs.startAngle, 1)
        return max(0, min(1, (start - prefs.manualAngle) / start))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Appearance")
                    .font(.system(size: 15, weight: .semibold))

                LidPreview(progress: previewProgress,
                           perspective: prefs.perspective,
                           blur: prefs.blur,
                           shadow: prefs.shadow,
                           style: prefs.style)
                    .frame(height: 200)
                    .frame(maxWidth: .infinity)

                HStack(spacing: 14) {
                    Text("\(Int(prefs.followLid ? engine.rawAngle : prefs.manualAngle))°")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .leading)

                    Slider(value: $prefs.manualAngle, in: 0...180)
                        .disabled(prefs.followLid)

                    Toggle("Follow lid", isOn: $prefs.followLid)
                        .toggleStyle(.switch)
                        .disabled(!engine.hasSensor)
                        .fixedSize()
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Style")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)

                    HStack(spacing: 12) {
                        ForEach(BendStyle.allCases) { style in
                            StyleTile(style: style, selected: prefs.style == style) {
                                prefs.style = style
                            }
                        }
                    }

                    Text(prefs.style.blurb)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Follow every movement", isOn: $prefs.dynamicFold)
                            .toggleStyle(.switch)
                        Text("The fold leans in whenever the hinge turns and lets go once the lid stops. Close it in a hurry and the full fold still plays.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Divider()
                        angleRow("Starts below", value: $prefs.startAngle)
                        Text("Nothing happens above this angle, however you move the lid.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Divider()
                        percentRow("Perspective", value: $prefs.perspective)
                        Divider()
                        percentRow("Variable blur", value: $prefs.blur)
                        Divider()
                        percentRow("Shadow", value: $prefs.shadow)
                    }
                    .padding(6)
                }
            }
            .padding(24)
        }
    }

    /// Where the fold starts, in degrees of hinge angle.
    private func angleRow(_ title: String, value: Binding<Double>) -> some View {
        HStack(spacing: 14) {
            Text(title)
                .font(.system(size: 12))
                .frame(width: 96, alignment: .leading)
            Slider(value: value, in: 30...110)
            Text("\(Int(value.wrappedValue))°")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
        }
    }

    private func percentRow(_ title: String, value: Binding<Double>) -> some View {
        HStack(spacing: 14) {
            Text(title)
                .font(.system(size: 12))
                .frame(width: 96, alignment: .leading)
            Slider(value: value, in: 0...1)
            Text("\(Int(value.wrappedValue * 100))%")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
        }
    }
}

struct StyleTile: View {
    let style: BendStyle
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                LidPreview(progress: 0.55,
                           perspective: style.preset.perspective,
                           blur: style.preset.blur,
                           shadow: style.preset.shadow,
                           style: style)
                    .frame(height: 74)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.12),
                                          lineWidth: selected ? 2.5 : 1)
                    )

                HStack(spacing: 4) {
                    Text(style.title).font(.system(size: 11))
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }
}

/// A miniature of the effect, good enough to judge the sliders by.
struct LidPreview: View {
    let progress: Double
    let perspective: Double
    let blur: Double
    let shadow: Double
    let style: BendStyle

    var body: some View {
        GeometryReader { geometry in
            let tilt = progress * perspective * 78

            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.black.opacity(0.82))

                ZStack {
                    LinearGradient(colors: [Color(red: 0.34, green: 0.42, blue: 0.56),
                                            Color(red: 0.62, green: 0.68, blue: 0.78),
                                            Color(red: 0.86, green: 0.88, blue: 0.92)],
                                   startPoint: .top, endPoint: .bottom)

                    VStack(spacing: 2) {
                        Text("Wednesday, September 9")
                            .font(.system(size: 7, weight: .medium))
                        Text("9:41")
                            .font(.system(size: 34, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(.white)
                    .shadow(radius: 2)
                    .padding(.bottom, geometry.size.height * 0.22)

                    LinearGradient(colors: [.black.opacity(shadow * 0.85), .clear],
                                   startPoint: .top, endPoint: .center)
                        .allowsHitTesting(false)

                    if style == .frost {
                        LinearGradient(colors: [Color.white.opacity(0.35 * progress), .clear],
                                       startPoint: .top, endPoint: .center)
                    }
                }
                .blur(radius: blur * progress * 7)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .padding(10)
                .rotation3DEffect(.degrees(tilt), axis: (x: 1, y: 0, z: 0),
                                  anchor: .bottom, perspective: 0.55)
            }
        }
    }
}

// MARK: - General

struct GeneralPane: View {
    @ObservedObject var prefs: Preferences
    @ObservedObject var engine: BendEngine
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var hasCapturePermission = DesktopCapture.hasPermission

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("General")
                    .font(.system(size: 15, weight: .semibold))

                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Bend the desktop", isOn: Binding(
                            get: { !prefs.paused },
                            set: { prefs.paused = !$0 }
                        ))
                        .toggleStyle(.switch)

                        Divider()

                        Toggle("Click when the lid opens", isOn: $prefs.soundEnabled)
                            .toggleStyle(.switch)

                        Divider()

                        Toggle("Open at login", isOn: $launchAtLogin)
                            .toggleStyle(.switch)
                            .onChange(of: launchAtLogin) { _, enabled in
                                do {
                                    enabled ? try SMAppService.mainApp.register()
                                            : try SMAppService.mainApp.unregister()
                                } catch {
                                    launchAtLogin = SMAppService.mainApp.status == .enabled
                                }
                            }
                    }
                    .padding(6)
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        statusRow("Lid sensor",
                                  ok: engine.hasSensor,
                                  detail: engine.hasSensor ? "Reading \(Int(engine.rawAngle))°"
                                                           : "Not available on this Mac")
                        Divider()
                        HStack {
                            statusRow("Screen Recording",
                                      ok: hasCapturePermission,
                                      detail: hasCapturePermission ? "Granted" : "Needed to capture the desktop")
                            Spacer()
                            if !hasCapturePermission {
                                Button("Grant…") {
                                    DesktopCapture.requestPermission()
                                    hasCapturePermission = DesktopCapture.hasPermission
                                }
                            }
                        }
                    }
                    .padding(6)
                }

                Text("Pause any time from the menu bar, or press Esc while the desktop is bent.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(24)
        }
    }

    private func statusRow(_ title: String, ok: Bool, detail: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(ok ? Color.green : Color.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - About

struct AboutPane: View {
    @ObservedObject var prefs: Preferences

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.3"
    }

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "macbook")
                .font(.system(size: 48, weight: .thin))
            Text("Duo").font(.system(size: 22, weight: .semibold))
            Text("Version \(version)").font(.system(size: 12)).foregroundStyle(.secondary)
            Text("Your desktop bends as you close the lid.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text("\(prefs.bendCount) bends on this Mac")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            Spacer()
            Text("Frames never leave this Mac.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity)
    }
}
