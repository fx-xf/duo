import Foundation

/// Hinge angle in, glass tilt out. Kept free of AppKit so it can be driven by a
/// simulated lid.
struct LidModel {
    /// The fold starts once the lid is closed past this angle. Above it the
    /// desktop is left alone, however far the lid is opened or nudged.
    var startAngle: Double = 80
    /// Follow every movement of the lid rather than only the last stretch before
    /// shut: the fold leans in while the hinge turns and lets go once it settles.
    var dynamic = false

    private(set) var springAngle: Double
    private(set) var springVelocity: Double = 0
    /// How fast the hinge is turning, degrees per second, smoothed.
    private(set) var hingeSpeed: Double = 0
    /// Degrees the glass has tilted away from the viewer.
    private(set) var tilt: Double = 0
    /// `tilt` as a fraction of the way from the start angle to shut.
    private(set) var progress: Double = 0

    private var lastTarget: Double
    private var motionTilt: Double = 0

    /// The sensor reports whole degrees and a hand on the deck rattles them by
    /// one, so nothing slower than this counts as the lid moving.
    private static let stillSpeed = 12.0
    private static let motionGain = 0.18
    private static let motionCap = 18.0
    /// A lid coming down in a hurry is probably on its way shut, so the fold may
    /// start this many degrees earlier than the threshold.
    private static let anticipation = 25.0

    init(angle: Double) {
        springAngle = angle
        lastTarget = angle
    }

    @discardableResult
    mutating func step(target: Double, dt: Double) -> Double {
        hingeSpeed += ((target - lastTarget) / max(dt, 1e-4) - hingeSpeed) * min(1, dt / 0.12)
        lastTarget = target

        // Tight on the way down so the glass keeps up with the lid; a softer,
        // slightly bouncy spring on the way up gives the snap back.
        let closing = target < springAngle
        let stiffness: Double = closing ? 900 : 420
        let damping: Double = closing ? 60 : 30
        springVelocity += (-stiffness * (springAngle - target) - damping * springVelocity) * dt
        springAngle += springVelocity * dt

        let start = max(startAngle, 1)
        let lead = dynamic ? min(Self.anticipation, max(0, (-hingeSpeed - 40) * 0.25)) : 0
        let angleTilt = max(0, start + lead - springAngle)

        // Movement alone earns a little tilt, given back as soon as the lid stops.
        let wanted = dynamic
            ? min(Self.motionCap, max(0, (abs(hingeSpeed) - Self.stillSpeed) * Self.motionGain))
            : 0
        motionTilt += (wanted - motionTilt) * min(1, dt / (wanted > motionTilt ? 0.06 : 0.22))
        // A tenth of a degree is nothing to look at, and an exponential never
        // quite lands: cut it there so a settled lid really is done folding.
        if wanted <= 0, motionTilt < 0.1 { motionTilt = 0 }

        tilt = max(angleTilt, motionTilt)
        progress = min(1, tilt / start)
        return progress
    }
}
