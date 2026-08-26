import CoreGraphics
import Foundation
import Testing

/// The optimizer skips the full-FPS tier when it isn't downscaling, so the
/// variant list's shape encodes the preset: Balanced/Quality yield only
/// below-source tiers, Battery Saver includes a downscaled full-rate tier.
@MainActor
struct VariantSelectionTests {
    private let fourK = CGSize(width: 3840, height: 2160)
    private let hd = CGSize(width: 1920, height: 1080)

    private func variant(_ fps: Int, _ resolution: CGSize) -> VideoVariant {
        VideoVariant(filename: "variant_\(fps)fps.mp4", fps: fps, resolution: resolution)
    }

    /// The shipped regression: a Balanced-optimized 60fps video silently played
    /// its 30fps tier forever at full policy. Full must fall back to the original.
    @Test func fullPolicyPlaysTheOriginalWhenNoFullRateTierExists() {
        let balanced = [variant(30, fourK), variant(15, fourK)]
        #expect(VariantSelection.variant(for: .full, sourceFPS: 60, variants: balanced) == nil)
    }

    @Test func fullPolicyPlaysBatterySaversDownscaledFullRateTier() {
        let batterySaver = [variant(60, hd), variant(30, hd), variant(15, hd)]
        #expect(VariantSelection.variant(for: .full, sourceFPS: 60, variants: batterySaver)?.fps == 60)
    }

    @Test func reducedPicksTheHighestTierBelowSource() {
        let balanced = [variant(30, fourK), variant(15, fourK)]
        #expect(VariantSelection.variant(for: .reduced, sourceFPS: 60, variants: balanced)?.fps == 30)

        let batterySaver = [variant(60, hd), variant(30, hd), variant(15, hd)]
        #expect(VariantSelection.variant(for: .reduced, sourceFPS: 60, variants: batterySaver)?.fps == 30)
    }

    @Test func minimalPicksTheLowestTier() {
        let balanced = [variant(30, fourK), variant(15, fourK)]
        #expect(VariantSelection.variant(for: .minimal, sourceFPS: 60, variants: balanced)?.fps == 15)
    }

    @Test func pausedResolvesToTheOriginal() {
        let balanced = [variant(30, fourK), variant(15, fourK)]
        #expect(VariantSelection.variant(for: .paused, sourceFPS: 60, variants: balanced) == nil)
    }

    @Test func emptyVariantsAlwaysResolveToTheOriginal() {
        for policy in [PlaybackPolicy.full, .reduced, .minimal, .paused] {
            #expect(VariantSelection.variant(for: policy, sourceFPS: 60, variants: []) == nil)
        }
    }

    @Test func selectionSortsUnorderedInput() {
        let shuffled = [variant(15, fourK), variant(30, fourK)]
        #expect(VariantSelection.variant(for: .reduced, sourceFPS: 60, variants: shuffled)?.fps == 30)
        #expect(VariantSelection.variant(for: .minimal, sourceFPS: 60, variants: shuffled)?.fps == 15)
    }

    /// A lone below-source tier serves reduced and minimal but never full.
    @Test func singleLowTier() {
        let single = [variant(30, fourK)]
        #expect(VariantSelection.variant(for: .full, sourceFPS: 60, variants: single) == nil)
        #expect(VariantSelection.variant(for: .reduced, sourceFPS: 60, variants: single)?.fps == 30)
        #expect(VariantSelection.variant(for: .minimal, sourceFPS: 60, variants: single)?.fps == 30)
    }
}
