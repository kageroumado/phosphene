import Foundation

/// Which file a path names right now: its inode and modification date, which a
/// replacement under the same name changes.
nonisolated struct FileIdentity: Codable, Equatable, Sendable {
    let basename: String
    let size: UInt64
    let inode: UInt64
    let modified: Date

    init?(of url: URL) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        self.init(basename: url.lastPathComponent, attributes: attributes)
    }

    init?(basename: String, attributes: [FileAttributeKey: Any]) {
        guard let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
              let size = (attributes[.size] as? NSNumber)?.uint64Value,
              let modified = attributes[.modificationDate] as? Date
        else { return nil }
        self.basename = basename
        self.size = size
        self.inode = inode
        self.modified = modified
    }
}
