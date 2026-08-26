import Foundation

/// The pure math of the playback-rate ramps — separated from `VideoRenderer`'s
/// timers so the continuity invariants can be tested: a ramp starts at the live
/// rate, ends exactly on its target, and its duration shrinks in proportion to
/// the distance it still has to travel.
enum RampMath {
    /// Ease-in-out cubic: smooth acceleration then deceleration.
    /// t in [0, 1] → output in [0, 1].
    static func easeInOut(_ t: Double) -> Double {
        t < 0.5
            ? 4.0 * t * t * t
            : 1.0 - pow(-2.0 * t + 2.0, 3) / 2.0
    }

    /// Timer steps for a ramp covering `distance` (in rate units, 0…1) at
    /// `stepInterval`, scaled down from the full-distance duration.
    static func steps(distance: Double, fullDuration: TimeInterval, stepInterval: TimeInterval) -> Int {
        max(1, Int(fullDuration * distance / stepInterval))
    }

    /// The eased rate at `progress` (0…1) of a ramp from `start` to `target`.
    static func rate(from start: Double, to target: Double, progress: Double) -> Double {
        start + (target - start) * easeInOut(min(max(progress, 0), 1))
    }
}
