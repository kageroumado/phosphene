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
    func `legacy variants still work without source or output HDR metadata`() throws {
        let original = [variant(60, hd), variant(30, hd), variant(15, hd)]
        let legacy = try JSONDecoder().decode([VideoVariant].self, from: JSONEncoder().encode(original))
        #expect(VariantSelection.variant(for: .full, sourceIsHDR: nil, sourceFPS: 60, variants: legacy) == legacy[0])
        #expect(VariantSelection.variant(for: .reduced, sourceIsHDR: nil, sourceFPS: 60, variants: legacy) == legacy[1])
        #expect(VariantSelection.variant(for: .minimal, sourceIsHDR: nil, sourceFPS: 60, variants: legacy) == legacy[2])
        #expect(VariantSelection.variant(for: .paused, sourceIsHDR: nil, sourceFPS: 60, variants: legacy) == nil)
        for policy in [PlaybackPolicy.full, .reduced, .minimal] {
            #expect(VariantSelection.variant(for: policy, sourceIsHDR: true, sourceFPS: 60, variants: legacy) == nil)
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

    @Test(arguments: [false, true])
    func `legacy frames require the original choice and an unchanged source`(replaceDirectory: Bool) throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let entry = dir.appendingPathComponent("entry")
        try fm.createDirectory(at: entry, withIntermediateDirectories: false)
        let original = entry.appendingPathComponent("video.mov")
        try Data([1]).write(to: original)
        let source = try #require(FileIdentity(of: original))
        let staged = dir.appendingPathComponent("staged")
        try fm.createDirectory(at: staged, withIntermediateDirectories: false)
        let alternate = staged.appendingPathComponent(original.lastPathComponent)
        try Data([2, 3]).write(to: alternate)
        try fm.setAttributes([.modificationDate: source.modified], ofItemAtPath: alternate.path)

        let prefix = CachedFrame.prefix("A", 64, 48)
        let timestamp = String(format: "%016llx", Date.timeIntervalSinceReferenceDate.bitPattern)
        let bmp = dir.appendingPathComponent(prefix + timestamp + ".bmp")
        try Data().write(to: bmp)

        func lookup(_ identity: FileIdentity, choice: String = "A", width: Int = 64, legacy: URL? = nil) -> URL? {
            CachedFrame.lookup(
                choice: choice, source: identity, width: width, height: 48, directory: dir,
                legacyOriginal: legacy, recordsDirectory: dir,
            )
        }

        #expect(lookup(source, legacy: original)?.lastPathComponent == bmp.lastPathComponent)
        #expect(lookup(source) == nil)
        #expect(lookup(source, choice: "B", legacy: original) == nil)
        #expect(lookup(source, width: 32, legacy: original) == nil)

        if replaceDirectory {
            // Staged media can predate the still when the whole entry is swapped later.
            let result = unsafe renamex_np(staged.path, entry.path, UInt32(RENAME_SWAP))
            try #require(result == 0)
        } else {
            try Data([2, 3]).write(to: original, options: .atomic)
            try fm.setAttributes([.modificationDate: source.modified], ofItemAtPath: original.path)
        }
        let replacement = try #require(FileIdentity(of: original))
        #expect(lookup(source, legacy: original) == nil)
        #expect(lookup(replacement, legacy: original) == nil)

        let record = CachedFrame(choice: "A", source: replacement, width: 64, height: 48, filename: bmp.lastPathComponent)
        try JSONEncoder().encode(record).write(to: CachedFrame.recordURL(prefix, in: dir))
        #expect(lookup(replacement) == bmp)
        #expect(lookup(source, legacy: original) == nil)
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
