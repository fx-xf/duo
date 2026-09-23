import Foundation
import Combine
import IOKit.ps
import Network
import CoreWLAN
import CoreAudio
import AudioToolbox

struct BatteryState: Equatable {
    var level: Double
    var isCharging: Bool
    var isPluggedIn: Bool
    var isLowPower: Bool

    var isLow: Bool { level <= 0.2 && !isPluggedIn }
}

enum NetworkState: Equatable {
    case wifi(bars: Int)
    case ethernet
    case other
    case offline

    /// The kind of link, ignoring signal strength — a change here is news, a
    /// Wi-Fi bar coming and going is not.
    var kind: Int {
        switch self {
        case .wifi: return 0
        case .ethernet: return 1
        case .other: return 2
        case .offline: return 3
        }
    }
}

enum HeadphoneKind: Equatable {
    case airPods, airPodsPro, airPodsMax, headphones

    init(outputName name: String) {
        let lowered = name.lowercased()
        if lowered.contains("airpods max") { self = .airPodsMax }
        else if lowered.contains("airpods pro") { self = .airPodsPro }
        else if lowered.contains("airpods") { self = .airPods }
        else { self = .headphones }
    }

    var symbol: String {
        switch self {
        case .airPods: return "airpods"
        case .airPodsPro: return "airpodspro"
        case .airPodsMax: return "airpodsmax"
        case .headphones: return "headphones"
        }
    }
}

struct AudioState: Equatable {
    var volume: Double
    var isMuted: Bool
    /// Set while a Bluetooth headset is the output.
    var headphones: HeadphoneKind?
    var outputName: String
}

/// Battery, network and sound, from public APIs only, published on the main thread.
final class SystemStatus: ObservableObject {
    @Published private(set) var battery: BatteryState?
    @Published private(set) var network: NetworkState = .other
    @Published private(set) var audio = AudioState(volume: 0.5, isMuted: false, headphones: nil, outputName: "")
    @Published private(set) var headphoneBattery: Double?

    /// Moments worth surfacing a widget for, as opposed to steady state.
    let volumeChanged = PassthroughSubject<Void, Never>()
    let networkChanged = PassthroughSubject<Void, Never>()

    private let batteryMonitor = BatteryMonitor()
    private let networkMonitor = NetworkMonitor()
    private let audioMonitor = AudioMonitor()
    private var headphoneTimer: Timer?
    private var hasNetwork = false
    private var started = false

    func start() {
        guard !started else { return }
        started = true

        batteryMonitor.onChange = { [weak self] in self?.battery = BatteryMonitor.read() }
        batteryMonitor.start()
        battery = BatteryMonitor.read()
        NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.battery = BatteryMonitor.read()
        }

        networkMonitor.onChange = { [weak self] state in
            guard let self, state != self.network || !self.hasNetwork else { return }
            let newsworthy = self.hasNetwork && state.kind != self.network.kind
            self.hasNetwork = true
            self.network = state
            if newsworthy { self.networkChanged.send() }
        }
        networkMonitor.start()

        audioMonitor.onChange = { [weak self] state in self?.apply(state) }
        audioMonitor.start()
    }

    private func apply(_ state: AudioState) {
        let old = audio
        audio = state
        let sameDevice = state.outputName == old.outputName && !old.outputName.isEmpty
        if sameDevice, abs(state.volume - old.volume) > 0.001 || state.isMuted != old.isMuted {
            volumeChanged.send()
        }
        if state.headphones == nil {
            headphoneBattery = nil
            headphoneTimer?.invalidate()
            headphoneTimer = nil
        } else if !sameDevice {
            readHeadphoneBattery(named: state.outputName)
            headphoneTimer?.invalidate()
            headphoneTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
                guard let self, self.audio.headphones != nil else { return }
                self.readHeadphoneBattery(named: self.audio.outputName)
            }
        }
    }

    private func readHeadphoneBattery(named name: String) {
        HeadphoneBattery.read(named: name) { [weak self] level in
            guard let self, self.audio.outputName == name else { return }
            self.headphoneBattery = level
        }
    }
}

// MARK: - Battery

private final class BatteryMonitor {
    var onChange: (() -> Void)?
    private var source: CFRunLoopSource?

    func start() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let monitor = Unmanaged<BatteryMonitor>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { monitor.onChange?() }
        }, context)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        self.source = source
    }

    /// Nil on a Mac without an internal battery.
    static func read() -> BatteryState? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  description[kIOPSIsPresentKey] as? Bool ?? true else { continue }
            let current = description[kIOPSCurrentCapacityKey] as? Int ?? 0
            let maximum = max(description[kIOPSMaxCapacityKey] as? Int ?? 100, 1)
            return BatteryState(level: min(1, Double(current) / Double(maximum)),
                                isCharging: description[kIOPSIsChargingKey] as? Bool ?? false,
                                isPluggedIn: description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue,
                                isLowPower: ProcessInfo.processInfo.isLowPowerModeEnabled)
        }
        return nil
    }
}

// MARK: - Network

private final class NetworkMonitor {
    var onChange: ((NetworkState) -> Void)?
    private let monitor = NWPathMonitor()
    private var path: NWPath?
    private var timer: Timer?

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.path = path
                self?.publish()
            }
        }
        monitor.start(queue: DispatchQueue(label: "app.duo.network", qos: .utility))
        // Wi-Fi signal drifts without the path changing, so look again now and then.
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.publish() }
    }

    private func publish() {
        guard let path else { return }
        let state: NetworkState
        if path.status != .satisfied {
            state = .offline
        } else if path.usesInterfaceType(.wiredEthernet) {
            state = .ethernet
        } else if path.usesInterfaceType(.wifi) {
            state = .wifi(bars: Self.wifiBars())
        } else {
            state = .other
        }
        onChange?(state)
    }

    /// Signal strength needs no location permission; only the network name would.
    private static func wifiBars() -> Int {
        guard let rssi = CWWiFiClient.shared().interface()?.rssiValue(), rssi < 0 else { return 3 }
        return rssi >= -60 ? 3 : rssi >= -72 ? 2 : 1
    }
}

// MARK: - Sound

private final class AudioMonitor {
    var onChange: ((AudioState) -> Void)?
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    func start() {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { [weak self] _, _ in
            self?.rebind()
        }
        rebind()
    }

    /// The default output changed: listen to the new device's volume and mute.
    private func rebind() {
        for (object, address, block) in listeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(object, &address, .main, block)
        }
        listeners.removeAll()

        let device = Self.defaultOutput()
        for selector in [kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyMute] {
            var address = AudioObjectPropertyAddress(mSelector: selector,
                                                     mScope: kAudioDevicePropertyScopeOutput,
                                                     mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectHasProperty(device, &address) else { continue }
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.publish(device) }
            if AudioObjectAddPropertyListenerBlock(device, &address, .main, block) == noErr {
                listeners.append((device, address, block))
            }
        }
        publish(device)
    }

    private func publish(_ device: AudioObjectID) {
        let name = Self.string(device, kAudioObjectPropertyName, scope: kAudioObjectPropertyScopeGlobal)
        let transport: UInt32 = Self.value(device, kAudioDevicePropertyTransportType, scope: kAudioObjectPropertyScopeGlobal) ?? 0
        let bluetooth = transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
        let volume: Float32 = Self.value(device, kAudioHardwareServiceDeviceProperty_VirtualMainVolume) ?? 0.5
        let muted: UInt32 = Self.value(device, kAudioDevicePropertyMute) ?? 0
        onChange?(AudioState(volume: Double(volume),
                             isMuted: muted != 0,
                             headphones: bluetooth ? HeadphoneKind(outputName: name) : nil,
                             outputName: name))
    }

    private static func defaultOutput() -> AudioObjectID {
        value(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice,
              scope: kAudioObjectPropertyScopeGlobal) ?? AudioObjectID(kAudioObjectUnknown)
    }

    private static func value<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                 scope: AudioObjectPropertyScope = kAudioDevicePropertyScopeOutput) -> T? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(object, &address) else { return nil }
        var size = UInt32(MemoryLayout<T>.size)
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
        defer { pointer.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer) == noErr else { return nil }
        return pointer.load(as: T.self)
    }

    private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                               scope: AudioObjectPropertyScope) -> String {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &name) == noErr,
              let name else { return "" }
        return name.takeRetainedValue() as String
    }
}

// MARK: - Headphone battery

/// There is no public API for a Bluetooth headset's battery, but the system
/// report carries it. Slow (about a second), so it runs off the main thread and
/// only when a headset arrives, then every few minutes.
private enum HeadphoneBattery {
    static func read(named name: String, completion: @escaping (Double?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
            process.arguments = ["SPBluetoothDataType", "-json"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            var level: Double?
            if (try? process.run()) != nil {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                level = parse(data, name: name)
            }
            DispatchQueue.main.async { completion(level) }
        }
    }

    /// The lowest bud decides — that is the one that runs out first. The case
    /// only counts for over-ear sets, which report a single "main" level.
    private static func parse(_ data: Data, name: String) -> Double? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let controllers = root["SPBluetoothDataType"] as? [[String: Any]] else { return nil }
        let wanted = name.lowercased()
        var fallback: Double?
        for controller in controllers {
            for entry in controller["device_connected"] as? [[String: Any]] ?? [] {
                for (deviceName, info) in entry {
                    guard let info = info as? [String: Any] else { continue }
                    let levels = ["device_batteryLevelLeft", "device_batteryLevelRight", "device_batteryLevelMain"]
                        .compactMap { info[$0] as? String }
                        .compactMap { Double($0.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)) }
                    guard let lowest = levels.min() else { continue }
                    if deviceName.lowercased() == wanted || wanted.contains(deviceName.lowercased()) {
                        return lowest / 100
                    }
                    fallback = fallback ?? lowest / 100
                }
            }
        }
        return fallback
    }
}
