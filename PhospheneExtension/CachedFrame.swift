import CryptoKit
import Foundation

struct CachedFrame: Codable {
    let choice: String
    let source: FileIdentity
    let width: Int
    let height: Int
    let filename: String
    var legacyOriginalOnly: Bool?

    static func prefix(_ choice: String, _ width: Int, _ height: Int) -> String {
        "\(SHA256.hash(data: Data(choice.utf8)).map { String(format: "%02x", $0) }.joined())-\(width)-\(height)-0-"
    }

    static func recordURL(_ prefix: String, in directory: URL = .cachesDirectory) -> URL {
        directory.appendingPathComponent("snapshot-" + prefix + "frame.json")
    }

    static func lookup(
        choice: String, source: FileIdentity, width: Int, height: Int, directory: URL,
        legacyOriginal: URL? = nil, recordsDirectory: URL = .cachesDirectory,
    ) -> URL? {
        let prefix = prefix(choice, width, height)
        let recordURL = recordURL(prefix, in: recordsDirectory)
        func recordedImage() throws -> URL? {
            let data = try Data(contentsOf: recordURL)
            let record = try JSONDecoder().decode(Self.self, from: data)
            if record.legacyOriginalOnly == true {
                guard let legacyOriginal, FileIdentity(of: legacyOriginal) == source else { return nil }
            }
            return record.imageURL(choice: choice, source: source, width: width, height: height, directory: directory)
        }
        do {
            return try recordedImage()
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            guard let legacyOriginal,
                  let image = legacyImage(prefix: prefix, source: source, original: legacyOriginal, directory: directory),
                  FileIdentity(of: legacyOriginal) == source else { return nil }
            let record = Self(choice: choice, source: source, width: width, height: height, filename: image.lastPathComponent, legacyOriginalOnly: true)
            try? record.adopt(at: recordURL)
            do {
                return try recordedImage()
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                return FileIdentity(of: legacyOriginal) == source ? image : nil
            } catch {
                return nil
            }
        } catch {
            return nil
        }
    }

    private func adopt(at url: URL) throws {
        let fm = FileManager.default
        let directory = url.deletingLastPathComponent()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let staging = directory.appendingPathComponent(".snapshot-" + UUID().uuidString)
        defer { try? fm.removeItem(at: staging) }
        try JSONEncoder().encode(self).write(to: staging, options: .withoutOverwriting)
        // Publish a complete record without overwriting a still generated in parallel.
        try fm.linkItem(at: staging, to: url)
    }

    private static func legacyImage(prefix: String, source: FileIdentity, original: URL, directory: URL) -> URL? {
        // Legacy filenames carry a choice, dimensions and write time, but no source identity.
        let original = URL(fileURLWithPath: original.path)
        let entryDirectory = original.deletingLastPathComponent()
        let fm = FileManager.default
        guard !fm.fileExists(atPath: entryDirectory.appendingPathComponent(".media-replaced").path),
              FileIdentity(of: original) == source,
              let values = try? original.resourceValues(forKeys: [.attributeModificationDateKey, .creationDateKey]),
              let changed = values.attributeModificationDate, let created = values.creationDate,
              let entry = try? entryDirectory.resourceValues(forKeys: [.attributeModificationDateKey, .contentModificationDateKey, .creationDateKey]),
              let entryChanged = entry.attributeModificationDate, let entryModified = entry.contentModificationDate,
              let entryCreated = entry.creationDate,
              let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return nil }
        // APFS updates both directory times on a contents edit such as an atomic metadata write.
        // A directory swap updates ctime alone and can publish media staged before the still.
        let entryPublished = entryChanged > entryModified ? entryChanged : entryCreated
        let earliest = max(changed, created, entryPublished, source.modified).timeIntervalSinceReferenceDate
        let latest = Date.timeIntervalSinceReferenceDate
        return files.compactMap { file -> (url: URL, timestamp: Double)? in
            let name = file.lastPathComponent
            let stamp = name.dropFirst(prefix.count).dropLast(4)
            guard name.hasPrefix(prefix), name.hasSuffix(".bmp"), stamp.count == 16,
                  let bits = UInt64(stamp, radix: 16), PathSafety.isItem(at: file, ofType: .typeRegular) else { return nil }
            let timestamp = Double(bitPattern: bits)
            guard timestamp > earliest, timestamp <= latest else { return nil }
            return (file, timestamp)
        }.max(by: { $0.timestamp < $1.timestamp })?.url
    }

    func imageURL(choice: String, source: FileIdentity, width: Int, height: Int, directory: URL) -> URL? {
        guard self.source == source, self.choice == choice, self.width == width, self.height == height,
              PathSafety.isSafeComponent(filename), filename.hasPrefix(Self.prefix(choice, width, height)), filename.hasSuffix(".bmp") else { return nil }
        let url = directory.appendingPathComponent(filename)
        return PathSafety.contained(url, in: directory) && FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}
