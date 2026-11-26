import Digoxin
import Foundation
import Testing

struct ReportingConsentTests {
    @Test(arguments: [
        ("off", false, false),
        ("counting", false, true),
        ("crashesOnly", true, false),
        ("crashReports", true, true),
    ])
    func `stored consent preserves each grant`(value: String, crashReports: Bool, usageStatistics: Bool) throws {
        let consent = try #require(ReportingConsent(storedValue: value))
        #expect(consent.crashReports == crashReports)
        #expect(consent.usageStatistics == usageStatistics)
        #expect(consent.storedValue == value)
    }

    @Test
    func `either grant can be withdrawn independently`() throws {
        var consent = try #require(ReportingConsent(storedValue: "crashReports"))
        consent.usageStatistics = false
        #expect(consent.storedValue == "crashesOnly")

        consent.usageStatistics = true
        consent.crashReports = false
        #expect(consent.storedValue == "counting")
    }

    @Test
    func `missing and unknown consent can still be requested`() {
        #expect(ReportingConsent(storedValue: nil) == nil)
        #expect(ReportingConsent(storedValue: "unknown") == nil)
        #expect(ReportingConsent(storedValue: "off") != nil)
    }
}

@MainActor
struct ReportingLifecycleTests {
    @Test
    func `rapid regrant retires both identities before new traffic`() async throws {
        let fixture = try ReportingFixture()
        defer { fixture.remove() }
        let both = ReportingConsent(crashReports: true, usageStatistics: true)
        let reporting = fixture.controller()
        reporting.consent = both
        await finish(reporting)
        #expect(await fixture.statistics.tier == .counting)
        #expect(await fixture.crashes.tier == .crashReports)

        reporting.consent = ReportingConsent()
        reporting.consent = both
        let onDisk = try ReportingState.load(from: fixture.stateURL)
        let saved = try #require(onDisk)
        #expect(saved.consent == both)
        #expect(saved.requiredRevocations == [.statistics, .crashes])

        await finish(reporting)
        #expect(await fixture.statistics.tierChanges == [.counting, .off, .counting])
        #expect(await fixture.crashes.tierChanges == [.crashReports, .off, .crashReports])
        #expect(await fixture.crashes.useCount == 0)
        #expect(try ReportingState.load(from: fixture.stateURL)?.requiredRevocations.isEmpty == true)
    }

    @Test
    func `restart applies saved revoke before a renewed statistics grant`() async throws {
        let fixture = try ReportingFixture(statistics: RecordingClient(tier: .counting))
        defer { fixture.remove() }
        try ReportingState(
            consent: ReportingConsent(usageStatistics: true),
            requiredRevocations: [.statistics],
        ).save(to: fixture.stateURL)

        let reporting = fixture.controller()
        reporting.noteUse()
        await finish(reporting)
        #expect(await fixture.statistics.tierChanges == [.off, .counting])
        #expect(await fixture.statistics.useCount == 1)
    }

    @Test
    func `revoke reaches Digoxin while an earlier send is suspended`() async throws {
        let sending = ReportingGate()
        let revoking = ReportingGate()
        let fixture = try ReportingFixture(statistics: RecordingClient(sendGate: sending, offGate: revoking))
        defer { fixture.remove() }
        let reporting = fixture.controller()
        reporting.consent.usageStatistics = true
        await sending.waitUntilEntered()

        reporting.consent.usageStatistics = false
        reporting.consent.usageStatistics = true
        await revoking.waitUntilEntered()
        #expect(await fixture.statistics.tier == .off)
        #expect(try ReportingState.load(from: fixture.stateURL)?.requiredRevocations == [.statistics])

        await sending.open()
        await revoking.open()
        await finish(reporting)
        #expect(await fixture.statistics.tierChanges == [.counting, .off, .counting])
    }

    @Test
    func `scoped Release consent preserves its statistics grant and retires the previous crash identity`() async throws {
        let fixture = try ReportingFixture(
            statistics: RecordingClient(tier: .counting),
            previousCrashes: RecordingClient(tier: .crashReports),
        )
        defer { fixture.remove() }
        try ReportingState(consent: ReportingConsent(crashReports: true, usageStatistics: true)).save(to: fixture.stateURL)
        let reporting = fixture.controller(initial: ReportingBuild.release.initialState { "crashReports" })

        reporting.noteUse()
        await finish(reporting)
        #expect(reporting.consent == ReportingConsent(crashReports: true, usageStatistics: true))
        #expect(await fixture.statistics.tierChanges.isEmpty)
        #expect(await fixture.statistics.useCount == 1)
        #expect(await fixture.previousCrashes.tierChanges == [.off])
        #expect(await fixture.previousCrashes.useCount == 0)
        #expect(await fixture.crashes.tierChanges == [.crashReports])
        #expect(await fixture.crashes.useCount == 0)
    }

    @Test
    func `the shared legacy preference and queue cannot start Release reporting`() async throws {
        let fixture = try ReportingFixture()
        defer { fixture.remove() }
        let legacy = fixture.root.appending(path: "Digoxin")
        let pending = legacy.appending(path: "heartbeats.json")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        let data = Data("synthetic ambiguous queue".utf8)
        try data.write(to: pending)

        let current = ReportingBuild.release.statisticsFolder(in: fixture.root)
        #expect(current == fixture.root.appending(path: "Statistics", directoryHint: .isDirectory))
        #expect(ReportingBuild.hasStrandedData(in: fixture.root, deletionPending: false))
        #expect(!ReportingBuild.hasStrandedData(in: current, deletionPending: false))
        let migration = LegacyStatisticsStore(old: legacy, new: current.appending(path: "Digoxin"))
        let reporting = fixture.controller(
            initial: ReportingBuild.release.initialState { "crashReports" },
            legacyStore: migration,
        )
        reporting.noteUse()
        await finish(reporting)
        #expect(reporting.legacyStatistics == .undecided)
        #expect(reporting.shouldAsk)
        #expect(reporting.consent == ReportingConsent())
        #expect(await fixture.statistics.useCount == 0)
        #expect(await fixture.crashes.tier == .off)
        #expect(try Data(contentsOf: pending) == data)
        #expect(ReportingBuild.release.initialState { "off" }.consent == ReportingConsent())
    }

    @Test(arguments: [
        (false, true, true, false),
        (false, true, true, true),
        (true, true, true, false),
        (false, false, true, false),
        (false, true, false, false),
    ])
    func `Keep requires empty queues and the original usable key`(
        queued: Bool, keyOpens: Bool, keyMatches: Bool, revoked: Bool,
    ) async throws {
        let fixture = try ReportingFixture(statistics: RecordingClient(tier: .counting))
        defer { fixture.remove() }
        let legacy = RecordingClient(tier: .counting, status: .registered(trust: "device"))
        var migration = fixture.legacyStore
        let key = Data("synthetic old key".utf8)
        let installID = keyMatches ? "esew3vuvwn7qgddcd5kqyqvwd3" : "another-install"
        let state = Data(#"{"registered":"\#(installID)","seq":13}"#.utf8)
        if keyOpens {
            migration.loadPublicKey = { $0 }
        }
        try FileManager.default.createDirectory(at: migration.old, withIntermediateDirectories: true)
        try key.write(to: migration.old.appending(path: "identity.key"))
        try state.write(to: migration.old.appending(path: "state.json"))
        try Data((queued ? "[{}]" : "[]").utf8).write(to: migration.old.appending(path: "heartbeats.json"))
        let reporting = fixture.controller(legacyStore: migration, legacyClient: legacy)
        reporting.choose(true, for: \.usageStatistics)
        if revoked {
            reporting.choose(false, for: \.usageStatistics)
            reporting.choose(true, for: \.usageStatistics)
            #expect(try ReportingState.load(from: fixture.stateURL)?.requiredRevocations == [.statistics])
        }
        reporting.noteUse()
        await finish(reporting)
        #expect(await fixture.statistics.useCount == 0)

        reporting.chooseLegacy(.keepRequested)
        await finish(reporting)
        #expect(await legacy.tierChanges.isEmpty)
        #expect(await legacy.flushTiers.isEmpty)
        if queued || !keyOpens || !keyMatches {
            #expect(reporting.legacyStatistics == .keepUnavailable)
            #expect(await fixture.statistics.useCount == 0)
            #expect(try Data(contentsOf: migration.old.appending(path: "identity.key")) == key)
        } else {
            #expect(reporting.legacyStatistics == nil)
            #expect(await fixture.statistics.useCount == 1)
            #expect(await fixture.statistics.tierChanges.isEmpty)
            #expect(try ReportingState.load(from: fixture.stateURL)?.requiredRevocations.isEmpty == true)
            #expect(try Data(contentsOf: migration.new.appending(path: "identity.key")) == key)
            #expect(try Data(contentsOf: migration.new.appending(path: "state.json")) == state)
            #expect(!FileManager.default.fileExists(atPath: migration.old.path))
        }
    }

    @Test(arguments: ["missing", "unreadable", "malformed"])
    func `a journal read failure preserves the reporting identity and recovers`(failure: String) async throws {
        let fixture = try ReportingFixture()
        defer { fixture.remove() }
        let reporting = fixture.controller()
        reporting.choose(true, for: \.usageStatistics)
        await finish(reporting)

        let backup = fixture.root.appending(path: "backup.json")
        try FileManager.default.moveItem(at: fixture.stateURL, to: backup)
        if failure == "unreadable" {
            try FileManager.default.createDirectory(at: fixture.stateURL, withIntermediateDirectories: false)
        } else if failure == "malformed" {
            try Data("{invalid".utf8).write(to: fixture.stateURL)
        }
        reporting.noteUse()
        await finish(reporting)
        #expect(reporting.storageError)
        #expect(await fixture.statistics.tierChanges == [.counting])
        #expect(await fixture.statistics.useCount == 1)

        if failure != "missing" {
            try FileManager.default.removeItem(at: fixture.stateURL)
        }
        try FileManager.default.moveItem(at: backup, to: fixture.stateURL)
        reporting.noteUse()
        await finish(reporting)
        #expect(!reporting.storageError)
        #expect(await fixture.statistics.tierChanges == [.counting])
        #expect(await fixture.statistics.useCount == 2)
    }

    @Test
    func `historical retirement requires confirmation and never drains its reporting tier`() async throws {
        let fixture = try ReportingFixture()
        defer { fixture.remove() }
        let legacy = RecordingClient(tier: .crashReports)
        let migration = fixture.legacyStore
        try FileManager.default.createDirectory(at: migration.old, withIntermediateDirectories: true)
        try Data("[{}]".utf8).write(to: migration.old.appending(path: "heartbeats.json"))
        let reporting = fixture.controller(
            initial: ReportingState(consent: ReportingConsent(crashReports: true, usageStatistics: true)),
            legacyStore: migration,
            legacyClient: legacy,
        )
        reporting.noteUse()
        reporting.choose(false, for: \.usageStatistics)
        reporting.chooseLegacy(.keepRequested)
        await finish(reporting)
        #expect(reporting.legacyStatistics == .undecided)
        #expect(await legacy.tierChanges.isEmpty)
        #expect(await legacy.flushTiers.isEmpty)

        reporting.chooseLegacy(.deletionRequested)
        await finish(reporting)
        #expect(await legacy.tierChanges == [.off])
        #expect(await legacy.useCount == 0)
        #expect(await legacy.reports.isEmpty)
        #expect(await legacy.flushTiers == [.off])
        #expect(reporting.consent == ReportingConsent(crashReports: true))
        #expect(reporting.deletionStatus(for: .legacyStatistics) == .unconfirmed)
    }

    @Test
    func `migration retires the preference even if the consent file later disappears`() throws {
        let fixture = try ReportingFixture()
        defer { fixture.remove() }
        let store = ReportingStore(url: fixture.stateURL)
        var legacy: String? = "off"
        let first = try store.initialize(
            initial: { ReportingState(consent: ReportingConsent(storedValue: legacy)) },
            retireLegacy: { legacy = nil },
            configure: { _ in },
        )
        #expect(first.consent == ReportingConsent())
        #expect(legacy == nil)

        try FileManager.default.removeItem(at: fixture.stateURL)
        legacy = "crashReports"
        let second = try store.initialize(
            initial: { ReportingState(consent: ReportingConsent(storedValue: legacy)) },
            retireLegacy: { legacy = nil },
            configure: { _ in },
        )
        #expect(second.consent == nil)
        #expect(second.requiredRevocations == [.statistics, .crashes])
        #expect(legacy == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func `a second controller can revoke but only the owner uses Digoxin`() async throws {
        let sending = ReportingGate()
        let revoking = ReportingGate()
        let primary = try ReportingFixture(statistics: RecordingClient(sendGate: sending, offGate: revoking))
        defer { primary.remove() }
        let secondary = try ReportingFixture(root: primary.root)
        var owner: UsageCounting? = primary.controller()
        owner?.consent = ReportingConsent(crashReports: true, usageStatistics: true)
        await sending.waitUntilEntered()

        let peer = secondary.controller()
        peer.noteUse()
        await finish(peer)
        #expect(await secondary.statistics.tierChanges.isEmpty)
        #expect(await secondary.crashes.tierChanges.isEmpty)

        peer.choose(false, for: \.usageStatistics)
        await revoking.waitUntilEntered()
        #expect(await primary.statistics.tier == .off)
        let shared = try ReportingState.load(from: primary.stateURL)
        #expect(shared?.consent == ReportingConsent(crashReports: true))
        #expect(shared?.requiredRevocations == [.statistics])

        await sending.open()
        await revoking.open()
        if let owner {
            await finish(owner)
        }
        owner = nil
        peer.noteUse()
        await finish(peer)
        #expect(await secondary.statistics.useCount == 0)
        #expect(await secondary.crashes.tierChanges == [.crashReports])
    }

    @Test
    func `a second controller forwards usage to the owner of the same journal`() async throws {
        let primary = try ReportingFixture()
        defer { primary.remove() }
        let secondary = try ReportingFixture(root: primary.root)
        let owner = primary.controller()
        owner.choose(true, for: \.usageStatistics)
        await finish(owner)
        #expect(await primary.statistics.useCount == 1)

        let peer = secondary.controller()
        peer.noteUse()
        for _ in 0 ..< 100 {
            if await primary.statistics.useCount > 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        await finish(owner)
        #expect(await primary.statistics.useCount == 2)
        #expect(await secondary.statistics.useCount == 0)
    }

    @Test
    func `an off Digoxin client with unreadable state keeps the revocation blocked`() async throws {
        let fixture = try ReportingFixture()
        defer { fixture.remove() }
        let storage = fixture.root.appending(path: "Statistics")
        let root = storage.appending(path: "Digoxin")
        let key = root.appending(path: "identity.key")
        let invalid = Data("synthetic corrupt state".utf8)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try invalid.write(to: root.appending(path: "state.json"))
        try invalid.write(to: key)
        try ReportingState(
            consent: ReportingConsent(usageStatistics: true), requiredRevocations: [.statistics],
        ).save(to: fixture.stateURL)

        let client = Digoxin(configuration: .init(app: "phosphene", baseURL: fixture.root, storageDirectory: storage))
        #expect(await client.tier == .off)
        let reporting = UsageCounting(
            stateURL: fixture.stateURL,
            initialState: { ReportingState() },
            makeClient: { stream in
                if stream == .statistics {
                    return client
                }
                return RecordingClient()
            },
            hasStrandedData: { stream, status in
                stream == .statistics && ReportingBuild.hasStrandedData(in: storage, deletionPending: status == .deletionPending)
            },
            crashApp: "phosphene-crashes",
            findReports: { _, _, _ in [] },
        )
        reporting.noteUse()
        await finish(reporting)
        #expect(reporting.deletionStatus(for: .statistics) == .unconfirmed)
        let saved = try ReportingState.load(from: fixture.stateURL)
        #expect(saved?.requiredRevocations == [.statistics])
        #expect(saved?.isBlocked(.statistics) == true)
        #expect(await client.tier == .off)
        #expect(try Data(contentsOf: key) == invalid)
    }

    @Test
    func `Debug asks independently and accepts both controls without crash discovery`() async throws {
        let release = try ReportingFixture()
        defer { release.remove() }
        let debug = try ReportingFixture(
            statistics: RecordingClient(tier: .counting),
            root: ReportingBuild.debug.supportFolder(in: release.root),
        )
        try ReportingState(consent: ReportingConsent(crashReports: true, usageStatistics: true)).save(to: release.stateURL)
        let reporting = debug.controller(
            initial: ReportingBuild.debug.initialState { "crashReports" },
            findReports: ReportingBuild.debug.reports,
        )
        #expect(reporting.shouldAsk)
        #expect(reporting.consent == ReportingConsent())
        #expect(ReportingBuild.debug.crashSlice == nil)

        reporting.consent = ReportingConsent(crashReports: true, usageStatistics: true)
        await finish(reporting)
        #expect(await debug.statistics.tierChanges == [.off, .counting])
        #expect(await debug.crashes.tierChanges == [.crashReports])
        #expect(await debug.crashes.reports.isEmpty)
        reporting.consent = ReportingConsent()
        await finish(reporting)
        #expect(try ReportingState.load(from: release.stateURL)?.consent?.crashReports == true)
        #expect(try ReportingState.load(from: debug.stateURL)?.consent?.crashReports == false)
    }

    @Test(.timeLimit(.minutes(1)))
    func `interrupted scan and a later scan never hand off a recent incident again`() async throws {
        let sending = ReportingGate()
        let fixture = try ReportingFixture(crashes: RecordingClient(crashGate: sending))
        defer { fixture.remove() }
        let first = OwnCrashReports.Report(url: fixture.root.appending(path: "first.ips"), id: "incident-1")
        let second = OwnCrashReports.Report(url: fixture.root.appending(path: "second.ips"), id: "incident-2")
        let rediscovered = OwnCrashReports.Report(url: fixture.root.appending(path: "copy.ips"), id: first.id)
        var reporting: UsageCounting? = fixture.controller(findReports: { _, _, _ in [first, second] })
        reporting?.consent.crashReports = true
        await sending.waitUntilEntered()
        #expect(try ReportingState.load(from: fixture.stateURL)?.crashScan?.incidents?[first.id] != nil)

        reporting?.activity[.crashes]?.cancel()
        await sending.open()
        if let reporting {
            await finish(reporting)
        }
        reporting = nil

        let restarted = fixture.controller(findReports: { _, _, _ in [rediscovered, second] })
        restarted.noteUse()
        await sending.waitUntilEntered()
        await sending.open()
        await finish(restarted)
        restarted.noteUse()
        await finish(restarted)
        #expect(await fixture.crashes.reports == [first.url, second.url])
        let saved = try ReportingState.load(from: fixture.stateURL)
        #expect(saved?.crashScan?.incidents?.count == 2)
    }

    @Test
    func `crash claims age out and the journal caps their number`() {
        let now = Date.now
        var scan = ReportingCrashScan(app: "phosphene-crashes", checkedThrough: now)
        scan.prune(at: now)
        for id in 0 ..< 1_024 {
            let claimed = scan.claim(String(id), at: now)
            #expect(claimed)
        }
        let overflow = scan.claim("extra", at: now)
        #expect(!overflow)
        scan.prune(at: now.addingTimeInterval(ReportingCrashScan.retention))
        #expect(scan.incidents?.isEmpty == true)
        let regained = scan.claim("extra", at: now.addingTimeInterval(ReportingCrashScan.retention))
        #expect(regained)
    }

    @Test
    func `Release remembers previously seen slices until consent is withdrawn`() async throws {
        let fixture = try ReportingFixture()
        defer { fixture.remove() }
        let previous = UUID()
        let current = UUID()
        try ReportingState(
            consent: ReportingConsent(crashReports: true),
            crashScan: ReportingCrashScan(
                app: "phosphene-crashes", checkedThrough: .distantPast, releaseSlices: [previous],
            ),
        ).save(to: fixture.stateURL)
        let reporting = fixture.controller(currentCrashSlice: current)
        #expect(try ReportingState.load(from: fixture.stateURL)?.crashScan?.releaseSlices == [previous, current])

        reporting.consent.crashReports = false
        #expect(try ReportingState.load(from: fixture.stateURL)?.crashScan == nil)
        await finish(reporting)
    }

    @Test
    func `pending deletion that disappears stays unconfirmed across a new grant`() async throws {
        let fixture = try ReportingFixture(
            statistics: RecordingClient(tier: .off, status: .deletionPending),
        )
        defer { fixture.remove() }
        let reporting = fixture.controller()
        reporting.noteUse()
        await finish(reporting)
        #expect(reporting.deletionStatus(for: .statistics) == .pending)

        await fixture.statistics.setStatus(.off)
        reporting.noteUse()
        await finish(reporting)
        #expect(reporting.deletionStatus(for: .statistics) == .unconfirmed)

        reporting.consent.usageStatistics = true
        await finish(reporting)
        let restarted = fixture.controller()
        #expect(restarted.deletionStatus(for: .statistics) == .unconfirmed)
    }

    private func finish(_ reporting: UsageCounting) async {
        await reporting.legacyTask?.value
        let streams: [ReportingStream] = [.statistics, .crashes, .previousCrashes, .legacyStatistics]
        for stream in streams {
            await reporting.transitions[stream]?.value
        }
        for stream in streams {
            await reporting.activity[stream]?.value
        }
    }
}

struct CrashDiscoveryTests {
    @Test
    func `only known Release executable slices qualify for reporting`() throws {
        let bundleID = "glass.kagerou.phosphene"
        let release = UUID()
        let debug = UUID()
        let incident = UUID()
        func ips(slice: UUID?, bundle: String = bundleID, bug: String = "309", body: String = "{}") -> Data {
            let sliceField = slice.map { ", \"slice_uuid\": \"\($0.uuidString)\"" } ?? ""
            return Data("""
            {"bug_type":"\(bug)","bundleID":"\(bundle)","incident_id":"\(incident)"\(sliceField)}
            \(body)
            """.utf8)
        }
        let id = try #require(OwnCrashReports.crashID(ips(slice: release), of: bundleID, releaseSlices: [release]))
        #expect(OwnCrashReports.crashID(ips(slice: release, body: "{\"renamed\":true}"), of: bundleID, releaseSlices: [release]) == id)
        #expect(OwnCrashReports.crashID(ips(slice: debug), of: bundleID, releaseSlices: [release]) == nil)
        #expect(OwnCrashReports.crashID(ips(slice: nil), of: bundleID, releaseSlices: [release]) == nil)
        #expect(OwnCrashReports.crashID(ips(slice: release, bundle: "another.app"), of: bundleID, releaseSlices: [release]) == nil)
        #expect(OwnCrashReports.crashID(ips(slice: release, bug: "288"), of: bundleID, releaseSlices: [release]) == nil)
        #expect(OwnCrashReports.currentSliceUUID() != nil)
    }
}

@MainActor
private struct ReportingFixture {
    let root: URL
    var stateURL: URL {
        root.appending(path: "Reporting.json")
    }
    var legacyStore: LegacyStatisticsStore {
        LegacyStatisticsStore(old: root.appending(path: "Digoxin"), new: root.appending(path: "Statistics/Digoxin"))
    }
    let statistics: RecordingClient
    let crashes: RecordingClient
    let previousCrashes: RecordingClient

    init(
        statistics: RecordingClient = RecordingClient(),
        crashes: RecordingClient = RecordingClient(),
        previousCrashes: RecordingClient = RecordingClient(),
        root: URL = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory),
    ) throws {
        self.root = root
        self.statistics = statistics
        self.crashes = crashes
        self.previousCrashes = previousCrashes
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func controller(
        initial: ReportingState = ReportingState(),
        legacyStore: LegacyStatisticsStore? = nil,
        legacyClient: RecordingClient = RecordingClient(),
        currentCrashSlice: UUID? = nil,
        findReports: @escaping @Sendable (Date, Date, Set<UUID>) async -> [OwnCrashReports.Report] = { _, _, _ in [] },
    ) -> UsageCounting {
        UsageCounting(
            stateURL: stateURL,
            initialState: { initial },
            legacyStore: legacyStore,
            makeClient: { stream in
                switch stream {
                case .statistics: statistics
                case .crashes: crashes
                case .previousCrashes: previousCrashes
                case .legacyStatistics: legacyClient
                }
            },
            crashApp: "phosphene-crashes",
            currentCrashSlice: currentCrashSlice,
            findReports: findReports,
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private actor RecordingClient {
    private(set) var tier: ConsentTier
    private(set) var status: DigoxinStatus
    private(set) var tierChanges: [ConsentTier] = []
    private(set) var reports: [URL] = []
    private(set) var useCount = 0
    private(set) var flushTiers: [ConsentTier] = []
    private var sendGate: ReportingGate?
    private let offGate: ReportingGate?
    private let crashGate: ReportingGate?

    init(
        tier: ConsentTier = .off,
        status: DigoxinStatus = .off,
        sendGate: ReportingGate? = nil,
        offGate: ReportingGate? = nil,
        crashGate: ReportingGate? = nil,
    ) {
        self.tier = tier
        self.status = status
        self.sendGate = sendGate
        self.offGate = offGate
        self.crashGate = crashGate
    }

    func setTier(_ newTier: ConsentTier) async {
        guard tier != newTier else { return }
        tier = newTier
        tierChanges.append(newTier)
        if newTier == .off {
            await offGate?.pause()
        }
    }

    func setStatus(_ status: DigoxinStatus) {
        self.status = status
    }

    func recordUse() async {
        useCount += 1
        let gate = sendGate
        sendGate = nil
        await gate?.pause()
    }

    func submitCrashReport(files: [URL], context _: [String: TelemetryValue]) async {
        reports.append(contentsOf: files)
        await crashGate?.pause()
    }

    func flush() async {
        flushTiers.append(tier)
    }
}

extension RecordingClient: ReportingClient {}

private actor ReportingGate {
    private var entrant: CheckedContinuation<Void, Never>?
    private var waiter: CheckedContinuation<Void, Never>?

    func pause() async {
        await withCheckedContinuation { continuation in
            entrant = continuation
            waiter?.resume()
            waiter = nil
        }
    }

    func waitUntilEntered() async {
        guard entrant == nil else { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func open() {
        entrant?.resume()
        entrant = nil
    }
}
