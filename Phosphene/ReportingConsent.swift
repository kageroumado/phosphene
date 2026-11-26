import CryptoKit
import Darwin
import Foundation
import notify

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
    case legacyStatistics
}

nonisolated enum LegacyStatisticsChoice: String, Codable {
    case undecided
    case keepRequested
    case keepUnavailable
    case startNew
    case deletionRequested

    var pausesCounting: Bool {
        self == .undecided || self == .keepRequested || self == .keepUnavailable
    }
}

nonisolated enum ReportingDeletion {
    case requested
    case pending
    case unconfirmed
}

nonisolated struct ReportingCrashScan: Codable, Equatable {
    let app: String
    var checkedThrough: Date
    var releaseSlices: Set<UUID> = []
    private var claimed: Set<String>?
    private(set) var incidents: [String: Date]?

    static let retention: TimeInterval = 7 * 24 * 60 * 60
    private static let capacity = 1_024

    mutating func prune(at date: Date) {
        var kept = (incidents ?? [:]).filter { date.timeIntervalSince($0.value) < Self.retention }
        for id in (claimed ?? []).sorted().prefix(Self.capacity - min(kept.count, Self.capacity)) {
            kept[id] = date
        }
        claimed = nil
        incidents = kept
    }

    mutating func claim(_ id: String, at date: Date) -> Bool {
        guard var kept = incidents, kept.count < Self.capacity, kept[id] == nil else { return false }
        kept[id] = date
        incidents = kept
        return true
    }
}

nonisolated struct ReportingState: Codable, Equatable {
    var consent: ReportingConsent?
    var requiredRevocations: Set<ReportingStream> = []
    var unconfirmedDeletions: Set<ReportingStream> = []
    var crashScan: ReportingCrashScan?
    var legacyStatistics: LegacyStatisticsChoice?
    private var blockedRevocations: Set<ReportingStream>?

    static var recovery: Self {
        Self(requiredRevocations: [.statistics, .crashes])
    }

    func isBlocked(_ stream: ReportingStream) -> Bool {
        blockedRevocations?.contains(stream) == true
    }

    mutating func block(_ stream: ReportingStream) {
        requiredRevocations.insert(stream)
        unconfirmedDeletions.insert(stream)
        blockedRevocations = (blockedRevocations ?? []).union([stream])
    }

    mutating func finishRevocation(_ stream: ReportingStream) {
        requiredRevocations.remove(stream)
        blockedRevocations?.remove(stream)
    }

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

/// The journal lock protects read/modify/write across instances. The owner lock
/// stays held for the reporting controller's process lifetime.
nonisolated struct ReportingStore {
    let url: URL
    static let notification = "glass.kagerou.phosphene.reportingChanged"

    var useNotification: String {
        let scope = SHA256.hash(data: Data(url.standardizedFileURL.path.utf8))
        return "glass.kagerou.phosphene.reportingUsed.\(Data(scope).base64EncodedString())"
    }

    func notifyUse() {
        _ = unsafe notify_post(useNotification)
    }

    func initialize(
        initial: () -> ReportingState,
        retireLegacy: (() -> Void)?,
        configure: (inout ReportingState) -> Void,
    ) throws -> ReportingState {
        try withJournalLock {
            let retired = sibling("Reporting.migrated")
            let alreadyMigrated = FileManager.default.fileExists(atPath: retired.path)
            let existing = try ReportingState.load(from: url)
            var state = existing ?? (alreadyMigrated ? .recovery : initial())
            configure(&state)
            if existing != state {
                try state.save(to: url)
            }
            if let retireLegacy {
                if !alreadyMigrated {
                    try Data().write(to: retired, options: .atomic)
                }
                retireLegacy()
            }
            return state
        }
    }

    func read() throws -> ReportingState {
        guard let state = try ReportingState.load(from: url) else { throw CocoaError(.fileReadNoSuchFile) }
        return state
    }

    func edit(_ change: (inout ReportingState) -> Void) throws -> ReportingState {
        let result = try withJournalLock {
            let existing = try read()
            var state = existing
            change(&state)
            let changed = existing != state
            if changed {
                try state.save(to: url)
            }
            return (state, changed)
        }
        if result.1 {
            _ = unsafe notify_post(Self.notification)
        }
        return result.0
    }

    func tryOwn() throws -> FileHandle? {
        let file = try openLock("Reporting.owner")
        if flock(file.fileDescriptor, LOCK_EX | LOCK_NB) == 0 {
            return file
        }
        if errno == EWOULDBLOCK {
            return nil
        }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    private func withJournalLock<T>(_ work: () throws -> T) throws -> T {
        let file = try openLock("Reporting.lock")
        defer { try? file.close() }
        while flock(file.fileDescriptor, LOCK_EX) != 0 {
            if errno != EINTR {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        return try work()
    }

    private func openLock(_ name: String) throws -> FileHandle {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = unsafe open(sibling(name).path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    private func sibling(_ name: String) -> URL {
        url.deletingLastPathComponent().appending(path: name)
    }
}

final nonisolated class ReportingStoreObserver {
    private let token: Int32

    init?(name: String = ReportingStore.notification, handler: @escaping @Sendable () -> Void) {
        var token: Int32 = 0
        let status = unsafe notify_register_dispatch(name, &token, .main) { _ in handler() }
        guard status == UInt32(NOTIFY_STATUS_OK) else { return nil }
        self.token = token
    }

    deinit {
        _ = notify_cancel(token)
    }
}
