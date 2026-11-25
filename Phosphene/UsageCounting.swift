import CryptoKit
import Digoxin
import Foundation
import MachO
import Observation

/// How many people use Phosphene, and Phosphene's own crashes, through Digoxin.
@MainActor @Observable
final class UsageCounting {
    private let store: ReportingStore
    private let makeClient: @MainActor (ReportingStream) -> any ReportingClient
    private let hasStrandedData: (ReportingStream, DigoxinStatus) -> Bool
    private let legacyStore: LegacyStatisticsStore?
    private let crashApp: String
    private let currentCrashSlice: UUID?
    private let findReports: @Sendable (Date, Date, Set<UUID>) async -> [OwnCrashReports.Report]
    private var state = ReportingState.recovery
    @ObservationIgnored private var scheduledConsent: ReportingConsent?
    private var statuses: [ReportingStream: DigoxinStatus] = [:]
    @ObservationIgnored private var ownership: FileHandle?
    @ObservationIgnored private var clients: [ReportingStream: any ReportingClient] = [:]
    @ObservationIgnored private(set) var legacyTask: Task<Void, Never>?
    @ObservationIgnored private var observer: ReportingStoreObserver?
    @ObservationIgnored private var monitor: Task<Void, Never>?
    @ObservationIgnored private(set) var transitions: [ReportingStream: Task<Void, Never>] = [:]
    @ObservationIgnored private(set) var activity: [ReportingStream: Task<Void, Never>] = [:]
    private(set) var storageError = false

    init(
        stateURL: URL,
        initialState: () -> ReportingState,
        retireLegacy: (() -> Void)? = nil,
        legacyStore: LegacyStatisticsStore? = nil,
        makeClient: @escaping @MainActor (ReportingStream) -> any ReportingClient,
        hasStrandedData: @escaping (ReportingStream, DigoxinStatus) -> Bool = { _, _ in false },
        crashApp: String,
        currentCrashSlice: UUID? = nil,
        findReports: @escaping @Sendable (Date, Date, Set<UUID>) async -> [OwnCrashReports.Report],
    ) {
        store = ReportingStore(url: stateURL)
        self.makeClient = makeClient
        self.legacyStore = legacyStore
        self.hasStrandedData = hasStrandedData
        self.crashApp = crashApp
        self.currentCrashSlice = currentCrashSlice
        self.findReports = findReports
        do {
            state = try store.initialize(initial: initialState, retireLegacy: retireLegacy) {
                configureLegacy(&$0)
                configureScan(&$0)
            }
        } catch {
            storageError = true
        }
    }

    var shouldAsk: Bool {
        state.consent == nil
    }

    var consent: ReportingConsent {
        get { state.consent ?? ReportingConsent() }
        set { changeConsent { $0 = newValue } }
    }

    func choose(_ value: Bool, for keyPath: WritableKeyPath<ReportingConsent, Bool>) {
        changeConsent { $0[keyPath: keyPath] = value }
    }

    private func changeConsent(_ change: (inout ReportingConsent) -> Void) {
        editState { state in
            let previous = state.consent ?? ReportingConsent()
            var choice = previous
            change(&choice)
            guard state.consent != choice else { return }
            state.consent = choice
            if previous.usageStatistics, !choice.usageStatistics {
                state.requiredRevocations.insert(.statistics)
            }
            if previous.crashReports, !choice.crashReports {
                state.requiredRevocations.insert(.crashes)
            }
            configureScan(&state)
        }
        noteUse()
    }

    var legacyStatistics: LegacyStatisticsChoice? {
        state.legacyStatistics
    }

    func chooseLegacy(_ choice: LegacyStatisticsChoice) {
        editState { state in
            guard let previous = state.legacyStatistics, previous != .keepRequested, previous != .deletionRequested else { return }
            switch choice {
            case .keepRequested:
                guard previous.pausesCounting, state.consent?.usageStatistics == true else { return }
            case .startNew:
                break
            case .deletionRequested:
                let consent = state.consent ?? ReportingConsent()
                state.consent = ReportingConsent(crashReports: consent.crashReports)
                state.requiredRevocations.formUnion([.statistics, .legacyStatistics])
            case .undecided, .keepUnavailable:
                return
            }
            state.legacyStatistics = choice
        }
        noteUse()
    }

    func status(for stream: ReportingStream) -> DigoxinStatus {
        statuses[stream] ?? .off
    }

    func deletionStatus(for stream: ReportingStream) -> ReportingDeletion? {
        if state.isBlocked(stream) {
            return .unconfirmed
        }
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
        if monitor == nil {
            observer = ReportingStoreObserver { [weak self] in
                Task { @MainActor in self?.synchronize() }
            }
            monitor = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(2))
                    guard let self else { return }
                    self.synchronize()
                    if self.ownership != nil, self.observer != nil {
                        return
                    }
                }
            }
        }
        synchronize(force: true)
    }

    private func synchronize(force: Bool = false) {
        refreshState()
        var acquired = false
        if ownership == nil, !storageError {
            do {
                ownership = try store.tryOwn()
                if ownership != nil {
                    if refreshState() {
                        acquired = true
                    } else {
                        ownership = nil
                    }
                }
            } catch {
                failClosed()
            }
        }
        guard ownership != nil else { return }
        let newClients = !storageError && configureClients()
        let changed = force || acquired || newClients || state.consent != scheduledConsent || storageError
        scheduledConsent = state.consent
        for (stream, client) in clients where transitions[stream] == nil {
            let revoke = state.requiredRevocations.contains(stream) && !state.isBlocked(stream)
            guard changed || revoke else { continue }
            transitions[stream] = Task {
                defer { transitions[stream] = nil }
                await applyConsent(to: stream, client: client)
            }
        }
    }

    private func configureLegacy(_ state: inout ReportingState) {
        if state.legacyStatistics == nil, legacyStore?.hasData == true {
            state.legacyStatistics = .undecided
        }
    }

    private func configureClients() -> Bool {
        var streams: [ReportingStream] = [.crashes, .previousCrashes]
        if legacyStatistics?.pausesCounting != true {
            streams.append(.statistics)
        }
        if legacyStatistics == .deletionRequested {
            streams.append(.legacyStatistics)
        }
        if legacyStatistics == .keepRequested, legacyTask == nil {
            legacyTask = Task {
                defer { legacyTask = nil }
                await continueLegacyStatistics()
                synchronize()
            }
        }
        let missing = streams.filter { clients[$0] == nil }
        for stream in missing {
            clients[stream] = makeClient(stream)
        }
        return !missing.isEmpty
    }

    private func continueLegacyStatistics() async {
        guard let legacyStore, refreshState(), legacyStatistics == .keepRequested else { return }
        var registered = false
        if legacyStore.canMove {
            // Reading the status does not trigger registration or queue delivery.
            let client = makeClient(.legacyStatistics)
            if case .registered = await client.status, await client.tier != .off {
                registered = true
            }
        }
        editState { state in
            guard state.legacyStatistics == .keepRequested else { return }
            if legacyStore.wasMoved {
                state.legacyStatistics = nil
            } else if state.consent?.usageStatistics != true {
                state.legacyStatistics = .undecided
            } else if registered, (try? legacyStore.move()) != nil {
                state.legacyStatistics = nil
            } else {
                state.legacyStatistics = .keepUnavailable
            }
        }
    }

    private func targetTier(for stream: ReportingStream) -> ConsentTier {
        guard !storageError else { return .off }
        switch stream {
        case .statistics: return consent.usageStatistics && legacyStatistics?.pausesCounting != true ? .counting : .off
        case .crashes: return consent.crashReports ? .crashReports : .off
        case .previousCrashes, .legacyStatistics: return .off
        }
    }

    private func applyConsent(to stream: ReportingStream, client: any ReportingClient) async {
        while true {
            let current = await client.tier
            let status = await client.status
            guard refreshState() else {
                if current != .off {
                    await client.setTier(.off)
                }
                return
            }
            updateStatus(status, for: stream)
            if current == .off, hasStrandedData(stream, status) {
                editState { $0.block(stream) }
                return
            }
            let target = targetTier(for: stream)
            if state.requiredRevocations.contains(stream) || (target == .off && current != .off) {
                let previousActivity = activity[stream]
                previousActivity?.cancel()
                if current != .off {
                    editState {
                        $0.requiredRevocations.insert(stream)
                        $0.unconfirmedDeletions.insert(stream)
                    }
                }
                // Invalidate Digoxin's generation before waiting for a canceled upload.
                await client.setTier(.off)
                await previousActivity?.value
                let deletionStatus = await client.status
                if hasStrandedData(stream, deletionStatus) {
                    editState { $0.block(stream) }
                    return
                }
                guard editState({ $0.finishRevocation(stream) }) else { return }
                continue
            }
            if current == target {
                startActivity(for: stream, tier: target, client: client)
                return
            }

            let previousActivity = activity[stream]
            previousActivity?.cancel()
            await client.setTier(target)
            await previousActivity?.value
        }
    }

    private func startActivity(for stream: ReportingStream, tier: ConsentTier, client: any ReportingClient) {
        guard activity[stream] == nil else { return }
        activity[stream] = Task {
            defer { activity[stream] = nil }
            guard canWork(stream, at: tier) else { return }
            if tier == .counting {
                await client.recordUse()
            } else {
                if tier == .crashReports {
                    await scanCrashes(using: client)
                }
                guard canWork(stream, at: tier) else { return }
                await client.flush()
            }
            let status = await client.status
            guard !Task.isCancelled else { return }
            updateStatus(status, for: stream)
        }
    }

    private func canWork(_ stream: ReportingStream, at tier: ConsentTier) -> Bool {
        guard !Task.isCancelled, refreshState(), targetTier(for: stream) == tier else { return false }
        return !state.requiredRevocations.contains(stream)
    }

    private func updateStatus(_ status: DigoxinStatus, for stream: ReportingStream) {
        // Digoxin also clears pending requests after permanent rejection.
        if status == .deletionPending, !state.unconfirmedDeletions.contains(stream) {
            editState { $0.unconfirmedDeletions.insert(stream) }
        }
        statuses[stream] = status
    }

    private func configureScan(_ state: inout ReportingState) {
        guard state.consent?.crashReports == true else {
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
        let oldest = cutoff.addingTimeInterval(-ReportingCrashScan.retention)
        guard cutoff > scan.checkedThrough,
              editScan(start: scan.checkedThrough, { $0.prune(at: cutoff) })
        else { return }
        let reports = await findReports(max(scan.checkedThrough, oldest), cutoff, scan.releaseSlices)
        for report in reports {
            guard canWork(.crashes, at: .crashReports) else { return }
            var claimed = false
            // shortcut: at-most-once handoff can lose a report before enqueue, upgrade when Digoxin accepts a durable report ID.
            guard editScan(start: scan.checkedThrough, { current in
                claimed = current.claim(report.id, at: cutoff)
            }) else { return }
            if claimed, !Task.isCancelled {
                await client.submitCrashReport(files: [report.url], context: [:])
            }
        }
        guard canWork(.crashes, at: .crashReports) else { return }
        editScan(start: scan.checkedThrough) { $0.checkedThrough = cutoff }
    }

    @discardableResult
    private func editScan(start: Date, _ change: (inout ReportingCrashScan) -> Void) -> Bool {
        editState { state in
            guard state.consent?.crashReports == true, !state.requiredRevocations.contains(.crashes),
                  var scan = state.crashScan, scan.checkedThrough == start
            else { return }
            change(&scan)
            state.crashScan = scan
        }
    }

    private func adopt(_ latest: ReportingState) {
        for stream in latest.requiredRevocations.subtracting(state.requiredRevocations) {
            activity[stream]?.cancel()
        }
        state = latest
    }

    @discardableResult
    private func refreshState() -> Bool {
        do {
            try adopt(store.read())
        } catch {
            failClosed()
        }
        return !storageError
    }

    @discardableResult
    private func editState(_ change: (inout ReportingState) -> Void) -> Bool {
        do {
            try adopt(store.edit(change))
            storageError = false
        } catch {
            failClosed()
        }
        return !storageError
    }

    private func failClosed() {
        storageError = true
        for task in activity.values {
            task.cancel()
        }
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

/// Moves an intact SDK store only after the user identifies it as Release data.
nonisolated struct LegacyStatisticsStore {
    let old: URL
    let new: URL

    var hasData: Bool {
        ReportingBuild.hasStrandedData(in: old.deletingLastPathComponent(), deletionPending: false)
    }

    var wasMoved: Bool {
        !FileManager.default.fileExists(atPath: old.path) && FileManager.default.fileExists(atPath: new.path)
    }

    var canMove: Bool {
        guard !FileManager.default.fileExists(atPath: new.path),
              let entries = try? FileManager.default.contentsOfDirectory(atPath: old.path),
              Set(entries).isSubset(of: ["state.json", "identity.key", "heartbeats.json", "crashes", "pending-deletions"]),
              entries.contains("identity.key"), entries.contains("state.json")
        else { return false }
        if entries.contains("heartbeats.json") {
            guard let data = try? Data(contentsOf: old.appending(path: "heartbeats.json")),
                  let queued = try? JSONSerialization.jsonObject(with: data) as? [Any], queued.isEmpty
            else { return false }
        }
        for name in ["crashes", "pending-deletions"] where entries.contains(name) {
            guard let contents = try? FileManager.default.contentsOfDirectory(atPath: old.appending(path: name).path),
                  contents.isEmpty
            else { return false }
        }
        return true
    }

    func move() throws {
        guard canMove else { throw CocoaError(.fileWriteUnknown) }
        try FileManager.default.createDirectory(at: new.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: old, to: new)
    }
}

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
            // An affirmative choice in this domain could have come from a pre-split Debug build.
            return ReportingState(consent: consent == ReportingConsent() ? consent : nil)
        }
    }

    func statisticsFolder(in folder: URL) -> URL {
        // The old Release root was also used by Debug before the split.
        self == .release ? folder.appending(path: "Statistics", directoryHint: .isDirectory) : folder
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
