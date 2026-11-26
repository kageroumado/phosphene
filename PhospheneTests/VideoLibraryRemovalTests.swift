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

    private func writeEntry(_ id: String, in library: VideoLibrary) throws -> URL {
        let directory = library.videosDir.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let entry = VideoEntry(id: id, name: "Sample", filename: "sample.mov", duration: 1, fps: 24, resolution: .zero, dateAdded: .now)
        let media = library.videoURL(for: entry)
        try Data([1]).write(to: media)
        try JSONEncoder().encode(entry).write(to: directory.appendingPathComponent("metadata.json"))
        return media
    }

    private func validate(_ original: URL, _ alternate: URL) throws -> AppearancePair.Validation {
        try AppearancePair.Validation(
            original: #require(FileIdentity(of: original)),
            alternate: #require(FileIdentity(of: alternate)),
            frameTicks: 1, timescale: 24, frameCount: 1, commonSyncFrames: [0],
        )
    }

    private func setImmutable(_ immutable: Bool, at url: URL) throws {
        guard unsafe chflags(url.path, immutable ? UInt32(UF_IMMUTABLE) : 0) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
    }
}
