import Foundation

nonisolated struct ReportingConsent: Codable, Equatable {
    var crashReports = false
    var usageStatistics = false

    var storedValue: String {
        switch (crashReports, usageStatistics) {
        case (false, false): "off"
        case (false, true): "counting"
        case (true, false): "crashesOnly"
        case (true, true): "crashReports"
        }
    }
}

extension ReportingConsent {
    /// Existing preference values keep their meaning during migration.
    nonisolated init?(storedValue: String?) {
        switch storedValue {
        case "off": self.init()
        case "counting": self.init(usageStatistics: true)
        case "crashesOnly": self.init(crashReports: true)
        case "crashReports": self.init(crashReports: true, usageStatistics: true)
        default: return nil
        }
    }
}

nonisolated enum ReportingStream: String, Codable {
    case statistics
    case crashes
    case previousCrashes
}

nonisolated enum ReportingDeletion {
    case requested
    case pending
    case unconfirmed
}

nonisolated struct ReportingCrashScan: Codable {
    let app: String
    var checkedThrough: Date
    var releaseSlices: Set<UUID> = []
    var claimed: Set<String> = []
}

nonisolated struct ReportingState: Codable {
    var consent: ReportingConsent?
    var requiredRevocations: Set<ReportingStream> = []
    var unconfirmedDeletions: Set<ReportingStream> = []
    var crashScan: ReportingCrashScan?

    static func load(from url: URL) throws -> Self? {
        do {
            return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
    }

    func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}
