import Foundation
import Testing

private final class PairFixtureBundle {}

struct AppearancePairTests {
    enum DeletionCase: CaseIterable {
        case complete
        case interrupted
        case replacedMedia
        case replacedDirectory
        case replacedStagedMedia
        case missingStagedMedia
        case restoreCollision
        case cleanupInterrupted
        case legacy
        case malformed
    }

    @Test
    func `merge swap split`() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try #require(Bundle(for: PairFixtureBundle.self).url(forResource: "ConstantFrameRate", withExtension: "mov"))
        let first = directory.appendingPathComponent("Day.mov")
        let second = directory.appendingPathComponent("Night.mov")
        try FileManager.default.copyItem(at: fixture, to: first)
        try FileManager.default.copyItem(at: fixture, to: second)
        let validation = try await PairEligibility.validate(first, second)
        #expect(validation.frameCount == 15)
        #expect(validation.commonSyncFrames == [0, 6, 12])
        #expect(validation.frameTicks * 24_000 == Int64(validation.timescale) * 1_001)

        let pair = AppearancePair(owner: UUID().uuidString, counterpart: UUID().uuidString, swapped: false, validation: validation)
        try pair.merge(in: directory) { (first, second) }
        #expect(try AppearancePair.read(in: directory) == [pair])
        #expect(throws: PairIssue.alreadyPaired) { try pair.merge(in: directory) { (first, second) } }
        #expect(throws: PairIssue.alreadyPaired) { try AppearancePair.requireSingle(pair.counterpart, in: directory) }
        try pair.edit(in: directory, split: false)
        let swapped = try #require(AppearancePair.read(in: directory).first)
        #expect(swapped.light == pair.counterpart && swapped.dark == pair.owner)
        #expect(throws: PairIssue.changed) { try pair.edit(in: directory, split: true) }
        try swapped.edit(in: directory, split: true)
        #expect(try AppearancePair.read(in: directory).isEmpty)
        #expect(FileIdentity(of: first) == validation.original)
        #expect(FileIdentity(of: second) == validation.alternate)

        try Data([1]).write(to: second, options: .atomic)
        #expect(throws: PairIssue.changed) { try pair.merge(in: directory) { (first, second) } }
        #expect(try AppearancePair.read(in: directory).isEmpty)
    }

    @Test(arguments: DeletionCase.allCases)
    func `pair deletion resumes only for confirmed members`(scenario: DeletionCase) throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = root.appendingPathComponent("videos")
        let ids = (0 ..< 3).map { _ in UUID().uuidString }
        let dirs = ids.map { library.appendingPathComponent($0) }
        let files = dirs.map { $0.appendingPathComponent("sample.mov") }
        defer { try? fm.removeItem(at: root) }
        for dir in dirs {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let source = root.appendingPathComponent("source.mov")
        try Data([1, 2, 3]).write(to: source)
        for file in files {
            try fm.copyItem(at: source, to: file)
        }
        let validation = try AppearancePair.Validation(
            original: #require(FileIdentity(of: files[0])),
            alternate: #require(FileIdentity(of: files[1])),
            frameTicks: 1,
            timescale: 24,
            frameCount: 1,
            commonSyncFrames: [0],
        )
        let original = AppearancePair(owner: ids[0], counterpart: ids[1], swapped: false, validation: validation)
        try original.merge(in: library) { (files[0], files[1]) }
        try original.edit(in: library, split: false)
        #expect(throws: PairIssue.changed) { try original.remove(in: library) }
        #expect(files.allSatisfy { fm.fileExists(atPath: $0.path) })

        let confirmed = try #require(AppearancePair.read(in: library).first)
        switch scenario {
        case .complete:
            try confirmed.remove(in: library)
        case .legacy:
            let pending = AppearancePair(owner: confirmed.owner, counterpart: confirmed.counterpart, swapped: true, validation: validation, deletionPending: true)
            try AppearancePair.update(in: library) { $0 = [pending] }
            try fm.removeItem(at: dirs[0])
            try pending.finishDeletion(in: library)
            #expect(FileIdentity(of: files[1]) == validation.alternate)
        case .cleanupInterrupted:
            try retryCommittedCleanup(of: confirmed, in: library, replacing: files[1], with: source)
        default:
            try recoverUncommittedDeletion(scenario, of: confirmed, in: root, unrelatedID: ids[2])
            #expect(try Data(contentsOf: files[2]) == Data(contentsOf: source))
            return
        }
        #expect(try AppearancePair.read(in: library).isEmpty)
        #expect(!fm.fileExists(atPath: dirs[0].path))
        #expect(fm.fileExists(atPath: dirs[1].path) == (scenario != .complete))
        #expect(try Data(contentsOf: files[2]) == Data(contentsOf: source))
    }

    private func retryCommittedCleanup(
        of confirmed: AppearancePair, in library: URL, replacing media: URL, with source: URL,
    ) throws {
        let fm = FileManager.default
        let folder = media.deletingLastPathComponent()
        try setImmutable(true, at: media)
        defer {
            try? setImmutable(false, at: media)
            for directory in (try? fm.contentsOfDirectory(at: library, includingPropertiesForKeys: nil)) ?? []
                where directory.lastPathComponent.hasPrefix(".delete-") {
                try? setImmutable(false, at: directory.appendingPathComponent("sample.mov"))
            }
        }
        #expect(throws: (any Error).self) { try confirmed.remove(in: library) }
        let pending = try #require(AppearancePair.read(in: library).first)
        #expect(pending.deletionPending == true)
        #expect(!fm.fileExists(atPath: folder.path))
        let staged = try #require(fm.contentsOfDirectory(at: library, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasSuffix(confirmed.counterpart) })
        let stagedMedia = staged.appendingPathComponent("sample.mov")
        #expect(FileIdentity(of: stagedMedia) == confirmed.validation.alternate)
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        try fm.copyItem(at: source, to: media)
        let replacement = try #require(FileIdentity(of: media))
        #expect(replacement.inode != confirmed.validation.alternate.inode)
        try setImmutable(false, at: stagedMedia)
        try pending.finishDeletion(in: library)
        #expect(FileIdentity(of: media) == replacement)
        #expect(!fm.fileExists(atPath: staged.path))
    }

    private func recoverUncommittedDeletion(
        _ scenario: DeletionCase, of confirmed: AppearancePair, in root: URL, unrelatedID: String,
    ) throws {
        let fm = FileManager.default
        let library = root.appendingPathComponent("videos")
        let ids = [confirmed.owner, confirmed.counterpart]
        let dirs = ids.map { library.appendingPathComponent($0) }
        let files = dirs.map { $0.appendingPathComponent("sample.mov") }
        let validation = confirmed.validation
        // Simulate an exit after the first rename and before the deletion commit.
        let token = UUID()
        let staged = library.appendingPathComponent(".delete-\(token.uuidString)-\(ids[0])")
        try persistUncommittedDeletion(of: confirmed, in: library, token: token, unrelatedID: scenario == .malformed ? unrelatedID : nil)
        try fm.moveItem(at: dirs[0], to: staged)
        let stagedAttributes = try fm.attributesOfItem(atPath: staged.path)
        let stagedInode = try #require(stagedAttributes[.systemFileNumber] as? NSNumber)
        let pending = try #require(AppearancePair.read(in: library).first)
        #expect(pending.deletionPending == true)
        #expect(throws: PairIssue.changed) { try pending.edit(in: library, split: true) }
        let stagedMedia = staged.appendingPathComponent("sample.mov")

        switch scenario {
        case .replacedMedia:
            try Data([1, 2, 3]).write(to: files[1], options: .atomic)
            #expect(FileIdentity(of: files[1])?.inode != validation.alternate.inode)
        case .replacedDirectory:
            let retired = root.appendingPathComponent("retired")
            try fm.moveItem(at: dirs[1], to: retired)
            try fm.createDirectory(at: dirs[1], withIntermediateDirectories: false)
            try fm.linkItem(at: retired.appendingPathComponent("sample.mov"), to: files[1])
            #expect(FileIdentity(of: files[1]) == validation.alternate)
        case .replacedStagedMedia:
            try Data([9]).write(to: stagedMedia, options: .atomic)
        case .missingStagedMedia:
            try fm.removeItem(at: stagedMedia)
        case .restoreCollision:
            try fm.createDirectory(at: dirs[0], withIntermediateDirectories: false)
            try Data([9]).write(to: files[0])
            #expect(throws: POSIXError(.EEXIST)) { try pending.finishDeletion(in: library) }
            #expect(try Data(contentsOf: files[0]) == Data([9]))
            #expect(FileIdentity(of: stagedMedia) == validation.original)
            #expect(try AppearancePair.read(in: library) == [pending])
            try fm.moveItem(at: dirs[0], to: root.appendingPathComponent("replacement"))
        default: break
        }

        let alias = root.appendingPathComponent("alias")
        try fm.createSymbolicLink(at: alias, withDestinationURL: library)
        if scenario == .malformed {
            #expect(throws: CocoaError(.fileReadCorruptFile)) { try pending.finishDeletion(in: alias) }
            #expect(fm.fileExists(atPath: staged.path))
            #expect(try AppearancePair.read(in: library) == [pending])
        } else {
            let stagedIdentity = FileIdentity(of: stagedMedia)
            let alternateIdentity = FileIdentity(of: files[1])
            try pending.finishDeletion(in: alias)
            try pending.finishDeletion(in: alias)
            #expect(!fm.fileExists(atPath: staged.path))
            #expect(fm.fileExists(atPath: dirs[0].path))
            let restoredAttributes = try fm.attributesOfItem(atPath: dirs[0].path)
            #expect(restoredAttributes[.systemFileNumber] as? NSNumber == stagedInode)
            #expect(FileIdentity(of: files[0]) == stagedIdentity)
            #expect(FileIdentity(of: files[1]) == alternateIdentity)
            #expect(try AppearancePair.read(in: library) == [confirmed])
        }
    }

    private func persistUncommittedDeletion(
        of pair: AppearancePair, in library: URL, token: UUID, unrelatedID: String?,
    ) throws {
        let fm = FileManager.default
        let ids = [pair.owner, pair.counterpart]
        let dirs = ids.map { library.appendingPathComponent($0) }
        let validation = pair.validation
        let manifest = library.appendingPathComponent(".appearance-pairs.json")
        var records = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [[String: Any]])
        var members: [String: [String: Any]] = [:]
        for (index, media) in [validation.original, validation.alternate].enumerated() {
            let attributes = try fm.attributesOfItem(atPath: dirs[index].path)
            members[ids[index]] = try [
                "device": #require(attributes[.systemNumber]),
                "inode": #require(attributes[.systemFileNumber]),
                "media": JSONSerialization.jsonObject(with: JSONEncoder().encode(media)),
            ]
        }
        if let unrelatedID {
            members[unrelatedID] = members.removeValue(forKey: ids[1])
        }
        records[0]["deletionPending"] = true
        records[0]["deletion"] = ["token": token.uuidString, "members": members, "split": false, "detached": false]
        try JSONSerialization.data(withJSONObject: records).write(to: manifest)
    }

    @Test
    func `removing an incomplete pair detaches its confirmed survivor`() throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: directory) }
        let ids = [UUID().uuidString, UUID().uuidString]
        let folders = ids.map { directory.appendingPathComponent($0) }
        for folder in folders {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let first = folders[0].appendingPathComponent("Day.mov")
        let second = folders[1].appendingPathComponent("Night.mov")
        try Data([1]).write(to: first)
        try Data([2]).write(to: second)
        let validation = try AppearancePair.Validation(
            original: #require(FileIdentity(of: first)),
            alternate: #require(FileIdentity(of: second)),
            frameTicks: 1,
            timescale: 24,
            frameCount: 1,
            commonSyncFrames: [0],
        )
        let pair = AppearancePair(owner: ids[0], counterpart: ids[1], swapped: false, validation: validation)
        try pair.merge(in: directory) { (first, second) }
        try fm.removeItem(at: folders[0])
        try AppearancePair.withLibraryLock(in: directory) {
            try pair.removeDegradedWhileLocked(pair.counterpart, media: validation.alternate, in: directory, pairs: AppearancePair.read(in: directory))
            try AppearancePair.requireSingle(pair.counterpart, in: directory)
            #expect(!fm.fileExists(atPath: folders[1].path))
        }
    }

    private func setImmutable(_ immutable: Bool, at url: URL) throws {
        guard unsafe chflags(url.path, immutable ? UInt32(UF_IMMUTABLE) : 0) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
    }
}
