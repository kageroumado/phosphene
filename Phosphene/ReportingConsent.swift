import CryptoKit
import Darwin
import Digoxin
import Foundation
import notify

nonisolated struct ReportingCrashScan: Codable, Equatable {
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
    enum Reduction: String, Codable {
        case none
        case crashes
        case identity
    }

    var tier: ConsentTier?
    var reduction: Reduction = .none
    var crashScan: ReportingCrashScan?

    static func load(from url: URL) throws -> Self? {
        do {
            return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
    }

    func save(to url: URL) throws {
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}

nonisolated enum ReportingBuild {
    case debug
    case release

    var preferenceKey: String {
        self == .debug ? "usageCountingDebug" : "usageCounting"
    }

    func supportFolder(in folder: URL) -> URL {
        self == .debug ? folder.appending(path: "Debug", directoryHint: .isDirectory) : folder
    }

    func initialState(
        preferenceForKey: (String) -> String?, upstreamCutoff: Date? = nil, previewURL: URL,
    ) -> ReportingState {
        let preference = preferenceForKey(preferenceKey).flatMap(ConsentTier.init(rawValue:))
        let preview = (try? Data(contentsOf: previewURL)).flatMap { try? JSONDecoder().decode(Preview.self, from: $0) }
        let tier = preference ?? preview?.consent?.tier
        var scan: ReportingCrashScan?
        if tier == .crashReports {
            if preview?.consent?.tier == .crashReports {
                scan = preview?.crashScan
            }
            if self == .release, preference == .crashReports, let upstreamCutoff {
                if let existing = scan {
                    scan?.checkedThrough = max(existing.checkedThrough, upstreamCutoff)
                } else {
                    scan = ReportingCrashScan(checkedThrough: upstreamCutoff)
                }
            }
        }
        // Preview revocations addressed different stores. Only the original preference can retire this one.
        return ReportingState(tier: tier, reduction: preference == .off ? .identity : .none, crashScan: scan)
    }

    private struct Preview: Decodable {
        struct Consent: Decodable {
            let crashReports: Bool
            let usageStatistics: Bool

            var tier: ConsentTier? {
                switch (usageStatistics, crashReports) {
                case (false, false): ConsentTier.off
                case (true, false): .counting
                case (true, true): .crashReports
                case (false, true): nil
                }
            }
        }

        let consent: Consent?
        let crashScan: ReportingCrashScan?
    }

    static func hasStrandedData(in folder: URL, deletionPending: Bool) -> Bool {
        let root = folder.appending(path: "Digoxin", directoryHint: .isDirectory)
        do {
            let items = try FileManager.default.contentsOfDirectory(atPath: root.path)
            if items.contains(where: { $0 != "pending-deletions" }) {
                return true
            }
            guard items.contains("pending-deletions"), !deletionPending else { return false }
            return try !FileManager.default.contentsOfDirectory(atPath: root.appending(path: "pending-deletions").path).isEmpty
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return false
        } catch {
            return true
        }
    }
}

/// The journal lock protects read/modify/write across instances. The owner lock
/// stays held for the reporting controller's process lifetime.
nonisolated struct ReportingStore {
    let url: URL

    var notification: String {
        let scope = SHA256.hash(data: Data(url.standardizedFileURL.path.utf8))
        return "glass.kagerou.phosphene.reportingChanged.\(Data(scope).base64EncodedString())"
    }

    var useNotification: String {
        notification + ".used"
    }

    func notifyUse() {
        _ = unsafe notify_post(useNotification)
    }

    func read() throws -> ReportingState {
        guard let state = try ReportingState.load(from: url) else { throw CocoaError(.fileReadNoSuchFile) }
        return state
    }

    func edit(
        initial: (() -> ReportingState)? = nil,
        recovering: ReportingState? = nil,
        didSave: (() -> Void)? = nil,
        _ change: (inout ReportingState) -> Void,
    ) throws -> ReportingState {
        let (state, changed) = try withJournalLock {
            let existing: ReportingState?
            do {
                existing = try ReportingState.load(from: url)
            } catch is DecodingError where recovering != nil {
                existing = nil
            }

            let marker = sibling("UsageCounting.initialized")
            let initialized: Bool
            do {
                _ = try FileManager.default.attributesOfItem(atPath: marker.path)
                initialized = true
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
                initialized = false
            }

            var state: ReportingState
            if let existing {
                state = existing
            } else if let recovering {
                state = recovering
            } else if !initialized, let initial {
                state = initial()
            } else {
                throw CocoaError(.fileReadNoSuchFile)
            }
            change(&state)
            let changed = existing != state
            if changed {
                try state.save(to: url)
            }
            if !initialized {
                try Data().write(to: marker, options: .atomic)
            }
            didSave?()
            return (state, changed)
        }
        if changed {
            _ = unsafe notify_post(notification)
        }
        return state
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

    init?(name: String, handler: @escaping @Sendable () -> Void) {
        var token: Int32 = 0
        let status = unsafe notify_register_dispatch(name, &token, .main) { _ in handler() }
        guard status == UInt32(NOTIFY_STATUS_OK) else { return nil }
        self.token = token
    }

    deinit {
        _ = notify_cancel(token)
    }
}
