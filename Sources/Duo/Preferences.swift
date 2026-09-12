import Foundation
import Combine

enum BendStyle: String, CaseIterable, Identifiable {
    case silk, shade, frost

    var id: String { rawValue }

    var title: String {
        switch self {
        case .silk: return "Silk"
        case .shade: return "Shade"
        case .frost: return "Frost"
        }
    }

    var blurb: String {
        switch self {
        case .silk: return "Frosted glass: sharp at the hinge, clouding as the lid lifts toward you."
        case .shade: return "Less frost, deeper dimming. The glass goes dark before it goes cloudy."
        case .frost: return "Heavier frost for the same fold. The desktop dissolves into milk glass."
        }
    }

    /// perspective, blur, shadow — the three sliders the style presets write into.
    var preset: (perspective: Double, blur: Double, shadow: Double) {
        switch self {
        case .silk: return (1.00, 0.65, 0.35)
        case .shade: return (0.90, 0.25, 0.85)
        case .frost: return (0.75, 1.00, 0.45)
        }
    }
}

final class Preferences: ObservableObject {
    static let shared = Preferences()

    private let defaults = UserDefaults.standard

    @Published var style: BendStyle {
        didSet {
            guard style != oldValue else { return }
            defaults.set(style.rawValue, forKey: Key.style)
            let p = style.preset
            perspective = p.perspective
            blur = p.blur
            shadow = p.shadow
        }
    }

    @Published var perspective: Double { didSet { defaults.set(perspective, forKey: Key.perspective) } }
    @Published var blur: Double { didSet { defaults.set(blur, forKey: Key.blur) } }
    @Published var shadow: Double { didSet { defaults.set(shadow, forKey: Key.shadow) } }

    /// When true the live hinge sensor drives the bend. When false `manualAngle` does.
    @Published var followLid: Bool { didSet { defaults.set(followLid, forKey: Key.followLid) } }
    @Published var manualAngle: Double { didSet { defaults.set(manualAngle, forKey: Key.manualAngle) } }

    /// The fold starts once the lid closes past this hinge angle.
    @Published var startAngle: Double { didSet { defaults.set(startAngle, forKey: Key.startAngle) } }

    @Published var soundEnabled: Bool { didSet { defaults.set(soundEnabled, forKey: Key.sound) } }
    @Published var paused: Bool = false
    @Published var bendCount: Int { didSet { defaults.set(bendCount, forKey: Key.bendCount) } }

    private enum Key {
        static let style = "style"
        static let perspective = "perspective"
        static let blur = "blur"
        static let shadow = "shadow"
        static let followLid = "followLid"
        static let manualAngle = "manualAngle"
        static let startAngle = "foldStartAngle"
        static let sound = "soundEnabled"
        static let bendCount = "bendCount"
    }

    private init() {
        defaults.register(defaults: [
            Key.style: BendStyle.silk.rawValue,
            Key.perspective: BendStyle.silk.preset.perspective,
            Key.blur: BendStyle.silk.preset.blur,
            Key.shadow: BendStyle.silk.preset.shadow,
            Key.followLid: true,
            Key.manualAngle: 136.0,
            Key.startAngle: 80.0,
            Key.sound: true,
            Key.bendCount: 0,
        ])
        style = BendStyle(rawValue: defaults.string(forKey: Key.style) ?? "") ?? .silk
        perspective = defaults.double(forKey: Key.perspective)
        blur = defaults.double(forKey: Key.blur)
        shadow = defaults.double(forKey: Key.shadow)
        followLid = defaults.bool(forKey: Key.followLid)
        manualAngle = defaults.double(forKey: Key.manualAngle)
        startAngle = defaults.double(forKey: Key.startAngle)
        soundEnabled = defaults.bool(forKey: Key.sound)
        bendCount = defaults.integer(forKey: Key.bendCount)
    }
}
