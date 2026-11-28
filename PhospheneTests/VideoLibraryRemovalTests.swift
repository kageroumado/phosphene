import CoreGraphics
import Foundation
import Testing

struct VideoLibraryRemovalTests {
    enum SingleState: CaseIterable {
        case corruptMetadata
        case missingMetadata
        case unreadableMetadata
        case missingMedia
        case missingDirectory
    }

    @Test(arguments: SingleState.allCases)
    func `only a missing single directory is idempotent`(state: SingleState) throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = VideoLibrary(documents: root)
        defer { try? fm.removeItem(at: root) }
        let id = UUID().uuidString
        let media = try writeEntry(id, in: library)
        let directory = media.deletingLastPathComponent()
        let metadata = directory.appendingPathComponent("metadata.json")
        switch state {
        case .corruptMetadata: try Data("{".utf8).write(to: metadata)
        case .missingMetadata: try fm.removeItem(at: metadata)
        case .unreadableMetadata: try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: metadata.path)
        case .missingMedia: try fm.removeItem(at: media)
        case .missingDirectory: try fm.removeItem(at: directory)
        }
        if state == .missingDirectory {
            try library.removeDownloadedChoice(id, files: [media])
            #expect(!fm.fileExists(atPath: directory.path))
        } else {
            #expect(throws: (any Error).self) { try library.removeDownloadedChoice(id, files: [media]) }
            #expect(fm.fileExists(atPath: directory.path))
            #expect(fm.fileExists(atPath: media.path) == (state != .missingMedia))
        }
    }

    @Test
    func `scan preserves unreadable entries and unrecognized media while publishing healthy entries`() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = VideoLibrary(documents: root)
        defer { try? fm.removeItem(at: root) }
        let healthyID = UUID().uuidString
        _ = try writeEntry(healthyID, in: library)
        let unreadableID = UUID().uuidString
        let unreadable = try writeEntry(unreadableID, in: library)
        let metadata = unreadable.deletingLastPathComponent().appendingPathComponent("metadata.json")
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: metadata.path)

        let unrecognizedID = UUID().uuidString
        let media = try writeEntry(unrecognizedID, in: library)
        let directory = media.deletingLastPathComponent()
        try fm.removeItem(at: directory.appendingPathComponent("metadata.json"))
        let renamed = media.deletingPathExtension().appendingPathExtension("qt")
        try fm.moveItem(at: media, to: renamed)
        let empty = library.videosDir.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: empty, withIntermediateDirectories: false)

        #expect(library.scan())
        #expect(library.entries.map(\.id) == [healthyID])
        #expect(fm.fileExists(atPath: unreadable.path))
        #expect(fm.fileExists(atPath: renamed.path))
        #expect(!fm.fileExists(atPath: empty.path))

        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: metadata.path)
        #expect(library.scan())
        #expect(Set(library.entries.map(\.id)) == [healthyID, unreadableID])
    }

    @Test(arguments: [false, true])
    func `scan prunes metadata-only orphans and preserves renamed media`(hasRenamedMedia: Bool) throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = VideoLibrary(documents: root)
        defer { try? fm.removeItem(at: root) }
        let id = UUID().uuidString
        let media = try writeEntry(id, in: library)
        let directory = media.deletingLastPathComponent()
        let metadata = directory.appendingPathComponent("metadata.json")
        let renamed = media.deletingPathExtension().appendingPathExtension("qt")
        let savedMetadata = try Data(contentsOf: metadata)
        if hasRenamedMedia {
            try fm.moveItem(at: media, to: renamed)
        } else {
            try fm.removeItem(at: media)
        }

        #expect(library.scan())
        #expect(library.entry(for: id) == nil)
        if hasRenamedMedia {
            #expect(try Data(contentsOf: renamed) == Data([1]))
            #expect(try Data(contentsOf: metadata) == savedMetadata)
        } else {
            #expect(!fm.fileExists(atPath: directory.path))
        }
    }

    @Test
    func `playback falls back to the first available choice when an ID is unknown`() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = VideoLibrary(documents: root)
        defer { try? fm.removeItem(at: root) }
        _ = try writeEntry(UUID().uuidString, in: library)
        _ = try writeEntry(UUID().uuidString, in: library)
        #expect(library.scan())
        let entries = library.entries
        try #require(entries.count == 2)
        let first = library.videoURL(for: entries[0])
        let second = library.videoURL(for: entries[1])
        let unknown = UUID().uuidString

        #expect(library.videoURL(for: unknown) == nil)
        #expect(!library.isChoiceDownloaded(unknown))
        #expect(library.playbackURL(for: unknown) == first)
        #expect(library.playbackURL(for: entries[1].id) == second)
        try fm.removeItem(at: first)
        #expect(library.playbackURL(for: unknown) == second)
    }

    @Test(arguments: [false, true])
    func `a corrupt pair index allows single-entry playback and removal`(duplicateMembership: Bool) throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = VideoLibrary(documents: root)
        defer { try? fm.removeItem(at: root) }
        let owner = UUID().uuidString
        let counterpart = UUID().uuidString
        let tier = VideoVariant(filename: "variant_12fps.mp4", fps: 12, resolution: CGSize(width: 64, height: 48))
        let original = try writeEntry(owner, in: library, variants: [tier])
        let alternate = try writeEntry(counterpart, in: library)
        let variant = library.variantURL(for: owner, variant: tier)
        try Data([2]).write(to: variant)
        let validation = try validate(original, alternate)
        let pair = AppearancePair(owner: owner, counterpart: counterpart, swapped: false, validation: validation)
        try AppearancePair.update(in: library.videosDir) { $0 = [pair] }
        #expect(library.scan())
        #expect(library.bestVariantURL(for: owner, policy: .reduced) == original)
        #expect(!library.hasPlayableVariant(variant, for: owner))

        let manifest = library.videosDir.appendingPathComponent(".appearance-pairs.json")
        let corrupt = duplicateMembership ? try JSONEncoder().encode([pair, pair]) : Data("{".utf8)
        try corrupt.write(to: manifest)
        #expect(try AppearancePair.read(in: library.videosDir).isEmpty)
        try AppearancePair.requireSingle(owner, in: library.videosDir)
        #expect(library.bestVariantURL(for: owner, policy: .reduced) == variant)
        #expect(library.hasPlayableVariant(variant, for: owner))
        #expect(library.pairRendition(for: owner) == nil)

        #expect(throws: (any Error).self) { try pair.edit(in: library.videosDir, split: true) }
        #expect(throws: (any Error).self) { try pair.remove(in: library.videosDir) }
        #expect(throws: PairIssue.changed) { try library.removeDownloadedChoice(owner, files: [original, alternate]) }
        #expect(try Data(contentsOf: variant) == Data([2]))
        #expect(FileIdentity(of: original) == validation.original)
        #expect(FileIdentity(of: alternate) == validation.alternate)

        try library.removeDownloadedChoice(owner, files: [original])
        #expect(!fm.fileExists(atPath: original.deletingLastPathComponent().path))
        #expect(FileIdentity(of: alternate) == validation.alternate)
        #expect(try Data(contentsOf: manifest) == corrupt)
    }

    @Test
    func `pair choice plays the surviving member after losing its owner directory`() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = VideoLibrary(documents: root)
        defer { try? fm.removeItem(at: root) }
        let owner = UUID().uuidString
        let counterpart = UUID().uuidString
        let original = try writeEntry(owner, in: library)
        let alternate = try writeEntry(counterpart, in: library)
        let pair = try AppearancePair(owner: owner, counterpart: counterpart, swapped: false, validation: validate(original, alternate))
        try AppearancePair.update(in: library.videosDir) { $0 = [pair] }

        #expect(library.scan())
        #expect(library.videoURL(for: owner) == original)
        #expect(library.pairRendition(for: owner) != nil)
        #expect(throws: PairIssue.changed) { try library.removeDownloadedChoice(owner, files: [original]) }
        #expect(fm.fileExists(atPath: original.path))
        #expect(fm.fileExists(atPath: alternate.path))

        try fm.moveItem(at: original.deletingLastPathComponent(), to: root.appendingPathComponent("moved-owner"))
        #expect(library.scan())
        #expect(library.entry(for: owner) == nil)
        #expect(library.videoURL(for: owner) == alternate)
        #expect(library.playbackURL(for: owner) == alternate)
        #expect(library.isChoiceDownloaded(owner))
        #expect(library.pairRendition(for: owner) == nil)
    }

    @Test
    func `reduced pair playback skips incomplete tiers`() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = VideoLibrary(documents: root)
        defer { try? fm.removeItem(at: root) }
        let owner = UUID().uuidString
        let counterpart = UUID().uuidString
        let original = try writeEntry(owner, in: library)
        let alternate = try writeEntry(counterpart, in: library)
        let generation = UUID()
        let optimization = original.deletingLastPathComponent().appendingPathComponent(".paired-variants-\(generation.uuidString)")
        let originalTiers = optimization.appendingPathComponent("original")
        let alternateTiers = optimization.appendingPathComponent("alternate")
        try fm.createDirectory(at: originalTiers, withIntermediateDirectories: true)
        try fm.createDirectory(at: alternateTiers, withIntermediateDirectories: true)
        let tiers = try [30, 15].map { fps in
            let first = originalTiers.appendingPathComponent("\(fps).mov")
            let second = alternateTiers.appendingPathComponent("\(fps).mov")
            try Data([1]).write(to: first)
            try Data([2]).write(to: second)
            return try AppearancePair.Tier(fps: fps, resolution: CGSize(width: 1, height: 1), validation: validate(first, second, fps: Int32(fps)))
        }
        let pair = try AppearancePair(
            owner: owner, counterpart: counterpart, swapped: false, validation: validate(original, alternate, fps: 60),
            optimization: .init(generation: generation, tiers: tiers),
        )
        try AppearancePair.update(in: library.videosDir) { $0 = [pair] }
        #expect(library.scan())
        let rendition = try #require(library.pairRendition(for: owner))

        #expect(rendition.playback(for: .reduced).validation == tiers[0].validation)
        try fm.removeItem(at: alternateTiers.appendingPathComponent("30.mov"))
        #expect(rendition.playback(for: .reduced).validation == tiers[1].validation)
        #expect(rendition.playback(for: .full) == rendition.originals)
    }

    @Test
    func `failed degraded removal preserves membership and tiers`() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = VideoLibrary(documents: root)
        defer { try? fm.removeItem(at: root) }
        let owner = UUID().uuidString
        let counterpart = UUID().uuidString
        let original = try writeEntry(owner, in: library)
        let alternate = try writeEntry(counterpart, in: library)
        let directory = original.deletingLastPathComponent()
        let validation = try validate(original, alternate)
        let generation = UUID()
        let variants = directory.appendingPathComponent(".paired-variants-\(generation.uuidString)")
        let tierFiles = try ["original", "alternate"].map { side in
            let folder = variants.appendingPathComponent(side)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent("tier.mov")
            try Data([3]).write(to: url)
            return url
        }
        let tier = try AppearancePair.Tier(fps: 24, resolution: CGSize(width: 1, height: 1), validation: validate(tierFiles[0], tierFiles[1]))
        let pair = AppearancePair(
            owner: owner, counterpart: counterpart, swapped: false, validation: validation,
            optimization: .init(generation: generation, tiers: [tier]),
        )
        try AppearancePair.update(in: library.videosDir) { $0 = [pair] }
        try Data([2]).write(to: alternate, options: .atomic)
        let replacement = try #require(FileIdentity(of: alternate))
        #expect(replacement.inode != validation.alternate.inode)
        #expect(throws: PairIssue.changed) { try library.removeDownloadedChoice(owner, files: [original, alternate]) }

        try setImmutable(true, at: directory)
        defer { try? setImmutable(false, at: directory) }
        #expect(throws: POSIXError(.EPERM)) { try library.removeDownloadedChoice(owner, files: [original]) }
        #expect(try AppearancePair.read(in: library.videosDir) == [pair])
        #expect(FileIdentity(of: original) == validation.original)
        #expect(pair.optimizedURL(for: tier, alternate: false, in: library.videosDir) == tierFiles[0])
        #expect(pair.optimizedURL(for: tier, alternate: true, in: library.videosDir) == tierFiles[1])
        #expect(FileIdentity(of: alternate) == replacement)

        try setImmutable(false, at: directory)
        try library.removeDownloadedChoice(owner, files: [original])
        #expect(try AppearancePair.read(in: library.videosDir).isEmpty)
        #expect(!fm.fileExists(atPath: directory.path))
        #expect(FileIdentity(of: alternate) == replacement)
    }

    enum MemberVariantCase: CaseIterable {
        case complete
        case replacedAfterConfirmation
        case interrupted
    }

    @Test(arguments: MemberVariantCase.allCases)
    func `removing one pair member's single-video variants checks the confirmed files`(scenario: MemberVariantCase) throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = VideoLibrary(documents: root)
        defer { try? fm.removeItem(at: root) }
        let owner = UUID().uuidString
        let counterpart = UUID().uuidString
        let tiers = [12, 24, 30, 60].map { VideoVariant(filename: "variant_\($0)fps.mp4", fps: $0, resolution: .zero) }
        let unrecognized = VideoVariant(filename: "other.mov", fps: 15, resolution: .zero)
        let original = try writeEntry(owner, in: library, variants: tiers + [unrecognized])
        let alternate = try writeEntry(counterpart, in: library, variants: [tiers[0]])
        let variants = tiers.map { library.variantURL(for: owner, variant: $0) }
        let unrecognizedURL = library.variantURL(for: owner, variant: unrecognized)
        let counterpartVariant = library.variantURL(for: counterpart, variant: tiers[0])
        for url in [variants[0], variants[1], counterpartVariant, unrecognizedURL] {
            try Data([2]).write(to: url)
        }
        try fm.linkItem(at: original, to: variants[2])
        try fm.createSymbolicLink(at: variants[3], withDestinationURL: alternate)
        let paired = original.deletingLastPathComponent().appendingPathComponent(".paired-variants-\(UUID().uuidString)")
        try fm.createDirectory(at: paired, withIntermediateDirectories: false)
        let validation = try validate(original, alternate)
        let pair = AppearancePair(owner: owner, counterpart: counterpart, swapped: true, validation: validation)
        try pair.merge(in: library.videosDir) { (original, alternate) }

        let removal = try pair.memberVariantRemoval(for: owner, in: library.videosDir)
        #expect(removal.filenames == tiers.prefix(2).map(\.filename))
        switch scenario {
        case .complete: break
        case .replacedAfterConfirmation:
            try Data([3]).write(to: variants[1], options: .atomic)
            #expect(throws: PairIssue.changed) { try removal.remove(in: library.videosDir) }
            #expect(try Data(contentsOf: variants[0]) == Data([2]))
            #expect(try Data(contentsOf: variants[1]) == Data([3]))
            #expect(library.scan())
            #expect(library.entry(for: owner)?.variants == tiers + [unrecognized])
            return
        case .interrupted:
            try setImmutable(true, at: variants[1])
            defer { try? setImmutable(false, at: variants[1]) }
            #expect(throws: POSIXError(.EPERM)) { try removal.remove(in: library.videosDir) }
            #expect(!fm.fileExists(atPath: variants[0].path))
            #expect(library.scan())
            #expect(library.entry(for: owner)?.variants == tiers + [unrecognized])
            try setImmutable(false, at: variants[1])
        }
        try removal.remove(in: library.videosDir)
        #expect(library.scan())
        #expect(library.entry(for: owner)?.variants == Array(tiers.dropFirst(2)) + [unrecognized])
        #expect(try AppearancePair.read(in: library.videosDir) == [pair])
        #expect(!fm.fileExists(atPath: variants[0].path))
        #expect(!fm.fileExists(atPath: variants[1].path))
        #expect(fm.fileExists(atPath: paired.path))
        #expect(FileIdentity(of: original) == validation.original)
        #expect(FileIdentity(of: alternate) == validation.alternate)
        #expect(FileIdentity.sameFile(variants[2], original))
        #expect(PathSafety.isItem(at: variants[3], ofType: .typeSymbolicLink))
        #expect(try Data(contentsOf: counterpartVariant) == Data([2]))
        #expect(try Data(contentsOf: unrecognizedURL) == Data([2]))
    }

    enum MissingOwnerCase: CaseIterable {
        case library
        case settingsWithReplacement
        case settingsWithInterruptedCleanup
    }

    @Test(arguments: MissingOwnerCase.allCases)
    func `removing a pair with missing owner media cleans its own paired variants`(scenario: MissingOwnerCase) throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = VideoLibrary(documents: root)
        defer { try? fm.removeItem(at: root) }
        let owner = UUID().uuidString
        let counterpart = UUID().uuidString
        let original = try writeEntry(owner, in: library)
        let alternate = try writeEntry(counterpart, in: library)
        let directory = original.deletingLastPathComponent()
        let generation = UUID()
        let paired = directory.appendingPathComponent(".paired-variants-\(generation.uuidString)")
        let tierFiles = try ["original", "alternate"].map { side in
            let folder = paired.appendingPathComponent(side)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent("tier.mov")
            try Data([2]).write(to: url)
            return url
        }
        let unrelated = directory.appendingPathComponent("keep.mov")
        try Data([3]).write(to: unrelated)
        let pair = try AppearancePair(
            owner: owner, counterpart: counterpart, swapped: false, validation: validate(original, alternate),
            optimization: .init(generation: generation, tiers: [AppearancePair.Tier(
                fps: 12, resolution: CGSize(width: 1, height: 1), validation: validate(tierFiles[0], tierFiles[1]),
            )]),
        )
        try AppearancePair.update(in: library.videosDir) { $0 = [pair] }
        try fm.removeItem(at: original)
        switch scenario {
        case .library:
            try pair.remove(in: library.videosDir)
        case .settingsWithReplacement:
            try Data([4]).write(to: tierFiles[1], options: .atomic)
            try library.removeDownloadedChoice(counterpart, files: [alternate])
            #expect(try Data(contentsOf: tierFiles[1]) == Data([4]))
        case .settingsWithInterruptedCleanup:
            #expect(library.scan())
            try setImmutable(true, at: tierFiles[1])
            defer { try? setImmutable(false, at: tierFiles[1]) }
            #expect(throws: POSIXError(.EPERM)) { try library.removeDownloadedChoice(counterpart, files: [alternate]) }
            #expect(!fm.fileExists(atPath: tierFiles[0].path))
            #expect(FileIdentity(of: alternate) == pair.validation.alternate)
            #expect(try AppearancePair.read(in: library.videosDir) == [pair])
            #expect(library.choices.map(\.entry.id) == [counterpart])
            #expect(library.isChoiceDownloaded(counterpart))
            try setImmutable(false, at: tierFiles[1])
            try library.removeDownloadedChoice(counterpart, files: [alternate])
        }
        #expect(try AppearancePair.read(in: library.videosDir).isEmpty)
        #expect(!fm.fileExists(atPath: tierFiles[0].path))
        #expect(fm.fileExists(atPath: paired.path) == (scenario == .settingsWithReplacement))
        #expect(!fm.fileExists(atPath: alternate.path))
        #expect(try Data(contentsOf: unrelated) == Data([3]))
    }

    @Test(arguments: [false, true])
    func `a staging failure preserves the pair and allows an explicit retry`(secondMember: Bool) throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = VideoLibrary(documents: root)
        defer { try? fm.removeItem(at: root) }
        let owner = UUID().uuidString
        let counterpart = UUID().uuidString
        let original = try writeEntry(owner, in: library)
        let alternate = try writeEntry(counterpart, in: library)
        let validation = try validate(original, alternate)
        let pair = AppearancePair(owner: owner, counterpart: counterpart, swapped: false, validation: validation)
        try pair.merge(in: library.videosDir) { (original, alternate) }
        let blocked = (secondMember ? alternate : original).deletingLastPathComponent()
        try setImmutable(true, at: blocked)
        defer { try? setImmutable(false, at: blocked) }

        #expect(throws: POSIXError(.EPERM)) { try pair.remove(in: library.videosDir) }
        #expect(try AppearancePair.read(in: library.videosDir) == [pair])
        let restarted = VideoLibrary(documents: root)
        #expect(restarted.scan())
        #expect(restarted.pairRendition(for: owner) != nil)
        #expect(FileIdentity(of: original) == validation.original)
        #expect(FileIdentity(of: alternate) == validation.alternate)
        #expect(try !fm.contentsOfDirectory(atPath: library.videosDir.path).contains { $0.hasPrefix(".delete-") })

        try setImmutable(false, at: blocked)
        try pair.remove(in: library.videosDir)
        #expect(try AppearancePair.read(in: library.videosDir).isEmpty)
        #expect(!fm.fileExists(atPath: original.path))
        #expect(!fm.fileExists(atPath: alternate.path))
    }

    private func writeEntry(_ id: String, in library: VideoLibrary, variants: [VideoVariant]? = nil) throws -> URL {
        let directory = library.videosDir.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let entry = VideoEntry(id: id, name: "Sample", filename: "sample.mov", duration: 1, fps: 24, resolution: .zero, dateAdded: .now, variants: variants)
        let media = library.videoURL(for: entry)
        try Data([1]).write(to: media)
        try JSONEncoder().encode(entry).write(to: directory.appendingPathComponent("metadata.json"))
        return media
    }

    private func validate(_ original: URL, _ alternate: URL, fps: Int32 = 24) throws -> AppearancePair.Validation {
        try AppearancePair.Validation(
            original: #require(FileIdentity(of: original)),
            alternate: #require(FileIdentity(of: alternate)),
            frameTicks: 1, timescale: fps, frameCount: 1, commonSyncFrames: [0],
        )
    }

    private func setImmutable(_ immutable: Bool, at url: URL) throws {
        guard unsafe chflags(url.path, immutable ? UInt32(UF_IMMUTABLE) : 0) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
    }
}
