import AppKit
import SwiftUI
import CoreAudio
import AudioToolbox

// The Sound module from the menu bar, opened from the headphones widget: the
// volume, every output, and a headset's listening modes. All of it goes through
// Core Audio — the listening mode too, through the two properties the Bluetooth
// audio driver publishes for it.

// MARK: - Listening modes

enum ListeningMode: UInt32, Identifiable {
    case off = 1, noiseCancellation = 2, transparency = 3, adaptive = 4

    var id: UInt32 { rawValue }

    var title: String {
        switch self {
        case .off: return "Off"
        case .noiseCancellation: return "Noise Cancellation"
        case .transparency: return "Transparency"
        case .adaptive: return "Adaptive"
        }
    }

    /// Control Center's own glyphs sit in the private symbol set; public
    /// stand-ins take over should they ever move.
    var glyph: NSImage? {
        switch self {
        case .off: return Glyph.named("person.fill", fallback: "person.fill")
        case .noiseCancellation: return Glyph.named("person.closed.fill", fallback: "person.crop.circle.fill")
        case .transparency: return Glyph.named("person.open.fill", fallback: "person.wave.2.fill")
        case .adaptive: return Glyph.named("person.and.sparkles.fill", fallback: "sparkles")
        }
    }
}

private enum Glyph {
    private static let privateSet = Bundle(path: "/System/Library/CoreServices/CoreGlyphsPrivate.bundle")

    static func named(_ name: String, fallback: String) -> NSImage? {
        if let image = privateSet?.image(forResource: name) {
            image.isTemplate = true
            return image
        }
        return NSImage(systemSymbolName: fallback, accessibilityDescription: nil)
    }
}

private func fourCharCode(_ code: String) -> AudioObjectPropertySelector {
    code.utf8.reduce(0) { $0 << 8 | AudioObjectPropertySelector($1) }
}

/// The current mode, and a mask of the modes the headset offers: noise
/// cancellation, transparency and adaptive, lowest bit first. Off is not in the
/// mask — it shows only once the user has allowed it and picked it.
private let listeningModeSelector = fourCharCode("lstm")
private let listeningModesSelector = fourCharCode("lsms")

// MARK: - Outputs

struct AudioOutput: Identifiable, Equatable {
    let id: AudioObjectID
    let name: String
    let transport: UInt32

    var isBluetooth: Bool {
        transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    var isBuiltIn: Bool { transport == kAudioDeviceTransportTypeBuiltIn }

    func symbol(laptop: Bool) -> String {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: return laptop ? "laptopcomputer" : "desktopcomputer"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return HeadphoneKind(outputName: name).symbol
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return "display"
        case kAudioDeviceTransportTypeAirPlay: return "airplayaudio"
        case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate: return "waveform"
        default: return "hifispeaker"
        }
    }
}

/// Every output, the one in use, its volume and its listening mode — kept live
/// for as long as the panel is open.
final class SoundControl: ObservableObject {
    @Published private(set) var outputs: [AudioOutput] = []
    @Published private(set) var selected = AudioObjectID(kAudioObjectUnknown)
    @Published private(set) var volume: Double = 0.5
    @Published private(set) var muted = false
    @Published private(set) var canSetVolume = false
    @Published private(set) var listeningMode: ListeningMode?
    @Published private(set) var listeningModes: [ListeningMode] = []

    private typealias Listener = (object: AudioObjectID, address: AudioObjectPropertyAddress, block: AudioObjectPropertyListenerBlock)
    private var systemListeners: [Listener] = []
    private var deviceListeners: [Listener] = []
    /// A mode just asked for, shown at once while the headset catches up.
    private var pendingMode: (mode: ListeningMode, until: Date)?
    /// The volume last written. A headset keeps only sixteen steps and answers
    /// each write with the nearest one, a beat late; those answers mustn't drag
    /// the knob back.
    private var writtenVolume: (level: Double, at: Date)?
    private var queuedVolume: Float32?
    private var writingVolume = false
    private let volumeWriter = DispatchQueue(label: "app.duo.volume", qos: .userInitiated)

    var selectedOutput: AudioOutput? { outputs.first { $0.id == selected } }

    func start() {
        guard systemListeners.isEmpty else { return }
        let system = AudioObjectID(kAudioObjectSystemObject)
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice] {
            if let listener = listen(system, selector, scope: kAudioObjectPropertyScopeGlobal, { [weak self] () -> Void in self?.reload() }) {
                systemListeners.append(listener)
            }
        }
        reload()
    }

    func stop() {
        (systemListeners + deviceListeners).forEach(remove)
        systemListeners.removeAll()
        deviceListeners.removeAll()
    }

    // MARK: changes

    func select(_ output: AudioOutput) {
        guard output.id != selected else { return }
        var device = output.id
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal)
        AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                   UInt32(MemoryLayout<AudioObjectID>.size), &device)
    }

    func setVolume(_ value: Double) {
        guard canSetVolume else { return }
        let target = min(max(value, 0), 1)
        volume = target
        if let written = writtenVolume, abs(written.level - target) < 0.004 { return }
        writtenVolume = (target, Date())
        queuedVolume = Float32(target)
        writeVolume()
    }

    /// A write to a Bluetooth headset can hold the caller for tens of
    /// milliseconds — long enough to stall every frame on the main thread. So
    /// writes go out on their own queue, one at a time, and only the latest
    /// waiting value is ever sent.
    private func writeVolume() {
        guard !writingVolume, let level = queuedVolume else { return }
        queuedVolume = nil
        writingVolume = true
        let device = selected
        // Turning it up turns the sound back on, as the menu bar does.
        let unmute = muted && level > 0
        volumeWriter.async { [weak self] in
            var value = level
            var address = Self.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
            AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
            if unmute {
                var off: UInt32 = 0
                var mute = Self.address(kAudioDevicePropertyMute)
                AudioObjectSetPropertyData(device, &mute, 0, nil, UInt32(MemoryLayout<UInt32>.size), &off)
            }
            DispatchQueue.main.async {
                self?.writingVolume = false
                self?.writeVolume()
            }
        }
    }

    func setListeningMode(_ mode: ListeningMode) {
        guard mode != listeningMode else { return }
        var raw = mode.rawValue
        var address = Self.address(listeningModeSelector, scope: kAudioObjectPropertyScopeGlobal)
        guard AudioObjectSetPropertyData(selected, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &raw) == noErr else { return }
        pendingMode = (mode, Date().addingTimeInterval(2))
        listeningMode = mode
        // The headset can refuse (Off, say, when it is not allowed); look again.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.1) { [weak self] in self?.readDevice() }
    }

    // MARK: reading

    private func reload() {
        outputs = Self.outputDevices()
        let current: AudioObjectID = Self.value(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice,
                                                scope: kAudioObjectPropertyScopeGlobal) ?? AudioObjectID(kAudioObjectUnknown)
        if current != selected {
            selected = current
            pendingMode = nil
            writtenVolume = nil
            queuedVolume = nil
            deviceListeners.forEach(remove)
            deviceListeners.removeAll()
            let refresh: () -> Void = { [weak self] in self?.readDevice() }
            for (selector, scope) in [(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyScopeOutput),
                                      (kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput),
                                      (listeningModeSelector, kAudioObjectPropertyScopeGlobal),
                                      (listeningModesSelector, kAudioObjectPropertyScopeGlobal)] {
                if let listener = listen(current, selector, scope: scope, refresh) { deviceListeners.append(listener) }
            }
        }
        readDevice()
    }

    private func readDevice() {
        let device = selected
        let level: Float32? = Self.value(device, kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        let reported = Double(level ?? 0)
        // The headset's own rounding of what was just written: keep the knob
        // where the hand left it. Anything else — the volume keys, another
        // app — moves it.
        if let written = writtenVolume, Date().timeIntervalSince(written.at) < 1, abs(reported - written.level) < 0.07 {
            volume = written.level
        } else {
            volume = reported
        }
        muted = (Self.value(device, kAudioDevicePropertyMute) as UInt32?).map { $0 != 0 } ?? false
        canSetVolume = level != nil && Self.settable(device, kAudioHardwareServiceDeviceProperty_VirtualMainVolume)

        let raw: UInt32? = Self.value(device, listeningModeSelector, scope: kAudioObjectPropertyScopeGlobal)
        let mask: UInt32 = Self.value(device, listeningModesSelector, scope: kAudioObjectPropertyScopeGlobal) ?? 0
        var current = raw.flatMap(ListeningMode.init(rawValue:))
        if let pending = pendingMode {
            if current == pending.mode || Date() > pending.until { pendingMode = nil } else { current = pending.mode }
        }
        var modes: [ListeningMode] = []
        if current == .off { modes.append(.off) }
        if mask & 0b010 != 0 { modes.append(.transparency) }
        if mask & 0b100 != 0 { modes.append(.adaptive) }
        if mask & 0b001 != 0 { modes.append(.noiseCancellation) }
        let settable = raw != nil && Self.settable(device, listeningModeSelector, scope: kAudioObjectPropertyScopeGlobal)
        listeningModes = settable ? modes : []
        listeningMode = settable ? current : nil
    }

    private static func outputDevices() -> [AudioOutput] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = address(kAudioHardwarePropertyDevices, scope: kAudioObjectPropertyScopeGlobal)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }

        let outputs = ids.compactMap { id -> AudioOutput? in
            var streams = Self.address(kAudioDevicePropertyStreams)
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &streamSize) == noErr, streamSize > 0 else { return nil }
            let hidden: UInt32 = value(id, kAudioDevicePropertyIsHidden, scope: kAudioObjectPropertyScopeGlobal) ?? 0
            let canBeDefault: UInt32 = value(id, kAudioDevicePropertyDeviceCanBeDefaultDevice) ?? 1
            guard hidden == 0, canBeDefault != 0 else { return nil }
            return AudioOutput(id: id,
                               name: string(id, kAudioObjectPropertyName),
                               transport: value(id, kAudioDevicePropertyTransportType, scope: kAudioObjectPropertyScopeGlobal) ?? 0)
        }
        // The Mac's own speakers first, the way the menu bar lists them.
        return outputs.filter(\.isBuiltIn) + outputs.filter { !$0.isBuiltIn }
    }

    // MARK: Core Audio plumbing

    private func listen(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope, _ action: @escaping () -> Void) -> Listener? {
        var address = Self.address(selector, scope: scope)
        guard AudioObjectHasProperty(object, &address) else { return nil }
        let block: AudioObjectPropertyListenerBlock = { _, _ in action() }
        guard AudioObjectAddPropertyListenerBlock(object, &address, .main, block) == noErr else { return nil }
        return (object, address, block)
    }

    private func remove(_ listener: Listener) {
        var address = listener.address
        AudioObjectRemovePropertyListenerBlock(listener.object, &address, .main, listener.block)
    }

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioDevicePropertyScopeOutput) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func value<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                 scope: AudioObjectPropertyScope = kAudioDevicePropertyScopeOutput) -> T? {
        var address = address(selector, scope: scope)
        guard object != kAudioObjectUnknown, AudioObjectHasProperty(object, &address) else { return nil }
        var size = UInt32(MemoryLayout<T>.size)
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
        defer { pointer.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer) == noErr else { return nil }
        return pointer.load(as: T.self)
    }

    private static func settable(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                 scope: AudioObjectPropertyScope = kAudioDevicePropertyScopeOutput) -> Bool {
        var address = address(selector, scope: scope)
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(object, &address, &settable) == noErr && settable.boolValue
    }

    private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String {
        var address = address(selector, scope: kAudioObjectPropertyScopeGlobal)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &name) == noErr, let name else { return "" }
        return name.takeRetainedValue() as String
    }
}

// MARK: - The menu

struct SoundMenu: View {
    @ObservedObject var control: SoundControl
    @ObservedObject var status: SystemStatus
    let close: () -> Void

    @State private var expanded = true

    private static let inset: CGFloat = 14

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Sound")
                .font(.system(size: 13, weight: .bold))
                .padding(.horizontal, Self.inset)
                .padding(.top, 13)
                .padding(.bottom, 8)

            volumeRow
                .padding(.horizontal, Self.inset)
                .padding(.bottom, 10)

            separator

            header("Output")
            ForEach(control.outputs) { output in
                OutputRow(output: output,
                          selected: output.id == control.selected,
                          laptop: status.battery != nil,
                          battery: output.id == control.selected && output.isBluetooth ? status.headphoneBattery : nil,
                          expandable: output.id == control.selected && !control.listeningModes.isEmpty,
                          expanded: $expanded) {
                    control.select(output)
                }
            }

            if expanded, !control.listeningModes.isEmpty {
                listeningModes
                    .transition(.opacity)
            }

            separator
                .padding(.top, expanded && !control.listeningModes.isEmpty ? 0 : 4)

            if let headset = control.selectedOutput, headset.isBluetooth {
                MenuRow(title: "\(headset.name) Settings…") {
                    open("x-apple.systempreferences:com.apple.HeadphoneSettings")
                }
            }
            MenuRow(title: "Sound Settings…") {
                open("x-apple.systempreferences:com.apple.Sound-Settings.extension")
            }
        }
        .padding(.bottom, 7)
        .frame(width: 308, alignment: .leading)
        .font(.system(size: 13))
        .animation(.easeOut(duration: 0.2), value: expanded)
        .animation(.easeOut(duration: 0.2), value: control.listeningModes)
    }

    private var volumeRow: some View {
        HStack(spacing: 9) {
            Image(systemName: control.muted ? "speaker.slash.fill" : "speaker.fill")
                .frame(width: 16)
            VolumeSlider(value: control.muted ? 0 : control.volume, enabled: control.canSetVolume) {
                control.setVolume($0)
            }
            Image(systemName: "speaker.wave.3.fill")
                .frame(width: 22)
        }
        .font(.system(size: 13))
        .foregroundStyle(.secondary)
    }

    private var listeningModes: some View {
        VStack(alignment: .leading, spacing: 0) {
            header("Listening Mode")
            ForEach(control.listeningModes) { mode in
                ModeRow(mode: mode, checked: mode == control.listeningMode) {
                    control.setListeningMode(mode)
                }
            }
        }
        .padding(.top, 2)
        .padding(.bottom, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.045))
        .padding(.top, 4)
    }

    private var separator: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.1))
            .frame(height: 1)
            .padding(.horizontal, Self.inset)
            .padding(.vertical, 3)
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, Self.inset)
            .padding(.top, 5)
            .padding(.bottom, 4)
    }

    private func open(_ url: String) {
        if let url = URL(string: url) { NSWorkspace.shared.open(url) }
        close()
    }
}

private struct OutputRow: View {
    let output: AudioOutput
    let selected: Bool
    let laptop: Bool
    let battery: Double?
    let expandable: Bool
    @Binding var expanded: Bool
    let pick: () -> Void

    var body: some View {
        HoverRow(action: pick) {
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(selected ? Color.accentColor : Color.primary.opacity(0.1))
                    Image(systemName: output.symbol(laptop: laptop))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(selected ? Color.white : Color.primary)
                }
                .frame(width: 26, height: 26)

                Text(output.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)

                Spacer(minLength: 4)

                if let battery {
                    HStack(spacing: 5) {
                        Text(battery, format: .percent.precision(.fractionLength(0)))
                            .monospacedDigit()
                        Image(systemName: Self.batterySymbol(battery))
                    }
                    .foregroundStyle(.secondary)
                    .fixedSize()
                }
                if expandable {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 0 : -90))
                        .frame(width: 18, height: 22)
                        .contentShape(Rectangle())
                        .onTapGesture { expanded.toggle() }
                }
            }
            .frame(height: 32)
        }
    }

    private static func batterySymbol(_ level: Double) -> String {
        switch level {
        case 0.88...: return "battery.100"
        case 0.63...: return "battery.75"
        case 0.38...: return "battery.50"
        case 0.13...: return "battery.25"
        default: return "battery.0"
        }
    }
}

private struct ModeRow: View {
    let mode: ListeningMode
    let checked: Bool
    let pick: () -> Void

    var body: some View {
        HoverRow(action: pick) {
            HStack(spacing: 0) {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .semibold))
                    .opacity(checked ? 1 : 0)
                    .frame(width: 16)
                Group {
                    if let glyph = mode.glyph {
                        Image(nsImage: glyph)
                            .renderingMode(.template)
                            .resizable()
                            .scaledToFit()
                    }
                }
                .frame(width: 18, height: 17)
                .foregroundStyle(.secondary)
                .padding(.leading, 12)
                Text(mode.title)
                    .padding(.leading, 9)
                Spacer(minLength: 0)
            }
            .padding(.leading, 5)
            .frame(height: 24)
        }
    }
}

private struct MenuRow: View {
    let title: String
    let action: () -> Void

    var body: some View {
        HoverRow(action: action) {
            Text(title)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 24)
        }
    }
}

/// The menu bar's volume slider: a blue fill and a white knob, blue even while
/// Duo isn't the active app.
private struct VolumeSlider: View {
    let value: Double
    let enabled: Bool
    let set: (Double) -> Void

    /// While dragging, the knob follows the hand and nothing else.
    @State private var dragged: Double?

    private static let knob = CGSize(width: 21, height: 14)

    var body: some View {
        GeometryReader { proxy in
            let travel = max(proxy.size.width - Self.knob.width, 1)
            let x = travel * min(max(dragged ?? value, 0), 1)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.12))
                    .frame(height: 5)
                Capsule()
                    .fill(Color(nsColor: .controlAccentColor))
                    .frame(width: x + Self.knob.width / 2, height: 5)
                Capsule()
                    .fill(Color.white)
                    .overlay(Capsule().strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.22), radius: 1.5, y: 0.5)
                    .frame(width: Self.knob.width, height: Self.knob.height)
                    .offset(x: x)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    guard enabled else { return }
                    let level = min(max((drag.location.x - Self.knob.width / 2) / travel, 0), 1)
                    var instant = Transaction()
                    instant.disablesAnimations = true
                    withTransaction(instant) { dragged = level }
                    set(level)
                }
                .onEnded { _ in dragged = nil })
        }
        .frame(height: 20)
        .opacity(enabled ? 1 : 0.45)
    }
}

/// A row that lights up under the pointer, whether or not Duo is the active
/// app — the panel never takes the focus away from what you were doing.
private struct HoverRow<Content: View>: View {
    let action: () -> Void
    @ViewBuilder let content: () -> Content
    @State private var hovered = false

    var body: some View {
        content()
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(hovered ? 0.08 : 0))
            )
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .background(PointerTracker { hovered = $0 })
    }
}

/// `onHover` only fires in the active app; this listens whatever is in front.
private struct PointerTracker: NSViewRepresentable {
    let changed: (Bool) -> Void

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.changed = changed
        return view
    }

    func updateNSView(_ view: TrackingView, context: Context) {
        view.changed = changed
    }

    final class TrackingView: NSView {
        var changed: ((Bool) -> Void)?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero,
                                           options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                           owner: self))
        }

        override func mouseEntered(with event: NSEvent) { changed?(true) }
        override func mouseExited(with event: NSEvent) { changed?(false) }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

// MARK: - The panel

/// Floats over everything, beside the widget it came from, and closes the way
/// a menu does: a click anywhere else, or on the widget again.
final class SoundPanel {
    private let control = SoundControl()
    private let presence = Presence()
    private var window: NSPanel?
    private var hosting: NSHostingView<PanelRoot>?
    private var monitors: [Any] = []
    private var anchor: (bubble: CGRect, edge: DockEdge) = (.zero, .bottom)

    /// Room around the menu for its shadow.
    private static let margin: CGFloat = 36
    private static let gap: CGFloat = 8

    var isOpen: Bool { window != nil }

    func toggle(from bubble: CGRect, edge: DockEdge, status: SystemStatus) {
        if isOpen { close() } else { open(from: bubble, edge: edge, status: status) }
    }

    func open(from bubble: CGRect, edge: DockEdge, status: SystemStatus) {
        guard window == nil else { return }
        anchor = (bubble, edge)
        control.start()

        let root = PanelRoot(presence: presence,
                             menu: SoundMenu(control: control, status: status) { [weak self] in self?.close() },
                             margin: Self.margin) { [weak self] size in
            // Not in the middle of SwiftUI's layout pass.
            DispatchQueue.main.async { self?.resize(to: size) }
        }
        let hosting = FirstClickHostingView(rootView: root)
        let window = MenuPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .popUpMenu
        window.hidesOnDeactivate = false
        // Keystrokes stay with whatever you were typing into.
        window.becomesKeyOnlyIfNeeded = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        window.contentView = hosting
        window.onEscape = { [weak self] in self?.close() }
        self.window = window
        self.hosting = hosting

        resize(to: hosting.fittingSize.shrunk(by: Self.margin))
        window.orderFrontRegardless()

        presence.shown = false
        DispatchQueue.main.async { [weak self] in
            withAnimation(.spring(response: 0.34, dampingFraction: 0.8)) { self?.presence.shown = true }
        }

        // A click anywhere outside closes it, as a menu would.
        if let outside = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown],
                                                          handler: { [weak self] _ in self?.close() }) {
            monitors.append(outside)
        }
        if let inside = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] event in
            guard let self, let window = self.window else { return event }
            // In the panel's shadow, or in another of Duo's windows (the widget
            // toggles it itself).
            if event.window === window, !self.menuRect.contains(NSEvent.mouseLocation) {
                self.close()
                return nil
            }
            return event
        }) {
            monitors.append(inside)
        }
    }

    func close() {
        guard let window else { return }
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        self.window = nil
        hosting = nil
        control.stop()
        withAnimation(.easeIn(duration: 0.14)) { presence.shown = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { window.orderOut(nil) }
    }

    /// Where the menu itself is, inside the window's shadow margin.
    private var menuRect: CGRect {
        window?.frame.insetBy(dx: Self.margin, dy: Self.margin) ?? .zero
    }

    /// Beside the widget, away from the Dock, kept on screen.
    private func resize(to menu: CGSize) {
        guard let window, menu.width > 0, menu.height > 0 else { return }
        let bubble = anchor.bubble
        let screen = NSScreen.screens.first { $0.frame.intersects(bubble) } ?? NSScreen.main
        let bounds = (screen?.visibleFrame ?? bubble).insetBy(dx: 8, dy: 8)

        var origin: CGPoint
        switch anchor.edge {
        case .bottom:
            origin = CGPoint(x: bubble.midX - menu.width / 2, y: bubble.maxY + Self.gap)
        case .left:
            origin = CGPoint(x: bubble.maxX + Self.gap, y: bubble.midY - menu.height / 2)
        case .right:
            origin = CGPoint(x: bubble.minX - Self.gap - menu.width, y: bubble.midY - menu.height / 2)
        }
        origin.x = min(max(origin.x, bounds.minX), bounds.maxX - menu.width)
        origin.y = min(max(origin.y, anchor.edge == .bottom ? bubble.maxY + Self.gap : bounds.minY), bounds.maxY - menu.height)

        let frame = CGRect(origin: origin, size: menu).insetBy(dx: -Self.margin, dy: -Self.margin)
        window.setFrame(frame, display: true)
        presence.anchor = unitAnchor()
    }

    /// The widget's position as seen from the menu, for it to grow out of.
    private func unitAnchor() -> UnitPoint {
        let menu = menuRect
        guard menu.width > 0, menu.height > 0 else { return .bottom }
        let bubble = anchor.bubble
        let x = min(max((bubble.midX - menu.minX) / menu.width, 0), 1)
        let y = min(max((menu.maxY - bubble.midY) / menu.height, 0), 1)
        switch anchor.edge {
        case .bottom: return UnitPoint(x: x, y: 1)
        case .left: return UnitPoint(x: 0, y: y)
        case .right: return UnitPoint(x: 1, y: y)
        }
    }
}

private extension CGSize {
    func shrunk(by margin: CGFloat) -> CGSize {
        CGSize(width: width - margin * 2, height: height - margin * 2)
    }
}

private final class Presence: ObservableObject {
    @Published var shown = false
    @Published var anchor: UnitPoint = .bottom
}

private struct PanelRoot: View {
    @ObservedObject var presence: Presence
    let menu: SoundMenu
    let margin: CGFloat
    let sized: (CGSize) -> Void

    var body: some View {
        menu
            .fixedSize()
            .background(MenuMaterial(radius: MenuMaterial.radius))
            .clipShape(RoundedRectangle(cornerRadius: MenuMaterial.radius))
            .overlay(RoundedRectangle(cornerRadius: MenuMaterial.radius)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
            .background(GeometryReader { proxy in
                Color.clear.preference(key: MenuSizeKey.self, value: proxy.size)
            })
            .onPreferenceChange(MenuSizeKey.self, perform: sized)
            .shadow(color: .black.opacity(0.22), radius: 18, y: 8)
            .scaleEffect(presence.shown ? 1 : 0.86, anchor: presence.anchor)
            .opacity(presence.shown ? 1 : 0)
            .padding(margin)
    }
}

private struct MenuSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

/// The menu bar's own material. It blurs what lies behind the window, which a
/// SwiftUI clip can't reach — the corners come from its own mask.
private struct MenuMaterial: NSViewRepresentable {
    static let radius: CGFloat = 20
    let radius: CGFloat

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .menu
        view.blendingMode = .behindWindow
        view.state = .active
        view.maskImage = Self.mask(radius)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}

    private static func mask(_ radius: CGFloat) -> NSImage {
        let side = radius * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

private final class MenuPanel: NSPanel {
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) { onEscape?() }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?() } else { super.keyDown(with: event) }
    }
}

/// Acts on the first click, without waiting for Duo to come to the front.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
