import Digoxin
import Foundation
import Testing

@MainActor
struct ReportingConsentTests {
    @Test(arguments: ConsentTier.allCases)
    func `Release keeps the existing tier and identity on the first launch`(tier: ConsentTier) async throws {
        let client = RecordingClient(tier: tier)
        let fixture = try ReportingFixture(client: client)
        defer { fixture.remove() }
        try fixture.writePreview(counting: tier == .off, crashes: false)
        let initial = ReportingBuild.release.initialState(
            preferenceForKey: { $0 == "usageCounting" ? tier.rawValue : nil },
            previewURL: fixture.previewURL,
        )

        let reporting = fixture.controller(initial: initial)
        #expect(reporting.tier == tier)
        #expect(!reporting.storageError)
        reporting.noteUse()
        await finish(reporting)

        #expect(await client.tierChanges.isEmpty)
        #expect(await client.useCount == (tier == .off ? 0 : 1))
        #expect(reporting.status == (tier == .off ? .off : .waiting))
        #expect(ReportingBuild.release.supportFolder(in: fixture.root) == fixture.root)
    }

    @Test(arguments: [
        (false, false, ConsentTier.off as ConsentTier?),
        (true, false, .counting),
        (true, true, .crashReports),
        (false, true, nil),
    ])
    func `preview supplies only a tier with exactly the same grants`(
        counting: Bool, crashes: Bool, tier: ConsentTier?,
    ) throws {
        let fixture = try ReportingFixture()
        defer { fixture.remove() }
        try fixture.writePreview(counting: counting, crashes: crashes)
        let state = ReportingBuild.release.initialState(preferenceForKey: { _ in "unknown" }, previewURL: fixture.previewURL)
        #expect(state.tier == tier)
        #expect(state.reduction == .none)
    }

    @Test
    func `a preview opt-out cannot retire the upstream identity`() async throws {
        let client = RecordingClient(tier: .counting)
        let fixture = try ReportingFixture(client: client)
        defer { fixture.remove() }
        try fixture.writePreview(counting: false, crashes: false)
        let initial = ReportingBuild.release.initialState(preferenceForKey: { _ in nil }, previewURL: fixture.previewURL)

        let reporting = fixture.controller(initial: initial)
        #expect(reporting.tier == ConsentTier.off)
        reporting.noteUse()
        await finish(reporting)
        #expect(await client.tierChanges.isEmpty)
        #expect(await client.useCount == 0)

        reporting.choose(.off)
        await finish(reporting)
        #expect(await client.tierChanges == [.off])
    }

    @Test
    func `Debug uses its own preference and directory`() async throws {
        let release = try ReportingFixture()
        defer { release.remove() }
        let debug = try ReportingFixture(root: ReportingBuild.debug.supportFolder(in: release.root))
        let initial = ReportingBuild.debug.initialState(
            preferenceForKey: { ["usageCounting": "crashReports", "usageCountingDebug": "counting"][$0] },
            upstreamCutoff: .distantPast,
            previewURL: debug.previewURL,
        )
        #expect(debug.root != release.root)
        #expect(initial.tier == .counting)
        #expect(ReportingBuild.debug.initialState(
            preferenceForKey: { $0 == "usageCounting" ? "counting" : nil }, previewURL: debug.previewURL,
        ).tier == nil)

        var saved: ConsentTier?
        let reporting = debug.controller(initial: initial, savePreference: { saved = $0 })
        reporting.choose(.crashReports)
        await finish(reporting)
        #expect(saved == .crashReports)
        #expect(try ReportingState.load(from: release.stateURL) == nil)
        #expect(await debug.client.reports.isEmpty)
    }

    @Test
    func `rapid regrant retires the identity before new traffic`() async throws {
        let fixture = try ReportingFixture()
        defer { fixture.remove() }
        let reporting = fixture.controller()
        reporting.choose(.crashReports)
        await finish(reporting)

        reporting.choose(.off)
        reporting.choose(.crashReports)
        let saved = try #require(try ReportingState.load(from: fixture.stateURL))
        #expect(saved.tier == .crashReports)
        #expect(saved.reduction == .identity)

        await finish(reporting)
        #expect(await fixture.client.tierChanges == [.crashReports, .off, .crashReports])
        #expect(await fixture.client.useCount == 2)
        #expect(try ReportingState.load(from: fixture.stateURL)?.reduction == ReportingState.Reduction.none)
    }

    @Test
    func `restart applies the saved revoke before a renewed grant`() async throws {
        let fixture = try ReportingFixture(client: RecordingClient(tier: .counting))
        defer { fixture.remove() }
        try ReportingState(tier: .counting, reduction: .identity).save(to: fixture.stateURL)

        let reporting = fixture.controller()
        reporting.noteUse()
        await finish(reporting)
        #expect(await fixture.client.tierChanges == [.off, .counting])
        #expect(await fixture.client.useCount == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func `revoke reaches Digoxin while an earlier send is suspended`() async throws {
        let sending = ReportingGate()
        let revoking = ReportingGate()
        let fixture = try ReportingFixture(client: RecordingClient(sendGate: sending, offGate: revoking))
        defer { fixture.remove() }
        let reporting = fixture.controller()
        reporting.choose(.counting)
        await sending.waitUntilEntered()

        reporting.choose(.off)
        reporting.choose(.counting)
        await revoking.waitUntilEntered()
        #expect(await fixture.client.tier == .off)
        #expect(try ReportingState.load(from: fixture.stateURL)?.reduction == .identity)

        await sending.open()
        await revoking.open()
        await finish(reporting)
        #expect(await fixture.client.tierChanges == [.counting, .off, .counting])
    }

    @Test(arguments: ["missing", "unreadable", "malformed"])
    func `a journal read failure preserves the identity and recovers`(failure: String) async throws {
        let fixture = try ReportingFixture()
        defer { fixture.remove() }
        let reporting = fixture.controller()
        reporting.choose(.counting)
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
        #expect(reporting.tier == .counting)
        #expect(await fixture.client.tierChanges == [.counting])
        #expect(await fixture.client.useCount == 1)

        let restarted = fixture.controller()
        #expect(restarted.storageError)
        #expect(restarted.tier == nil)
        if failure != "missing" {
            try FileManager.default.removeItem(at: fixture.stateURL)
        }
        try FileManager.default.moveItem(at: backup, to: fixture.stateURL)
        reporting.noteUse()
        await finish(reporting)
        #expect(!reporting.storageError)
        #expect(await fixture.client.tierChanges == [.counting])
        #expect(await fixture.client.useCount == 2)
    }

    @Test
    func `a failed off write keeps reporting suspended until the choice is saved`() async throws {
        let fixture = try ReportingFixture()
        defer { fixture.remove() }
        let reporting = fixture.controller()
        reporting.choose(.counting)
        await finish(reporting)

        let backup = fixture.root.appending(path: "backup.json")
        try FileManager.default.moveItem(at: fixture.stateURL, to: backup)
        try FileManager.default.createDirectory(at: fixture.stateURL, withIntermediateDirectories: false)
        reporting.choose(.off)
        #expect(reporting.storageError)
        try FileManager.default.removeItem(at: fixture.stateURL)
        try FileManager.default.moveItem(at: backup, to: fixture.stateURL)
        reporting.noteUse()
        await finish(reporting)
        #expect(reporting.storageError)
        #expect(await fixture.client.useCount == 1)

        reporting.choose(.off)
        await finish(reporting)
        #expect(!reporting.storageError)
        #expect(await fixture.client.tierChanges == [.counting, .off])
    }

    @Test(.timeLimit(.minutes(1)))
    func `a peer forwards usage and revocation to the owner`() async throws {
        let offGate = ReportingGate()
        let primary = try ReportingFixture(client: RecordingClient(offGate: offGate))
        defer { primary.remove() }
        let secondary = try ReportingFixture(root: primary.root)
        let owner = primary.controller()
        owner.choose(.counting)
        await finish(owner)

        let peer = secondary.controller()
        peer.noteUse()
        for _ in 0 ..< 100 {
            if await primary.client.useCount > 1 {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await primary.client.useCount == 2)

        peer.choose(.off)
        await offGate.waitUntilEntered()
        #expect(owner.tier == ConsentTier.off)
        #expect(await primary.client.tier == .off)
        #expect(await secondary.client.useCount == 0)
        #expect(await secondary.client.tierChanges.isEmpty)
        await offGate.open()
        await finish(owner)
    }

    @Test(arguments: [false, true])
    func `an unreadable Digoxin state leaves the existing identity intact`(revoking: Bool) async throws {
        let fixture = try ReportingFixture()
        defer { fixture.remove() }
        let root = fixture.root.appending(path: "Digoxin")
        let key = root.appending(path: "identity.key")
        let invalid = Data("synthetic corrupt state".utf8)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try invalid.write(to: root.appending(path: "state.json"))
        try invalid.write(to: key)
        let reduction: ReportingState.Reduction = revoking ? .identity : .none
        try ReportingState(tier: .counting, reduction: reduction).save(to: fixture.stateURL)

        let client = Digoxin(configuration: .init(app: "phosphene", baseURL: fixture.root, storageDirectory: fixture.root))
        let reporting = UsageCounting(
            stateURL: fixture.stateURL,
            initialState: { ReportingState() },
            makeClient: { client },
            hasStrandedData: { status in
                ReportingBuild.hasStrandedData(in: fixture.root, deletionPending: status == .deletionPending)
            },
        )
        reporting.noteUse()
        await finish(reporting)
        #expect(try ReportingState.load(from: fixture.stateURL)?.reduction == reduction)
        #expect(await client.tier == .off)
        #expect(try Data(contentsOf: key) == invalid)
    }

    @Test
    func `withdrawing crash consent purges queued crashes without retiring counting`() async throws {
        let previous = UUID()
        let current = UUID()
        let fixture = try ReportingFixture(client: RecordingClient(tier: .crashReports))
        defer { fixture.remove() }
        let cutoff = Date.now.addingTimeInterval(-3_600)
        try ReportingState(
            tier: .crashReports, crashScan: ReportingCrashScan(checkedThrough: cutoff, releaseSlices: [previous]),
        ).save(to: fixture.stateURL)
        let reporting = fixture.controller(currentCrashSlice: current)
        #expect(try ReportingState.load(from: fixture.stateURL)?.crashScan?.releaseSlices == [previous, current])

        reporting.choose(.counting)
        #expect(try ReportingState.load(from: fixture.stateURL)?.crashScan == nil)
        reporting.choose(.crashReports)
        let renewed = try #require(try ReportingState.load(from: fixture.stateURL)?.crashScan)
        #expect(renewed.checkedThrough > cutoff)
        #expect(renewed.releaseSlices == [current])
        await finish(reporting)
        #expect(await fixture.client.tierChanges == [.counting, .crashReports])
    }

    @Test
    func `upstream crash cutoff survives migration`() throws {
        let fixture = try ReportingFixture()
        defer { fixture.remove() }
        let cutoff = Date.now.addingTimeInterval(-3_600)
        let initial = ReportingBuild.release.initialState(
            preferenceForKey: { _ in "crashReports" }, upstreamCutoff: cutoff, previewURL: fixture.previewURL,
        )
        let reporting = fixture.controller(initial: initial)
        #expect(reporting.tier == .crashReports)
        #expect(try ReportingState.load(from: fixture.stateURL)?.crashScan?.checkedThrough == cutoff)
    }

    @Test(.timeLimit(.minutes(1)))
    func `a restarted scan resumes without handing off the same incident twice`() async throws {
        let gate = ReportingGate()
        let fixture = try ReportingFixture(client: RecordingClient(crashGate: gate))
        defer { fixture.remove() }
        let first = OwnCrashReports.Report(url: fixture.root.appending(path: "first.ips"), id: "incident-1")
        let second = OwnCrashReports.Report(url: fixture.root.appending(path: "second.ips"), id: "incident-2")
        let rediscovered = OwnCrashReports.Report(url: fixture.root.appending(path: "copy.ips"), id: first.id)
        var reporting: UsageCounting? = fixture.controller(findReports: { _, _, _ in [first, second] })
        reporting?.choose(.crashReports)
        await gate.waitUntilEntered()
        #expect(try ReportingState.load(from: fixture.stateURL)?.crashScan?.incidents?[first.id] != nil)

        reporting?.activity?.cancel()
        await gate.open()
        if let reporting {
            await finish(reporting)
        }
        reporting = nil

        let restarted = fixture.controller(findReports: { _, _, _ in [rediscovered, second] })
        restarted.noteUse()
        await gate.waitUntilEntered()
        await gate.open()
        await finish(restarted)
        restarted.noteUse()
        await finish(restarted)
        #expect(await fixture.client.reports == [first.url, second.url])
    }

    private func finish(_ reporting: UsageCounting) async {
        await reporting.transition?.value
        await reporting.activity?.value
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
        root.appending(path: "UsageCounting.json")
    }
    var previewURL: URL {
        root.appending(path: "Reporting.json")
    }
    let client: RecordingClient

    init(
        client: RecordingClient = RecordingClient(),
        root: URL = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory),
    ) throws {
        self.root = root
        self.client = client
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func writePreview(counting: Bool, crashes: Bool) throws {
        let data = Data("""
        {"consent":{"usageStatistics":\(counting),"crashReports":\(crashes)},"requiredRevocations":["statistics"]}
        """.utf8)
        try data.write(to: previewURL)
    }

    func controller(
        initial: ReportingState = ReportingState(),
        savePreference: @escaping (ConsentTier) -> Void = { _ in },
        currentCrashSlice: UUID? = nil,
        findReports: @escaping @Sendable (Date, Date, Set<UUID>) async -> [OwnCrashReports.Report] = { _, _, _ in [] },
    ) -> UsageCounting {
        UsageCounting(
            stateURL: stateURL,
            initialState: { initial },
            savePreference: savePreference,
            makeClient: { client },
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
    var status: DigoxinStatus {
        tier == .off ? .off : .waiting
    }
    private(set) var tierChanges: [ConsentTier] = []
    private(set) var reports: [URL] = []
    private(set) var useCount = 0
    private var sendGate: ReportingGate?
    private let offGate: ReportingGate?
    private let crashGate: ReportingGate?

    init(tier: ConsentTier = .off, sendGate: ReportingGate? = nil, offGate: ReportingGate? = nil, crashGate: ReportingGate? = nil) {
        self.tier = tier
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

    func activeCount() async throws -> Digoxin.ActiveCount {
        throw URLError(.notConnectedToInternet)
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
