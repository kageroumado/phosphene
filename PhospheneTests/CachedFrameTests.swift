import Foundation
import Testing

struct CachedFrameTests {
    @Test
    func `metadata migration preserves and adopts a legacy still`() async throws {
        let fixture = try LegacyStill()
        defer { fixture.remove() }
        let metadata = fixture.entry.appendingPathComponent("metadata.json")
        try await Task.sleep(for: .milliseconds(2))
        try Data("{}".utf8).write(to: metadata, options: .atomic)

        #expect(fixture.lookup(source: fixture.source)?.path == fixture.bmp.path)
        let adopted = try JSONDecoder().decode(CachedFrame.self, from: Data(contentsOf: fixture.record))
        #expect(adopted.source == fixture.source)
        #expect(adopted.filename == fixture.bmp.lastPathComponent)
        #expect(fixture.lookup(source: fixture.source, legacy: false) == nil)

        try Data([2]).write(to: fixture.original, options: .atomic)
        let replacement = try #require(FileIdentity(of: fixture.original))
        #expect(fixture.lookup(source: fixture.source) == nil)
        #expect(fixture.lookup(source: replacement) == nil)
    }

    @Test(arguments: [false, true])
    func `staged media published after a legacy still cannot adopt it`(migrateMetadata: Bool) async throws {
        let fixture = try LegacyStill { staged in
            try Data([2]).write(to: staged.appendingPathComponent("video.mov"))
            if migrateMetadata {
                try Data().write(to: staged.appendingPathComponent(".media-replaced"))
            }
        }
        defer { fixture.remove() }
        try await Task.sleep(for: .milliseconds(2))
        let result = unsafe renamex_np(fixture.staged.path, fixture.entry.path, UInt32(RENAME_SWAP))
        try #require(result == 0)
        if migrateMetadata {
            try Data("{}".utf8).write(to: fixture.entry.appendingPathComponent("metadata.json"), options: .atomic)
        }

        let replacement = try #require(FileIdentity(of: fixture.original))
        #expect(fixture.lookup(source: replacement) == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.record.path))
    }

    private struct LegacyStill {
        let directory: URL
        let source: FileIdentity
        let bmp: URL
        var entry: URL { directory.appendingPathComponent("entry") }
        var staged: URL { directory.appendingPathComponent("staged") }
        var original: URL { entry.appendingPathComponent("video.mov") }
        var record: URL { CachedFrame.recordURL(CachedFrame.prefix("A", 64, 48), in: directory) }

        init(stage: (URL) throws -> Void = { _ in }) throws {
            let fm = FileManager.default
            let directory = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let entry = directory.appendingPathComponent("entry")
            let staged = directory.appendingPathComponent("staged")
            let original = entry.appendingPathComponent("video.mov")
            try fm.createDirectory(at: entry, withIntermediateDirectories: true)
            do {
                try Data([1]).write(to: original)
                try Data("{\"name\":\"old\"}".utf8).write(to: entry.appendingPathComponent("metadata.json"))
                try fm.createDirectory(at: staged, withIntermediateDirectories: false)
                try stage(staged)
                self.directory = directory
                source = try #require(FileIdentity(of: original))
                let timestamp = String(format: "%016llx", Date.timeIntervalSinceReferenceDate.bitPattern)
                bmp = directory.appendingPathComponent(CachedFrame.prefix("A", 64, 48) + timestamp + ".bmp")
                try Data().write(to: bmp)
            } catch {
                try? fm.removeItem(at: directory)
                throw error
            }
        }

        func remove() {
            try? FileManager.default.removeItem(at: directory)
        }

        func lookup(source: FileIdentity, legacy: Bool = true) -> URL? {
            CachedFrame.lookup(
                choice: "A", source: source, width: 64, height: 48, directory: directory,
                legacyOriginal: legacy ? original : nil, recordsDirectory: directory,
            )
        }
    }
}
