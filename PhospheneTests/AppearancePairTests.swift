import Foundation
import Testing

private final class PairFixtureBundle {}

struct AppearancePairTests {
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

    @Test(arguments: [false, true])
    func `confirmed deletion removes only the two library copies`(interrupted: Bool) throws {
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
        if interrupted {
            let pending = AppearancePair(owner: confirmed.owner, counterpart: confirmed.counterpart, swapped: true, validation: validation, deletionPending: true)
            try AppearancePair.update(in: library) { $0 = [pending] }
            try fm.removeItem(at: dirs[0])
            #expect(throws: PairIssue.changed) { try pending.edit(in: library, split: true) }
            try pending.finishDeletion(in: library)
        } else {
            try confirmed.remove(in: library)
        }
        #expect(try AppearancePair.read(in: library).isEmpty)
        #expect(!fm.fileExists(atPath: dirs[0].path))
        #expect(!fm.fileExists(atPath: dirs[1].path))
        #expect(try Data(contentsOf: files[2]) == Data(contentsOf: source))
    }
}
