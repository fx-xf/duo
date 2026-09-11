import Foundation

/// Hinge angle in, glass tilt out. Kept free of AppKit so it can be driven by a
/// simulated lid.
struct LidModel {
    /// The fold starts once the lid is closed past this angle. Above it the
    /// desktop is left alone, however far the lid is opened or nudged.
    var startAngle: Double = 70

    private(set) var springAngle: Double
    private(set) var springVelocity: Double = 0
    /// Degrees the lid has closed past `startAngle`: the glass tilt, 1:1 with the hinge.
    private(set) var tilt: Double = 0
    /// `tilt` as a fraction of the way from the start angle to shut.
    private(set) var progress: Double = 0

    init(angle: Double) {
        springAngle = angle
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

        let start = max(startAngle, 1)
        tilt = max(0, start - springAngle)
        progress = min(1, tilt / start)
        return progress
    }
}
