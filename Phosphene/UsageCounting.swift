import CryptoKit
import Digoxin
import Foundation
import MachO
import Observation

/// How many people use Phosphene, and Phosphene's own crashes, through Digoxin.
@MainActor @Observable
final class UsageCounting {
    private let store: ReportingStore
    private let initialState: () -> ReportingState
    private let savePreference: (ConsentTier) -> Void
    private let makeClient: @MainActor () -> any ReportingClient
    private let hasStrandedData: (DigoxinStatus) -> Bool
    private let currentCrashSlice: UUID?
    private let findReports: @Sendable (Date, Date, Set<UUID>) async -> [OwnCrashReports.Report]
    private var state = ReportingState()
    private(set) var status: DigoxinStatus = .off
    private(set) var storageError = false

    @ObservationIgnored private var initialized = false
    @ObservationIgnored private var choiceWriteFailed = false
    @ObservationIgnored private var scheduledTier: ConsentTier?
    @ObservationIgnored private var ownership: FileHandle?
    @ObservationIgnored private(set) var client: (any ReportingClient)?
    @ObservationIgnored private var observer: ReportingStoreObserver?
    @ObservationIgnored private var useObserver: ReportingStoreObserver?
    @ObservationIgnored private var monitor: Task<Void, Never>?
    @ObservationIgnored private(set) var transition: Task<Void, Never>?
    @ObservationIgnored private(set) var activity: Task<Void, Never>?

    init(
        stateURL: URL,
        initialState: @escaping () -> ReportingState,
        savePreference: @escaping (ConsentTier) -> Void = { _ in },
        makeClient: @escaping @MainActor () -> any ReportingClient,
        hasStrandedData: @escaping (DigoxinStatus) -> Bool = { _ in false },
        currentCrashSlice: UUID? = nil,
        findReports: @escaping @Sendable (Date, Date, Set<UUID>) async -> [OwnCrashReports.Report] = { _, _, _ in [] },
    ) {
        store = ReportingStore(url: stateURL)
        self.initialState = initialState
        self.savePreference = savePreference
        self.makeClient = makeClient
        self.hasStrandedData = hasStrandedData
        self.currentCrashSlice = currentCrashSlice
        self.findReports = findReports
        do {
            state = try initializeJournal()
        } catch {
            storageError = true
        }
    }

    var tier: ConsentTier? {
        state.tier
    }

    func choose(_ tier: ConsentTier) {
        do {
            let latest = try store.edit(initial: initialState, recovering: state, didSave: { self.savePreference(tier) }) {
                if tier == .off {
                    $0.reduction = .identity
                } else if tier == .counting, $0.tier == .crashReports, $0.reduction != .identity {
                    $0.reduction = .crashes
                }
                $0.tier = tier
                configureScan(&$0)
            }
            initialized = true
            adopt(latest)
            choiceWriteFailed = false
            noteUse()
        } catch {
            choiceWriteFailed = true
            failClosed()
        }
    }

    func noteUse() {
        if observer == nil {
            observer = ReportingStoreObserver(name: store.notification) { [weak self] in
                Task { @MainActor in self?.synchronize() }
            }
        }
        startMonitor()
        synchronize(force: true)
        if ownership == nil, !storageError {
            store.notifyUse()
        }
    }

    private func startMonitor() {
        guard monitor == nil else { return }
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }
                self.synchronize(force: self.useObserver == nil)
                if self.ownership != nil, self.observer != nil, self.useObserver != nil, !self.storageError {
                    self.monitor = nil
                    return
                }
            }
        }
    }

    private func synchronize(force: Bool = false) {
        let recovering = storageError
        guard refreshState() else { return }
        var acquired = false
        if ownership == nil {
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
        if useObserver == nil {
            useObserver = ReportingStoreObserver(name: store.useNotification) { [weak self] in
                Task { @MainActor in self?.synchronize(force: true) }
            }
        }

        guard transition == nil, force || acquired || recovering || tier != scheduledTier || state.reduction != .none else { return }
        if client == nil {
            client = makeClient()
        }
        guard let client else { return }
        transition = Task {
            defer { transition = nil }
            await applyConsent(to: client)
        }
    }

    private func applyConsent(to client: any ReportingClient) async {
        while true {
            let current = await client.tier
            let currentStatus = await client.status
            guard refreshState() else { return }
            status = currentStatus
            scheduledTier = tier
            if current == .off, hasStrandedData(currentStatus) {
                return
            }

            let reduction = state.reduction
            if reduction != .none {
                let previousActivity = activity
                previousActivity?.cancel()
                // Invalidate Digoxin's generation before waiting for a canceled upload.
                switch reduction {
                case .identity where current != .off: await client.setTier(.off)
                case .crashes where current == .crashReports: await client.setTier(.counting)
                default: break
                }
                await previousActivity?.value
                guard editState({
                    if $0.reduction == reduction {
                        $0.reduction = .none
                    }
                }) else { return }
                continue
            }

            guard let tier else { return }
            if current != tier {
                // A preview choice may stop app-initiated work without retiring the Release identity.
                guard tier != .off else { return }
                let previousActivity = activity
                previousActivity?.cancel()
                await client.setTier(tier)
                await previousActivity?.value
                continue
            }

            if let previousActivity = activity, previousActivity.isCancelled {
                await previousActivity.value
                continue
            }
            startActivity(at: tier, client: client)
            return
        }
    }

    private func startActivity(at tier: ConsentTier, client: any ReportingClient) {
        guard activity == nil, tier != .off || status == .deletionPending else { return }
        activity = Task {
            defer { activity = nil }
            guard canWork(at: tier) else { return }
            if tier == .off {
                await client.flush()
            } else {
                await client.recordUse()
                if tier == .crashReports, canWork(at: tier) {
                    await scanCrashes(using: client)
                }
            }
            let currentStatus = await client.status
            guard !Task.isCancelled else { return }
            status = currentStatus
        }
    }

    private func canWork(at tier: ConsentTier) -> Bool {
        !Task.isCancelled && refreshState() && !Task.isCancelled && self.tier == tier && state.reduction == .none
    }

    private func configureScan(_ state: inout ReportingState) {
        guard state.tier == .crashReports else {
            state.crashScan = nil
            return
        }
        if state.crashScan == nil {
            state.crashScan = ReportingCrashScan(checkedThrough: .now)
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
            guard canWork(at: .crashReports) else { return }
            var claimed = false
            // shortcut: at-most-once handoff can lose a report before enqueue, upgrade when Digoxin accepts a durable report ID.
            guard editScan(start: scan.checkedThrough, { current in
                claimed = current.claim(report.id, at: cutoff)
            }) else { return }
            if claimed, !Task.isCancelled {
                await client.submitCrashReport(files: [report.url], context: [:])
            }
        }
        guard canWork(at: .crashReports) else { return }
        editScan(start: scan.checkedThrough) { $0.checkedThrough = cutoff }
    }

    @discardableResult
    private func editScan(start: Date, _ change: (inout ReportingCrashScan) -> Void) -> Bool {
        editState { state in
            guard state.tier == .crashReports, state.reduction == .none,
                  var scan = state.crashScan, scan.checkedThrough == start
            else { return }
            change(&scan)
            state.crashScan = scan
        }
    }

    private func adopt(_ latest: ReportingState) {
        if latest.tier != tier || latest.reduction != .none {
            activity?.cancel()
        }
        state = latest
    }

    @discardableResult
    private func refreshState() -> Bool {
        do {
            let latest = try initialized ? store.read() : initializeJournal()
            adopt(latest)
            storageError = choiceWriteFailed
        } catch {
            failClosed()
        }
        return !storageError
    }

    private func initializeJournal() throws -> ReportingState {
        let latest = try store.edit(initial: initialState) { configureScan(&$0) }
        initialized = true
        return latest
    }

    @discardableResult
    private func editState(_ change: (inout ReportingState) -> Void) -> Bool {
        do {
            try adopt(store.edit(change))
            storageError = choiceWriteFailed
            return !storageError
        } catch {
            failClosed()
            return false
        }
    }

    private func failClosed() {
        storageError = true
        scheduledTier = nil
        activity?.cancel()
        startMonitor()
    }
}

nonisolated protocol ReportingClient: Sendable {
    var tier: ConsentTier { get async }
    var status: DigoxinStatus { get async }
    func setTier(_ newTier: ConsentTier) async
    func recordUse() async
    func submitCrashReport(files: [URL], context: [String: TelemetryValue]) async
    func flush() async
    func activeCount() async throws -> Digoxin.ActiveCount
}

extension Digoxin: ReportingClient {}

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
