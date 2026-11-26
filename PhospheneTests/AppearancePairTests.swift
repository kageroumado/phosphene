import Foundation
import Testing

private final class PairFixtureBundle {}

struct AppearancePairTests {
    enum DeletionCase: CaseIterable {
        case complete
        case interrupted
        case replacedMedia
        case replacedDirectory
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
            try setImmutable(true, at: files[1])
            defer {
                try? setImmutable(false, at: files[1])
                for directory in (try? fm.contentsOfDirectory(at: library, includingPropertiesForKeys: nil)) ?? []
                    where directory.lastPathComponent.hasPrefix(".delete-") {
                    try? setImmutable(false, at: directory.appendingPathComponent("sample.mov"))
                }
            }
            #expect(throws: (any Error).self) { try confirmed.remove(in: library) }
            let pending = try #require(AppearancePair.read(in: library).first)
            #expect(pending.deletionPending == true)
            #expect(!fm.fileExists(atPath: dirs[1].path))
            let staged = try #require(fm.contentsOfDirectory(at: library, includingPropertiesForKeys: nil)
                .first { $0.lastPathComponent.hasSuffix(ids[1]) })
            let stagedMedia = staged.appendingPathComponent("sample.mov")
            #expect(FileIdentity(of: stagedMedia) == validation.alternate)
            try fm.createDirectory(at: dirs[1], withIntermediateDirectories: false)
            try fm.copyItem(at: source, to: files[1])
            let replacement = try #require(FileIdentity(of: files[1]))
            #expect(replacement.inode != validation.alternate.inode)
            try setImmutable(false, at: stagedMedia)
            try pending.finishDeletion(in: library)
            #expect(FileIdentity(of: files[1]) == replacement)
            #expect(!fm.fileExists(atPath: staged.path))
        default:
            try setImmutable(true, at: dirs[1])
            defer { try? setImmutable(false, at: dirs[1]) }
            #expect(throws: POSIXError(.EPERM)) { try confirmed.remove(in: library) }
            let pending = try #require(AppearancePair.read(in: library).first)
            #expect(pending.deletionPending == true)
            #expect(throws: PairIssue.changed) { try pending.edit(in: library, split: true) }
            let staged = try #require(fm.contentsOfDirectory(at: library, includingPropertiesForKeys: nil)
                .first { $0.lastPathComponent.hasPrefix(".delete-") })
            #expect(FileIdentity(of: staged.appendingPathComponent("sample.mov")) == validation.original)
            #expect(!fm.fileExists(atPath: dirs[0].path))
            #expect(FileIdentity(of: files[1]) == validation.alternate)
            try setImmutable(false, at: dirs[1])

            switch scenario {
            case .replacedMedia, .malformed:
                try Data([1, 2, 3]).write(to: files[1], options: .atomic)
                #expect(FileIdentity(of: files[1])?.inode != validation.alternate.inode)
            case .replacedDirectory:
                let retired = root.appendingPathComponent("retired")
                try fm.moveItem(at: dirs[1], to: retired)
                try fm.createDirectory(at: dirs[1], withIntermediateDirectories: false)
                try fm.linkItem(at: retired.appendingPathComponent("sample.mov"), to: files[1])
                #expect(FileIdentity(of: files[1]) == validation.alternate)
            default: break
            }

            let alias = root.appendingPathComponent("alias")
            try fm.createSymbolicLink(at: alias, withDestinationURL: library)
            if scenario == .malformed {
                let manifest = library.appendingPathComponent(".appearance-pairs.json")
                var records = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [[String: Any]])
                var deletion = try #require(records[0]["deletion"] as? [String: Any])
                let members = try #require(deletion["members"] as? [String: Any])
                deletion["members"] = try [ids[2]: #require(members[ids[1]])]
                records[0]["deletion"] = deletion
                try JSONSerialization.data(withJSONObject: records).write(to: manifest)
                let malformed = try #require(AppearancePair.read(in: library).first)
                #expect(throws: CocoaError(.fileReadCorruptFile)) { try malformed.finishDeletion(in: alias) }
                #expect(fm.fileExists(atPath: staged.path))
            } else {
                try pending.finishDeletion(in: alias)
                try pending.finishDeletion(in: alias)
                #expect(!fm.fileExists(atPath: staged.path))
            }
        }
        #expect(try AppearancePair.read(in: library).isEmpty == (scenario != .malformed))
        #expect(!fm.fileExists(atPath: dirs[0].path))
        #expect(fm.fileExists(atPath: dirs[1].path) == (scenario != .complete && scenario != .interrupted))
        #expect(try Data(contentsOf: files[2]) == Data(contentsOf: source))
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
