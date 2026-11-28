import Foundation

nonisolated struct LegacyStillProvenance: Codable {
    static let filename = ".legacy-still-source.json"
    static let replacementMarker = ".media-replaced"

    private let source: FileIdentity
    private let entryName: String
    private let changed: Date
    private let observed: Date

    func contains(_ timestamp: Double) -> Bool {
        timestamp > changed.timeIntervalSinceReferenceDate && timestamp <= observed.timeIntervalSinceReferenceDate
    }

    static func read(for original: URL, source: FileIdentity) -> Self? {
        try? inspect(original, source: source).provenance
    }

    /// Call under the library lock before editing the entry or hard-linking the original.
    static func preserve(for original: URL) {
        guard let source = FileIdentity(of: original), let evidence = try? inspect(original, source: source),
              !evidence.saved else { return }
        let url = original.deletingLastPathComponent().appendingPathComponent(filename)
        try? JSONEncoder().encode(evidence.provenance).write(to: url, options: .atomic)
    }

    private static func inspect(_ original: URL, source: FileIdentity) throws -> (provenance: Self, saved: Bool) {
        let observed = Date()
        let original = URL(fileURLWithPath: original.path)
        let entry = original.deletingLastPathComponent()
        guard try itemType(at: entry) == .typeDirectory, try itemType(at: original) == .typeRegular,
              FileIdentity(of: original) == source, try itemType(at: entry.appendingPathComponent(replacementMarker)) == nil else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let url = entry.appendingPathComponent(filename)
        if let type = try itemType(at: url) {
            guard type == .typeRegular else { throw CocoaError(.fileReadCorruptFile) }
            let saved = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
            guard saved.source == source, saved.entryName == entry.lastPathComponent, saved.observed <= observed else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return (saved, true)
        }

        // Directory ctime bounds a swap that could have published an older staged video.
        let values = try original.resourceValues(forKeys: [.attributeModificationDateKey, .creationDateKey])
        let entryValues = try entry.resourceValues(forKeys: [.attributeModificationDateKey])
        guard let changed = values.attributeModificationDate, let created = values.creationDate,
              let entryChanged = entryValues.attributeModificationDate, FileIdentity(of: original) == source else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return (Self(source: source, entryName: entry.lastPathComponent, changed: max(changed, created, entryChanged, source.modified), observed: observed), false)
    }

    private static func itemType(at url: URL) throws -> FileAttributeType? {
        do {
            return try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return nil
        }
    }
}
