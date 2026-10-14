import CoreGraphics
import Foundation
import Testing

/// The optimizer skips the full-FPS tier when it isn't downscaling, so the
/// variant list's shape encodes the preset: Balanced/Quality yield only
/// below-source tiers, Battery Saver includes a downscaled full-rate tier.
@MainActor
struct VariantSelectionTests {
    private let fourK = CGSize(width: 3_840, height: 2_160)
    private let hd = CGSize(width: 1_920, height: 1_080)

    private func variant(_ fps: Int, _ resolution: CGSize) -> VideoVariant {
        VideoVariant(filename: "variant_\(fps)fps.mp4", fps: fps, resolution: resolution)
    }

    /// The shipped regression: a Balanced-optimized 60fps video silently played
    /// its 30fps tier forever at full policy. Full must fall back to the original.
    @Test
    func `full policy plays the original when no full rate tier exists`() {
        let balanced = [variant(30, fourK), variant(15, fourK)]
        #expect(VariantSelection.variant(for: .full, sourceFPS: 60, variants: balanced) == nil)
    }

    @Test
    func `full policy plays battery savers downscaled full rate tier`() {
        let batterySaver = [variant(60, hd), variant(30, hd), variant(15, hd)]
        #expect(VariantSelection.variant(for: .full, sourceFPS: 60, variants: batterySaver)?.fps == 60)
    }

    @Test
    func `reduced picks the highest tier below source`() {
        let balanced = [variant(30, fourK), variant(15, fourK)]
        #expect(VariantSelection.variant(for: .reduced, sourceFPS: 60, variants: balanced)?.fps == 30)

        let batterySaver = [variant(60, hd), variant(30, hd), variant(15, hd)]
        #expect(VariantSelection.variant(for: .reduced, sourceFPS: 60, variants: batterySaver)?.fps == 30)
    }

    @Test
    func `minimal picks the lowest tier`() {
        let balanced = [variant(30, fourK), variant(15, fourK)]
        #expect(VariantSelection.variant(for: .minimal, sourceFPS: 60, variants: balanced)?.fps == 15)
    }

    @Test
    func `paused resolves to the original`() {
        let balanced = [variant(30, fourK), variant(15, fourK)]
        #expect(VariantSelection.variant(for: .paused, sourceFPS: 60, variants: balanced) == nil)
    }

    @Test
    func `empty variants always resolve to the original`() {
        for policy in [PlaybackPolicy.full, .reduced, .minimal, .paused] {
            #expect(VariantSelection.variant(for: policy, sourceFPS: 60, variants: []) == nil)
        }
    }

    @Test
    func `selection sorts unordered input`() {
        let shuffled = [variant(15, fourK), variant(30, fourK)]
        #expect(VariantSelection.variant(for: .reduced, sourceFPS: 60, variants: shuffled)?.fps == 30)
        #expect(VariantSelection.variant(for: .minimal, sourceFPS: 60, variants: shuffled)?.fps == 15)
    }

    /// A lone below-source tier serves reduced and minimal but never full.
    @Test
    func `single low tier`() {
        let single = [variant(30, fourK)]
        #expect(VariantSelection.variant(for: .full, sourceFPS: 60, variants: single) == nil)
        #expect(VariantSelection.variant(for: .reduced, sourceFPS: 60, variants: single)?.fps == 30)
        #expect(VariantSelection.variant(for: .minimal, sourceFPS: 60, variants: single)?.fps == 30)
    }
}
