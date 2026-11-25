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
    func `migration preserves statistics identity and retires the previous crash identity`() async throws {
        let fixture = try ReportingFixture(
            statistics: RecordingClient(tier: .crashReports),
            previousCrashes: RecordingClient(tier: .crashReports),
        )
        defer { fixture.remove() }
        let reporting = fixture.controller(initial: ReportingBuild.release.initialState { "crashReports" })

        reporting.noteUse()
        await finish(reporting)
        #expect(reporting.consent == ReportingConsent(crashReports: true, usageStatistics: true))
        #expect(await fixture.statistics.tierChanges == [.counting])
        #expect(await fixture.previousCrashes.tierChanges == [.off])
        #expect(await fixture.previousCrashes.useCount == 0)
        #expect(await fixture.crashes.tierChanges == [.crashReports])
        #expect(await fixture.crashes.useCount == 0)
    }

    @Test
    func `migrated crash-only consent retires stale statistics before a new grant`() async throws {
        let fixture = try ReportingFixture(statistics: RecordingClient(tier: .counting))
        defer { fixture.remove() }
        let reporting = fixture.controller(initial: ReportingBuild.release.initialState { "crashesOnly" })
        #expect(reporting.consent == ReportingConsent(crashReports: true))

        reporting.consent.usageStatistics = true
        await finish(reporting)
        #expect(await fixture.statistics.tierChanges == [.off, .counting])
        #expect(await fixture.crashes.tierChanges == [.crashReports])
        #expect(await fixture.crashes.useCount == 0)
    }

    @Test
    func `Debug asks independently and accepts both controls without crash discovery`() async throws {
        let release = try ReportingFixture()
        defer { release.remove() }
        let debug = try ReportingFixture(
            statistics: RecordingClient(tier: .counting),
            root: ReportingBuild.debug.supportFolder(in: release.root),
        )
        try ReportingBuild.release.initialState { "crashReports" }.save(to: release.stateURL)
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

    @Test
    func `interrupted scan resumes without handing off a claimed crash twice`() async throws {
        let sending = ReportingGate()
        let fixture = try ReportingFixture(crashes: RecordingClient(crashGate: sending))
        defer { fixture.remove() }
        let first = OwnCrashReports.Report(url: fixture.root.appending(path: "first.ips"), id: "incident-1")
        let second = OwnCrashReports.Report(url: fixture.root.appending(path: "second.ips"), id: "incident-2")
        let findReports: @Sendable (Date, Date, Set<UUID>) async -> [OwnCrashReports.Report] = { _, _, _ in [first, second] }
        let reporting = fixture.controller(findReports: findReports)
        reporting.consent.crashReports = true
        await sending.waitUntilEntered()
        #expect(try ReportingState.load(from: fixture.stateURL)?.crashScan?.claimed == [first.id])

        reporting.activity[.crashes]?.cancel()
        await sending.open()
        await finish(reporting)

        let restarted = fixture.controller(findReports: findReports)
        restarted.noteUse()
        await sending.waitUntilEntered()
        await sending.open()
        await finish(restarted)
        #expect(await fixture.crashes.reports == [first.url, second.url])
        #expect(try ReportingState.load(from: fixture.stateURL)?.crashScan?.claimed.isEmpty == true)
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
        let streams: [ReportingStream] = [.statistics, .crashes, .previousCrashes]
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
        currentCrashSlice: UUID? = nil,
        findReports: @escaping @Sendable (Date, Date, Set<UUID>) async -> [OwnCrashReports.Report] = { _, _, _ in [] },
    ) -> UsageCounting {
        UsageCounting(
            stateURL: stateURL,
            initialState: { initial },
            statistics: statistics,
            previousCrashes: previousCrashes,
            crashDestination: ("phosphene-crashes", crashes),
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

    func flush() async {}
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
