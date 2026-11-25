import CryptoKit
import Foundation

struct CachedFrame: Codable {
    let choice: String
    let source: FileIdentity
    let width: Int
    let height: Int
    let filename: String

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
        do {
            let data = try Data(contentsOf: recordURL(prefix, in: recordsDirectory))
            let record = try JSONDecoder().decode(Self.self, from: data)
            return record.imageURL(choice: choice, source: source, width: width, height: height, directory: directory)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            guard let legacyOriginal else { return nil }
            return legacyImage(prefix: prefix, source: source, original: legacyOriginal, directory: directory)
        } catch {
            return nil
        }
    }

    private static func legacyImage(prefix: String, source: FileIdentity, original: URL, directory: URL) -> URL? {
        // Legacy filenames carry a choice, dimensions and write time, but no source identity.
        let original = URL(fileURLWithPath: original.path)
        let entryDirectory = original.deletingLastPathComponent()
        guard FileIdentity(of: original) == source,
              let values = try? original.resourceValues(forKeys: [.attributeModificationDateKey, .creationDateKey]),
              let changed = values.attributeModificationDate, let created = values.creationDate,
              let entryChanged = try? entryDirectory.resourceValues(forKeys: [.attributeModificationDateKey]).attributeModificationDate,
              let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return nil }
        // Replacing the whole entry directory can publish a video copied before the still was written.
        let earliest = max(changed, created, entryChanged, source.modified).timeIntervalSinceReferenceDate
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
