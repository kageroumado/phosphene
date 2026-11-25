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
            guard try FileManager.default.attributesOfItem(atPath: recordURL.path)[.type] as? FileAttributeType == .typeRegular else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let data = try Data(contentsOf: recordURL)
            let record = try JSONDecoder().decode(Self.self, from: data)
            if record.legacyOriginalOnly == true {
                guard let legacyOriginal, let timestamp = legacyTimestamp(record.filename, prefix: prefix),
                      LegacyStillProvenance.read(for: legacyOriginal, source: source)?.contains(timestamp) == true else { return nil }
            }
            return record.imageURL(choice: choice, source: source, width: width, height: height, directory: directory)
        }
        do {
            return try recordedImage()
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            guard let legacyOriginal,
                  let provenance = LegacyStillProvenance.read(for: legacyOriginal, source: source),
                  let image = legacyImage(prefix: prefix, provenance: provenance, directory: directory),
                  FileIdentity(of: legacyOriginal) == source else { return nil }
            let record = Self(choice: choice, source: source, width: width, height: height, filename: image.lastPathComponent, legacyOriginalOnly: true)
            try? record.adopt(at: recordURL)
            do {
                return try recordedImage()
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
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

    private static func legacyTimestamp(_ name: String, prefix: String) -> Double? {
        // Legacy filenames carry a choice, dimensions and write time, but no source identity.
        let stamp = name.dropFirst(prefix.count).dropLast(4)
        guard name.hasPrefix(prefix), name.hasSuffix(".bmp"), stamp.count == 16,
              let bits = UInt64(stamp, radix: 16) else { return nil }
        return Double(bitPattern: bits)
    }

    private static func legacyImage(prefix: String, provenance: LegacyStillProvenance, directory: URL) -> URL? {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return nil }
        return files.compactMap { file -> (url: URL, timestamp: Double)? in
            guard let timestamp = legacyTimestamp(file.lastPathComponent, prefix: prefix), provenance.contains(timestamp),
                  PathSafety.isItem(at: file, ofType: .typeRegular) else { return nil }
            return (file, timestamp)
        }.max(by: { $0.timestamp < $1.timestamp })?.url
    }

    func imageURL(choice: String, source: FileIdentity, width: Int, height: Int, directory: URL) -> URL? {
        guard self.source == source, self.choice == choice, self.width == width, self.height == height,
              PathSafety.isSafeComponent(filename), filename.hasPrefix(Self.prefix(choice, width, height)), filename.hasSuffix(".bmp") else { return nil }
        let url = directory.appendingPathComponent(filename)
        return PathSafety.contained(url, in: directory) && PathSafety.isItem(at: url, ofType: .typeRegular) ? url : nil
    }
}
