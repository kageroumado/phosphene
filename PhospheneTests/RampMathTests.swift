import Foundation
import Testing

/// The continuity invariants behind reversible ramps: a ramp starts at the live
/// rate, ends exactly on its target, and covers less distance in proportionally
/// less time. Their violation was visible on screen as slow-motion playback and
/// a paused wallpaper leaping to speed before decelerating.
@MainActor
struct RampMathTests {
    @Test
    func `easing is anchored at its endpoints`() {
        #expect(RampMath.easeInOut(0) == 0)
        #expect(RampMath.easeInOut(1) == 1)
        #expect(abs(RampMath.easeInOut(0.5) - 0.5) < 0.0001)
    }

    /// A reversal begins exactly where the cancelled ramp left the rate.
    @Test
    func `ramp starts at the current rate`() {
        #expect(RampMath.rate(from: 0.4, to: 1.0, progress: 0) == 0.4)
        #expect(RampMath.rate(from: 0.7, to: 0.0, progress: 0) == 0.7)
    }

    @Test
    func `ramp ends exactly on its target`() {
        #expect(RampMath.rate(from: 0.4, to: 1.0, progress: 1) == 1.0)
        #expect(RampMath.rate(from: 0.7, to: 0.0, progress: 1) == 0.0)
    }

    @Test
    func `ramp is monotonic in both directions`() {
        var previous = RampMath.rate(from: 0.2, to: 1.0, progress: 0)
        for step in 1 ... 100 {
            let rate = RampMath.rate(from: 0.2, to: 1.0, progress: Double(step) / 100)
            #expect(rate >= previous)
            previous = rate
        }
        previous = RampMath.rate(from: 0.9, to: 0.0, progress: 0)
        for step in 1 ... 100 {
            let rate = RampMath.rate(from: 0.9, to: 0.0, progress: Double(step) / 100)
            #expect(rate <= previous)
            previous = rate
        }
    }

    @Test
    func `progress outside the unit range is clamped`() {
        #expect(RampMath.rate(from: 0.0, to: 1.0, progress: 1.5) == 1.0)
        #expect(RampMath.rate(from: 0.0, to: 1.0, progress: -0.5) == 0.0)
    }

    /// Half the distance rides half the schedule — what keeps a reversed ramp
    /// from stretching its remaining travel over the full duration.
    @Test
    func `step count is proportional to distance`() {
        let fullTrip = RampMath.steps(distance: 1.0, fullDuration: 6.0, stepInterval: 1.0 / 120.0)
        let halfTrip = RampMath.steps(distance: 0.5, fullDuration: 6.0, stepInterval: 1.0 / 120.0)
        #expect(fullTrip == 720)
        #expect(halfTrip == 360)
    }

    @Test
    func `a zero distance ramp still takes one step`() {
        #expect(RampMath.steps(distance: 0, fullDuration: 6.0, stepInterval: 1.0 / 120.0) == 1)
    }
}
