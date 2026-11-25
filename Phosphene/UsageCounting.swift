import CryptoKit
import Digoxin
import Foundation
import MachO
import Observation

/// How many people use Phosphene, and Phosphene's own crashes, through Digoxin.
@MainActor @Observable
final class UsageCounting {
    private let stateURL: URL
    private let clients: [ReportingStream: any ReportingClient]
    private let crashApp: String
    private let currentCrashSlice: UUID?
    private let findReports: @Sendable (Date, Date, Set<UUID>) async -> [OwnCrashReports.Report]
    private var state: ReportingState
    private var statuses: [ReportingStream: DigoxinStatus] = [:]
    @ObservationIgnored private(set) var transitions: [ReportingStream: Task<Void, Never>] = [:]
    @ObservationIgnored private(set) var activity: [ReportingStream: Task<Void, Never>] = [:]
    private(set) var storageError = false

    init(
        stateURL: URL,
        initialState: () -> ReportingState,
        statistics: any ReportingClient,
        previousCrashes: any ReportingClient,
        crashDestination: (app: String, client: any ReportingClient),
        currentCrashSlice: UUID? = nil,
        findReports: @escaping @Sendable (Date, Date, Set<UUID>) async -> [OwnCrashReports.Report],
    ) {
        self.stateURL = stateURL
        clients = [.statistics: statistics, .previousCrashes: previousCrashes, .crashes: crashDestination.client]
        crashApp = crashDestination.app
        self.currentCrashSlice = currentCrashSlice
        self.findReports = findReports
        do {
            state = try ReportingState.load(from: stateURL) ?? initialState()
        } catch {
            // A broken state file cannot revive an old grant or resume an existing queue.
            state = ReportingState(requiredRevocations: [.statistics, .crashes])
        }
        updateScan()
        save()
    }

    var shouldAsk: Bool {
        state.consent == nil
    }

    var consent: ReportingConsent {
        get { state.consent ?? ReportingConsent() }
        set {
            guard state.consent != newValue else { return }
            let previous = consent
            state.consent = newValue
            if previous.usageStatistics, !newValue.usageStatistics {
                state.requiredRevocations.insert(.statistics)
                activity[.statistics]?.cancel()
            }
            if previous.crashReports, !newValue.crashReports {
                state.requiredRevocations.insert(.crashes)
                activity[.crashes]?.cancel()
            }
            updateScan()
            save()
            noteUse()
        }
    }

    func status(for stream: ReportingStream) -> DigoxinStatus {
        statuses[stream] ?? .off
    }

    func deletionStatus(for stream: ReportingStream) -> ReportingDeletion? {
        if state.requiredRevocations.contains(stream) {
            return .requested
        }
        if status(for: stream) == .deletionPending {
            return .pending
        }
        if state.unconfirmedDeletions.contains(stream) {
            return .unconfirmed
        }
        return nil
    }

    func noteUse() {
        if storageError {
            save()
        }
        for (stream, client) in clients where transitions[stream] == nil {
            transitions[stream] = Task {
                defer { transitions[stream] = nil }
                await applyConsent(to: stream, client: client)
            }
        }
    }

    private func targetTier(for stream: ReportingStream) -> ConsentTier {
        guard !storageError else { return .off }
        switch stream {
        case .statistics: return consent.usageStatistics ? .counting : .off
        case .crashes: return consent.crashReports ? .crashReports : .off
        case .previousCrashes: return .off
        }
    }

    private func applyConsent(to stream: ReportingStream, client: any ReportingClient) async {
        while true {
            let current = await client.tier
            await refreshStatus(for: stream, client: client)
            let target = targetTier(for: stream)
            if state.requiredRevocations.contains(stream) || (target == .off && current != .off) {
                let previousActivity = activity[stream]
                previousActivity?.cancel()
                if current != .off {
                    state.requiredRevocations.insert(stream)
                    state.unconfirmedDeletions.insert(stream)
                    save()
                }
                // Turn off before waiting for a canceled upload. Digoxin invalidates its in-flight generation here.
                await client.setTier(.off)
                await previousActivity?.value
                state.requiredRevocations.remove(stream)
                save()
                continue
            }
            if current == target {
                startActivity(for: stream, tier: target, client: client)
                return
            }

            let previousActivity = activity[stream]
            previousActivity?.cancel()
            // The legacy combined queue always moves to counting, which drops its queued crashes.
            await client.setTier(target)
            await previousActivity?.value
        }
    }

    private func startActivity(for stream: ReportingStream, tier: ConsentTier, client: any ReportingClient) {
        guard activity[stream] == nil else { return }
        activity[stream] = Task {
            defer { activity[stream] = nil }
            guard !Task.isCancelled else { return }
            if tier == .counting {
                await client.recordUse()
            } else {
                if tier == .crashReports {
                    await scanCrashes(using: client)
                }
                guard !Task.isCancelled else { return }
                // Retry pending reports and deletions without recording a day of use.
                await client.flush()
            }
            guard !Task.isCancelled else { return }
            await refreshStatus(for: stream, client: client)
        }
    }

    private func refreshStatus(for stream: ReportingStream, client: any ReportingClient) async {
        let status = await client.status
        // Digoxin also clears pending requests after permanent rejection.
        if status == .deletionPending, state.unconfirmedDeletions.insert(stream).inserted {
            save()
        }
        statuses[stream] = status
    }

    private func updateScan() {
        guard consent.crashReports else {
            state.crashScan = nil
            return
        }
        if state.crashScan?.app != crashApp {
            state.crashScan = ReportingCrashScan(app: crashApp, checkedThrough: .now)
        }
        if let currentCrashSlice {
            state.crashScan?.releaseSlices.insert(currentCrashSlice)
        }
    }

    private func scanCrashes(using client: any ReportingClient) async {
        guard let scan = state.crashScan else { return }
        let cutoff = Date.now
        guard cutoff > scan.checkedThrough else { return }
        let reports = await findReports(scan.checkedThrough, cutoff, scan.releaseSlices)
        for report in reports {
            guard !Task.isCancelled, !storageError else { return }
            guard state.crashScan?.claimed.insert(report.id).inserted == true else { continue }
            // shortcut: at-most-once handoff can lose a report before enqueue, upgrade when Digoxin accepts a durable report ID.
            guard save() else {
                state.crashScan?.claimed.remove(report.id)
                return
            }
            await client.submitCrashReport(files: [report.url], context: [:])
        }
        guard !Task.isCancelled, !storageError else { return }
        state.crashScan?.checkedThrough = cutoff
        state.crashScan?.claimed.removeAll()
        save()
    }

    @discardableResult
    private func save() -> Bool {
        do {
            try state.save(to: stateURL)
            storageError = false
        } catch {
            storageError = true
        }
        return !storageError
    }
}

nonisolated protocol ReportingClient: Sendable {
    var tier: ConsentTier { get async }
    var status: DigoxinStatus { get async }
    func setTier(_ newTier: ConsentTier) async
    func recordUse() async
    func submitCrashReport(files: [URL], context: [String: TelemetryValue]) async
    func flush() async
}

extension Digoxin: ReportingClient {}

nonisolated enum ReportingBuild {
    case debug
    case release

    func supportFolder(in folder: URL) -> URL {
        switch self {
        case .debug: folder.appending(path: "Debug", directoryHint: .isDirectory)
        case .release: folder
        }
    }

    func initialState(legacyConsent: () -> String?) -> ReportingState {
        switch self {
        case .debug:
            // Previous Debug queues used a preference shared with Release.
            return ReportingState(requiredRevocations: [.statistics])
        case .release:
            let consent = ReportingConsent(storedValue: legacyConsent())
            return ReportingState(
                consent: consent,
                requiredRevocations: consent?.usageStatistics == true ? [] : [.statistics],
            )
        }
    }

    var crashSlice: UUID? {
        self == .release ? OwnCrashReports.currentSliceUUID() : nil
    }

    func reports(after date: Date, through cutoff: Date, releaseSlices: Set<UUID>) async -> [OwnCrashReports.Report] {
        // Debug and Release share a bundle identifier in macOS diagnostic reports.
        guard self == .release else { return [] }
        return await OwnCrashReports.reports(after: date, through: cutoff, releaseSlices: releaseSlices)
    }
}

// MARK: - Own crash reports

/// Which of the crash reports macOS wrote under the app's process name are the app's.
///
/// macOS writes `procPath` with the home folder masked (`/Users/USER/…`), so the path
/// cannot distinguish builds. Match the bundle and executable slice UUID in the header.
nonisolated enum OwnCrashReports {
    struct Report: Sendable {
        let url: URL
        let id: String
    }

    @concurrent
    static func reports(after date: Date, through cutoff: Date, releaseSlices: Set<UUID>) async -> [Report] {
        guard !releaseSlices.isEmpty, let bundleID = Bundle.main.bundleIdentifier else { return [] }
        return DiagnosticReports.reports(forProcess: "Phosphene", after: date).compactMap { url in
            guard let created = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate,
                  created <= cutoff, let data = try? Data(contentsOf: url),
                  let id = crashID(data, of: bundleID, releaseSlices: releaseSlices)
            else { return nil }
            return Report(url: url, id: id)
        }
    }

    /// dyld has already validated the main executable's loaded Mach-O slice.
    static func currentSliceUUID() -> UUID? {
        guard let header = unsafe _dyld_get_image_header(0),
              unsafe header.pointee.magic == MH_MAGIC_64
        else { return nil }
        let commands = unsafe UnsafeRawBufferPointer(
            start: UnsafeRawPointer(header).advanced(by: MemoryLayout<mach_header_64>.size),
            count: Int(header.pointee.sizeofcmds),
        )
        let count = unsafe Int(header.pointee.ncmds)
        var offset = 0
        for _ in 0 ..< count {
            guard commands.count - offset >= MemoryLayout<load_command>.size else { return nil }
            let command = unsafe commands.loadUnaligned(fromByteOffset: offset, as: load_command.self)
            let size = Int(command.cmdsize)
            guard size >= MemoryLayout<load_command>.size, size <= commands.count - offset else { return nil }
            if command.cmd == LC_UUID, size == MemoryLayout<uuid_command>.size {
                let uuid = unsafe commands.loadUnaligned(fromByteOffset: offset, as: uuid_command.self)
                return UUID(uuid: uuid.uuid)
            }
            offset += size
        }
        return nil
    }

    /// `bug_type` of a crash. A hang or a spin is written under other types.
    static let crashBugType = "309"

    /// A stable claim key for an app crash. Fall back to the file digest for headers without an incident ID.
    static func crashID(_ ips: Data, of bundleID: String, releaseSlices: Set<UUID>) -> String? {
        let line = ips.prefix { $0 != UInt8(ascii: "\n") }
        guard let header = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              header["bug_type"] as? String == crashBugType,
              header["bundleID"] as? String == bundleID,
              let slice = (header["slice_uuid"] as? String).flatMap(UUID.init(uuidString:)),
              releaseSlices.contains(slice)
        else { return nil }
        let incident = (header["incident_id"] as? String).flatMap(UUID.init(uuidString:))
        let identity = incident.map { Data($0.uuidString.utf8) } ?? ips
        return Data(SHA256.hash(data: identity)).base64EncodedString()
    }
}
