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

    @Test
    func `HDR and unresolved originals bypass legacy variants`() {
        for hdr: Bool? in [true, nil] {
            for policy in [PlaybackPolicy.full, .reduced, .minimal, .paused] {
                #expect(VariantSelection.variant(for: policy, sourceIsHDR: hdr, sourceFPS: 60, variants: [variant(60, hd)]) == nil)
            }
        }
    }

    @Test
    func `variant color metadata must agree with its source`() {
        let hdr = VideoVariant(filename: "hdr.mp4", fps: 60, resolution: hd, isHDR: true)
        let sdr = VideoVariant(filename: "sdr.mp4", fps: 30, resolution: hd, isHDR: false)
        let mapped = VideoVariant(filename: "mapped.mp4", fps: 15, resolution: hd, isHDR: false, toneMappedToSDR: true)
        let unverified = VideoVariant(filename: "unverified.mp4", fps: 15, resolution: hd, toneMappedToSDR: true)
        let variants = [hdr, sdr, mapped, unverified]
        #expect(VariantSelection.variant(for: .full, sourceIsHDR: true, sourceFPS: 60, variants: variants) == hdr)
        #expect(VariantSelection.variant(for: .reduced, sourceIsHDR: true, sourceFPS: 60, variants: variants) == mapped)
        #expect(VariantSelection.variant(for: .minimal, sourceIsHDR: true, sourceFPS: 60, variants: [sdr, unverified]) == nil)
        #expect(VariantSelection.variant(for: .minimal, sourceIsHDR: false, sourceFPS: 60, variants: variants) == sdr)
        #expect(VariantSelection.variant(for: .full, sourceIsHDR: nil, sourceFPS: 60, variants: variants) == nil)
        #expect(VariantSelection.variant(for: .paused, sourceIsHDR: true, sourceFPS: 60, variants: variants) == nil)
    }

    @Test
    func `cached frame belongs to one source and display size`() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("video.mov")
        try Data([1]).write(to: source)
        let old = try #require(FileIdentity(of: source))
        let name = CachedFrame.prefix("A", 64, 48) + "1234.bmp"
        let bmp = dir.appendingPathComponent(name)
        try Data().write(to: bmp)
        let record = CachedFrame(choice: "A", source: old, width: 64, height: 48, filename: name)
        let decoded = try JSONDecoder().decode(CachedFrame.self, from: JSONEncoder().encode(record))
        #expect(decoded.imageURL(choice: "A", source: old, width: 64, height: 48, directory: dir) == bmp)
        #expect(decoded.imageURL(choice: "A", source: old, width: 32, height: 24, directory: dir) == nil)
        try Data([2, 3]).write(to: source, options: .atomic)
        let new = try #require(FileIdentity(of: source))
        #expect(decoded.imageURL(choice: "A", source: new, width: 64, height: 48, directory: dir) == nil)
    }

    /// The shipped regression: a Balanced-optimized 60fps video silently played
    /// its 30fps tier forever at full policy. Full must fall back to the original.
    @Test
    func `full policy plays the original when no full rate tier exists`() {
        let balanced = [variant(30, fourK), variant(15, fourK)]
        #expect(VariantSelection.variant(for: .full, sourceIsHDR: false, sourceFPS: 60, variants: balanced) == nil)
    }

    @Test
    func `full policy plays battery savers downscaled full rate tier`() {
        let batterySaver = [variant(60, hd), variant(30, hd), variant(15, hd)]
        #expect(VariantSelection.variant(for: .full, sourceIsHDR: false, sourceFPS: 60, variants: batterySaver)?.fps == 60)
    }

    @Test
    func `reduced picks the highest tier below source`() {
        let balanced = [variant(30, fourK), variant(15, fourK)]
        #expect(VariantSelection.variant(for: .reduced, sourceIsHDR: false, sourceFPS: 60, variants: balanced)?.fps == 30)

        let batterySaver = [variant(60, hd), variant(30, hd), variant(15, hd)]
        #expect(VariantSelection.variant(for: .reduced, sourceIsHDR: false, sourceFPS: 60, variants: batterySaver)?.fps == 30)
    }

    @Test
    func `minimal picks the lowest tier`() {
        let balanced = [variant(30, fourK), variant(15, fourK)]
        #expect(VariantSelection.variant(for: .minimal, sourceIsHDR: false, sourceFPS: 60, variants: balanced)?.fps == 15)
    }

    @Test
    func `paused resolves to the original`() {
        let balanced = [variant(30, fourK), variant(15, fourK)]
        #expect(VariantSelection.variant(for: .paused, sourceIsHDR: false, sourceFPS: 60, variants: balanced) == nil)
    }

    @Test
    func `empty variants always resolve to the original`() {
        for policy in [PlaybackPolicy.full, .reduced, .minimal, .paused] {
            #expect(VariantSelection.variant(for: policy, sourceIsHDR: false, sourceFPS: 60, variants: []) == nil)
        }
    }

    @Test
    func `selection sorts unordered input`() {
        let shuffled = [variant(15, fourK), variant(30, fourK)]
        #expect(VariantSelection.variant(for: .reduced, sourceIsHDR: false, sourceFPS: 60, variants: shuffled)?.fps == 30)
        #expect(VariantSelection.variant(for: .minimal, sourceIsHDR: false, sourceFPS: 60, variants: shuffled)?.fps == 15)
    }

    /// A lone below-source tier serves reduced and minimal but never full.
    @Test
    func `single low tier`() {
        let single = [variant(30, fourK)]
        #expect(VariantSelection.variant(for: .full, sourceIsHDR: false, sourceFPS: 60, variants: single) == nil)
        #expect(VariantSelection.variant(for: .reduced, sourceIsHDR: false, sourceFPS: 60, variants: single)?.fps == 30)
        #expect(VariantSelection.variant(for: .minimal, sourceIsHDR: false, sourceFPS: 60, variants: single)?.fps == 30)
    }
}
