import Foundation
import Testing

struct CachedFrameTests {
    @Test
    func `metadata migration preserves and adopts a legacy still`() async throws {
        let fixture = try LegacyStill()
        defer { fixture.remove() }
        let metadata = fixture.entry.appendingPathComponent("metadata.json")
        try await Task.sleep(for: .milliseconds(2))
        LegacyStillProvenance.preserve(for: fixture.original)
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
    func `staged media cannot adopt a stale still after a metadata rewrite`(marked: Bool) async throws {
        let fixture = try LegacyStill { staged in
            try Data([2]).write(to: staged.appendingPathComponent("video.mov"))
            if marked {
                try Data().write(to: staged.appendingPathComponent(LegacyStillProvenance.replacementMarker))
            }
        }
        defer { fixture.remove() }
        try await Task.sleep(for: .milliseconds(2))
        try fixture.publishStagedEntry()
        LegacyStillProvenance.preserve(for: fixture.original)
        try Data("{}".utf8).write(to: fixture.entry.appendingPathComponent("metadata.json"), options: .atomic)

        let replacement = try #require(FileIdentity(of: fixture.original))
        #expect(fixture.lookup(source: replacement) == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.record.path))
        try fixture.writeRecord(source: replacement, legacy: true)
        #expect(fixture.lookup(source: replacement) == nil)
    }

    @Test
    func `untracked directory and metadata writes cannot establish a legacy source`() async throws {
        let fixture = try LegacyStill { staged in
            try Data([2]).write(to: staged.appendingPathComponent("video.mov"))
        }
        defer { fixture.remove() }
        try await Task.sleep(for: .milliseconds(2))
        try fixture.publishStagedEntry()
        try Data("{}".utf8).write(to: fixture.entry.appendingPathComponent("metadata.json"), options: .atomic)
        let replacement = try #require(FileIdentity(of: fixture.original))
        #expect(fixture.lookup(source: replacement) == nil)
    }

    @Test(arguments: [false, true])
    func `adding or removing variants preserves the original still before first lookup`(addVariant: Bool) async throws {
        let fixture = try LegacyStill(hasVariant: !addVariant)
        defer { fixture.remove() }
        let fm = FileManager.default
        try await Task.sleep(for: .milliseconds(2))
        LegacyStillProvenance.preserve(for: fixture.original)
        for file in [fixture.original, fixture.provenance] {
            try fm.linkItem(at: file, to: fixture.staged.appendingPathComponent(file.lastPathComponent))
        }
        if addVariant {
            try Data([2]).write(to: fixture.staged.appendingPathComponent(LegacyStill.variantName))
        }
        try Data("{}".utf8).write(to: fixture.staged.appendingPathComponent("metadata.json"))
        try fixture.publishStagedEntry()
        try fm.removeItem(at: fixture.staged)
        #expect(FileIdentity(of: fixture.original) == fixture.source)
        #expect(fm.fileExists(atPath: fixture.entry.appendingPathComponent(LegacyStill.variantName).path) == addVariant)

        // A later write cannot extend the original window of reliable timestamps.
        try Data().write(to: fixture.directory.appendingPathComponent(LegacyStill.stillName()))
        LegacyStillProvenance.preserve(for: fixture.original)
        #expect(fixture.lookup(source: fixture.source)?.path == fixture.bmp.path)
    }

    @Test
    func `a stale identity record blocks legacy fallback`() throws {
        let fixture = try LegacyStill { staged in
            try Data([2]).write(to: staged.appendingPathComponent("video.mov"))
        }
        defer { fixture.remove() }
        let stale = try #require(FileIdentity(of: fixture.staged.appendingPathComponent("video.mov")))
        try fixture.writeRecord(source: stale)
        #expect(fixture.lookup(source: fixture.source) == nil)
        #expect(try JSONDecoder().decode(CachedFrame.self, from: Data(contentsOf: fixture.record)).source == stale)
    }

    @Test
    func `cache rejects symlinked provenance records and images`() throws {
        let fixture = try LegacyStill()
        defer { fixture.remove() }
        let fm = FileManager.default
        LegacyStillProvenance.preserve(for: fixture.original)
        let saved = fixture.directory.appendingPathComponent("saved.json")
        try fm.moveItem(at: fixture.provenance, to: saved)
        try fm.createSymbolicLink(at: fixture.provenance, withDestinationURL: saved)
        #expect(fixture.lookup(source: fixture.source) == nil)

        try fixture.writeRecord(source: fixture.source)
        let record = fixture.directory.appendingPathComponent("record.json")
        try fm.moveItem(at: fixture.record, to: record)
        try fm.createSymbolicLink(at: fixture.record, withDestinationURL: record)
        #expect(fixture.lookup(source: fixture.source, legacy: false) == nil)
        try fm.removeItem(at: fixture.record)
        try fm.moveItem(at: record, to: fixture.record)

        let image = fixture.directory.appendingPathComponent("image.bmp")
        try fm.moveItem(at: fixture.bmp, to: image)
        try fm.createSymbolicLink(at: fixture.bmp, withDestinationURL: image)
        #expect(fixture.lookup(source: fixture.source, legacy: false) == nil)
    }

    @Test
    func `legacy provenance requires a regular original in a real entry directory`() throws {
        let fixture = try LegacyStill()
        defer { fixture.remove() }
        let fm = FileManager.default
        LegacyStillProvenance.preserve(for: fixture.original)
        let movedEntry = fixture.directory.appendingPathComponent("moved")
        try fm.moveItem(at: fixture.entry, to: movedEntry)
        try fm.createSymbolicLink(at: fixture.entry, withDestinationURL: movedEntry)
        #expect(fixture.lookup(source: fixture.source) == nil)
        try fm.removeItem(at: fixture.entry)
        try fm.moveItem(at: movedEntry, to: fixture.entry)

        let target = fixture.entry.appendingPathComponent("target.mov")
        try fm.moveItem(at: fixture.original, to: target)
        try fm.createSymbolicLink(at: fixture.original, withDestinationURL: target)
        #expect(fixture.lookup(source: fixture.source) == nil)
    }

    private struct LegacyStill {
        static let variantName = "variant_15fps.mp4"
        let directory: URL
        let source: FileIdentity
        let bmp: URL
        var entry: URL {
            directory.appendingPathComponent("entry")
        }
        var staged: URL {
            directory.appendingPathComponent("staged")
        }
        var original: URL {
            entry.appendingPathComponent("video.mov")
        }
        var provenance: URL {
            entry.appendingPathComponent(LegacyStillProvenance.filename)
        }
        var record: URL {
            CachedFrame.recordURL(CachedFrame.prefix("A", 64, 48), in: directory)
        }

        static func stillName() -> String {
            let timestamp = String(format: "%016llx", Date.timeIntervalSinceReferenceDate.bitPattern)
            return CachedFrame.prefix("A", 64, 48) + timestamp + ".bmp"
        }

        init(hasVariant: Bool = false, stage: (URL) throws -> Void = { _ in }) throws {
            let fm = FileManager.default
            let directory = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let entry = directory.appendingPathComponent("entry")
            let staged = directory.appendingPathComponent("staged")
            let original = entry.appendingPathComponent("video.mov")
            try fm.createDirectory(at: entry, withIntermediateDirectories: true)
            do {
                try Data([1]).write(to: original)
                if hasVariant {
                    try Data([2]).write(to: entry.appendingPathComponent(Self.variantName))
                }
                try Data("{\"name\":\"old\"}".utf8).write(to: entry.appendingPathComponent("metadata.json"))
                try fm.createDirectory(at: staged, withIntermediateDirectories: false)
                try stage(staged)
                self.directory = directory
                source = try #require(FileIdentity(of: original))
                bmp = directory.appendingPathComponent(Self.stillName())
                try Data().write(to: bmp)
            } catch {
                try? fm.removeItem(at: directory)
                throw error
            }
        }

        func remove() {
            try? FileManager.default.removeItem(at: directory)
        }

        func publishStagedEntry() throws {
            let result = unsafe renamex_np(staged.path, entry.path, UInt32(RENAME_SWAP))
            try #require(result == 0)
        }

        func writeRecord(source: FileIdentity, legacy: Bool? = nil) throws {
            let frame = CachedFrame(choice: "A", source: source, width: 64, height: 48, filename: bmp.lastPathComponent, legacyOriginalOnly: legacy)
            try JSONEncoder().encode(frame).write(to: record)
        }

        func lookup(source: FileIdentity, legacy: Bool = true) -> URL? {
            CachedFrame.lookup(
                choice: "A", source: source, width: 64, height: 48, directory: directory,
                legacyOriginal: legacy ? original : nil, recordsDirectory: directory,
            )
        }
    }
}
