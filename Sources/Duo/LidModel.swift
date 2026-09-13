import Foundation

/// Hinge angle in, glass tilt out. Kept free of AppKit so it can be driven by a
/// simulated lid.
struct LidModel {
    /// The fold starts once the lid is closed past this angle. Above it the
    /// desktop is left alone, however far the lid is opened or nudged.
    var startAngle: Double = 80
    /// Measure the fold from wherever the lid last came to rest instead of from
    /// a fixed angle: every movement folds, and a lid that stops gets its
    /// desktop back, at whatever angle you left it.
    var dynamic = false

    private(set) var springAngle: Double
    private(set) var springVelocity: Double = 0
    /// Degrees the glass has tilted away from the viewer.
    private(set) var tilt: Double = 0
    /// `tilt` as a fraction of the way from the start angle to shut.
    private(set) var progress: Double = 0

    /// The angle the dynamic fold is measured from.
    private var anchor: Double
    private var stillAngle: Double
    private var stillFor: Double = 0

    /// Past this the panel is nearly edge-on and there is nothing left to show.
    private static let maxTilt = 85.0
    /// The sensor reports whole degrees and a hand on the deck rattles them by
    /// one, so the first couple of degrees never count as a fold.
    private static let deadZone = 2.5
    /// The lid is holding still while the sensor stays inside this window.
    private static let stillWindow = 2.0
    private static let settleDelay = 0.35
    private static let releaseTime = 0.45

    init(angle: Double) {
        springAngle = angle
        anchor = angle
        stillAngle = angle
    }

    @discardableResult
    mutating func step(target: Double, dt: Double) -> Double {
        // Tight on the way down so the glass keeps up with the lid; a softer,
        // slightly bouncy spring on the way up gives the snap back.
        let closing = target < springAngle
        let stiffness: Double = closing ? 900 : 420
        let damping: Double = closing ? 60 : 30
        springVelocity += (-stiffness * (springAngle - target) - damping * springVelocity) * dt
        springAngle += springVelocity * dt

        if abs(target - stillAngle) > Self.stillWindow {
            stillAngle = target
            stillFor = 0
        } else {
            stillFor += dt
        }

        guard dynamic else {
            anchor = springAngle
            tilt = min(Self.maxTilt, max(0, max(startAngle, 1) - springAngle))
            progress = min(1, tilt / max(startAngle, 1))
            return progress
        }

        if springAngle > anchor {
            // Opening hands the reference back: only closing folds.
            anchor = springAngle
        } else if stillFor > Self.settleDelay {
            // A lid that has stopped becomes the new reference, so the desktop
            // unfolds wherever you leave it — any angle, right up to shut.
            anchor += (springAngle - anchor) * min(1, dt / Self.releaseTime)
            if anchor - springAngle < 0.1 { anchor = springAngle }
        }

        tilt = min(Self.maxTilt, max(0, anchor - springAngle - Self.deadZone))
        progress = min(1, tilt / max(startAngle, 1))
        return progress
    }
}
