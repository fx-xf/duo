import Foundation

/// Hinge angle in, glass tilt out. Kept free of AppKit so it can be driven by a
/// simulated lid.
struct LidModel {
    /// The fold starts once the lid is closed past this angle. Above it the
    /// desktop is left alone, however far the lid is opened or nudged.
    var startAngle: Double = 80
    /// Also measure the fold from wherever the lid last came to rest: every
    /// movement folds, and a lid that stops above the threshold gets its desktop
    /// back at whatever angle you left it. Below the threshold the ordinary fold
    /// still holds, so closing the lid always plays in full, however slowly.
    var dynamic = false

    private(set) var springAngle: Double
    private(set) var springVelocity: Double = 0
    /// Degrees the glass has tilted away from the viewer.
    private(set) var tilt: Double = 0
    /// `tilt` as a fraction of the way from the start angle to shut.
    private(set) var progress: Double = 0

    /// The angle the dynamic fold is measured from.
    private var anchor: Double
    /// A slow average of the sensor. Rattle averages out of it; a real movement,
    /// however slow, keeps pushing it the same way.
    private var slowAngle: Double
    private var clock: Double = 0
    private var trail: [(time: Double, angle: Double)] = []
    private var stillFor: Double = 0

    /// Past this the panel is nearly edge-on and there is nothing left to show.
    private static let maxTilt = 85.0
    /// The sensor reports whole degrees and a hand on the deck rattles them by
    /// one, so the first couple of degrees never count as a fold.
    private static let deadZone = 2.5
    /// The lid is holding still when the slow average has drifted less than
    /// this over the window. A close at 1.5°/s still counts as moving.
    private static let stillWindow = 0.45
    private static let stillDrift = 0.6
    private static let settleDelay = 0.08
    private static let releaseTime = 0.25

    init(angle: Double) {
        springAngle = angle
        anchor = angle
        slowAngle = angle
    }

    @discardableResult
    mutating func step(target: Double, dt: Double) -> Double {
        clock += dt

        // Tight on the way down so the glass keeps up with the lid; a softer,
        // slightly bouncy spring on the way up gives the snap back.
        let closing = target < springAngle
        let stiffness: Double = closing ? 900 : 420
        let damping: Double = closing ? 60 : 30
        springVelocity += (-stiffness * (springAngle - target) - damping * springVelocity) * dt
        springAngle += springVelocity * dt

        let start = max(startAngle, 1)
        let thresholdTilt = max(0, start - springAngle)

        guard dynamic else {
            anchor = springAngle
            trail.removeAll()
            stillFor = 0
            return finish(thresholdTilt)
        }

        slowAngle += (target - slowAngle) * min(1, dt / 0.12)
        trail.append((clock, slowAngle))
        while let first = trail.first, clock - first.time > Self.stillWindow { trail.removeFirst() }
        let spanned = clock - (trail.first?.time ?? clock) >= Self.stillWindow * 0.9
        let drift = abs(slowAngle - (trail.first?.angle ?? slowAngle))
        stillFor = spanned && drift < Self.stillDrift ? stillFor + dt : 0

        if springAngle > anchor {
            // Opening hands the reference back: only closing folds.
            anchor = springAngle
        } else if stillFor > Self.settleDelay {
            // A lid that has stopped becomes the new reference, so the desktop
            // unfolds wherever you leave it.
            anchor += (springAngle - anchor) * min(1, dt / Self.releaseTime)
            if anchor - springAngle < 0.4 { anchor = springAngle }
        }

        let movementTilt = max(0, anchor - springAngle - Self.deadZone)
        return finish(max(movementTilt, thresholdTilt))
    }

    private mutating func finish(_ degrees: Double) -> Double {
        tilt = min(Self.maxTilt, degrees)
        progress = min(1, tilt / max(startAngle, 1))
        return progress
    }
}
