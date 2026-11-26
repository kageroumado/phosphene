import Foundation
import Testing
import Tiptoe

@MainActor
struct UpdateActivityTests {
    @Test
    func `Update Now waits for the offered download and reserves through the install`() async throws {
        let (preparing, started) = AsyncStream<Void>.makeStream()
        let (finishPreparation, resumePreparation) = AsyncStream<Void>.makeStream()
        let (manualRequested, requested) = AsyncStream<Void>.makeStream()
        let tiptoe = makeTiptoe()
        let videoWork = VideoWorkGate()
        let activity = UpdateActivity(tiptoe: tiptoe, videoWork: videoWork)
        var completedPreparation = false
        var installed = false
        let background = Task {
            await activity.check {
                started.yield()
                for await _ in finishPreparation {
                    break
                }
                await stage(candidate("2.0.0") {
                    #expect(completedPreparation)
                    #expect(activity.isReplacingApp)
                    #expect(!videoWork.beginWork())
                    await activity.check {
                        Issue.record("A background check started during the swap.")
                    }
                    installed = true
                }, in: activity)
                completedPreparation = true
            }
        }
        for await _ in preparing {
            break
        }
        let manual = Task {
            requested.yield()
            return try await activity.install(version: "2.0.0") {
                Issue.record("The offered version was already prepared.")
                return nil
            }
        }
        for await _ in manualRequested {
            break
        }
        #expect(!installed)
        #expect(!activity.isReplacingApp)
        resumePreparation.yield()
        await background.value
        #expect(try await manual.value == .attempted)
        #expect(installed)
        #expect(activity.isReplacingApp)
    }

    @Test
    func `running video work blocks manual installation before checking for a candidate`() async throws {
        let videoWork = VideoWorkGate()
        try #require(videoWork.beginWork())
        defer { videoWork.endWork() }
        let activity = UpdateActivity(tiptoe: makeTiptoe(), videoWork: videoWork)
        let result = try await activity.install(version: "2.0.0") {
            Issue.record("The updater started while video work was active.")
            return nil
        }
        #expect(result == .videoWorkInProgress)
    }

    @Test
    func `video work started during background preparation blocks manual installation`() async throws {
        let (preparing, started) = AsyncStream<Void>.makeStream()
        let (finishPreparation, resumePreparation) = AsyncStream<Void>.makeStream()
        let (manualRequested, requested) = AsyncStream<Void>.makeStream()
        let videoWork = VideoWorkGate()
        let activity = UpdateActivity(tiptoe: makeTiptoe(), videoWork: videoWork)
        let background = Task {
            await activity.check {
                started.yield()
                for await _ in finishPreparation {
                    break
                }
            }
        }
        for await _ in preparing {
            break
        }
        let manual = Task {
            requested.yield()
            return try await activity.install(version: "2.0.0") {
                Issue.record("The updater started after video work began.")
                return nil
            }
        }
        for await _ in manualRequested {
            break
        }
        try #require(videoWork.beginWork())
        defer { videoWork.endWork() }
        resumePreparation.yield()
        await background.value
        #expect(try await manual.value == .videoWorkInProgress)
        #expect(!activity.isReplacingApp)
    }

    @Test
    func `quiet swap resumes once video work finishes and keeps its reservation`() async throws {
        let defaults = updateDefaults()
        let tiptoe = makeTiptoe(defaults: defaults)
        let videoWork = VideoWorkGate()
        let activity = UpdateActivity(tiptoe: tiptoe, videoWork: videoWork)
        let (installing, started) = AsyncStream<Void>.makeStream()
        try #require(videoWork.beginWork())
        try #require(videoWork.beginWork())
        activity.autoInstall = true
        await activity.check {
            await stage(candidate("2.0.0") {
                #expect(tiptoe.justUpdatedTo == "2.0.0")
                _ = makeTiptoe(defaults: defaults)
                #expect(tiptoe.justUpdatedTo == nil)
                #expect(activity.isReplacingApp)
                #expect(!videoWork.beginWork())
                started.yield()
            }, in: activity)
        }
        #expect(tiptoe.pending?.version == "2.0.0")
        #expect(tiptoe.justUpdatedTo == nil)
        // An explicit Tiptoe attempt bypasses its quiet checks. The swap still has to decline.
        await tiptoe.installNow().value
        #expect(!activity.isReplacingApp)
        #expect(activity.pendingVersion == "2.0.0")
        videoWork.endWork()
        #expect(tiptoe.pending == nil)
        videoWork.endWork()
        for await _ in installing {
            break
        }
        #expect(activity.isReplacingApp)
        tiptoe.stop()
    }

    @Test
    func `a quiet swap keeps its reservation until its failed operation returns`() async throws {
        let defaults = updateDefaults()
        let tiptoe = makeTiptoe(defaults: defaults, secondsSinceInput: 0)
        let videoWork = VideoWorkGate()
        let activity = UpdateActivity(tiptoe: tiptoe, videoWork: videoWork)
        activity.autoInstall = true
        await activity.check {
            await stage(candidate("2.0.0") {
                _ = makeTiptoe(defaults: defaults)
                #expect(tiptoe.justUpdatedTo == nil)
                #expect(activity.isReplacingApp)
                activity.autoInstall = false
                #expect(!Task.isCancelled)
                throw URLError(.cannotWriteToFile)
            }, in: activity)
        }
        await tiptoe.installNow().value
        #expect(!activity.isReplacingApp)
        #expect(tiptoe.justUpdatedTo == nil)
        try #require(videoWork.beginWork())
        videoWork.endWork()
    }

    @Test
    func `Update Now offline leaves an older held download untouched`() async throws {
        let tiptoe = makeTiptoe()
        let activity = UpdateActivity(tiptoe: tiptoe, videoWork: VideoWorkGate())
        var installs = 0
        await activity.check {
            await stage(candidate("2.0.0") { installs += 1 }, in: activity)
        }
        await #expect(throws: URLError.self) {
            _ = try await activity.install(version: "3.0.0") {
                throw URLError(.notConnectedToInternet)
            }
        }
        #expect(tiptoe.pending?.version == "2.0.0")
        #expect(activity.pendingVersion == "2.0.0")
        #expect(installs == 0)

        #expect(try await activity.install(version: "2.0.0") {
            Issue.record("The exact offline download was already verified.")
            return nil
        } == .attempted)
        #expect(installs == 1)
    }

    @Test(arguments: [false, true])
    func `a held download is discarded only after its replacement is ready`(replacementSucceeds: Bool) async throws {
        let tiptoe = makeTiptoe()
        let activity = UpdateActivity(tiptoe: tiptoe, videoWork: VideoWorkGate())
        var discarded = false
        var installedVersion: String?
        try await activity.prepare(.init(version: "2.0.0") {
            .init(install: { installedVersion = "2.0.0" }, discard: { discarded = true })
        })

        let replacement = UpdateActivity.Candidate(version: "3.0.0") {
            #expect(activity.pendingVersion == "2.0.0")
            #expect(tiptoe.pending?.version == "2.0.0")
            #expect(!discarded)
            guard replacementSucceeds else { throw URLError(.cannotDecodeContentData) }
            return .init(install: { installedVersion = "3.0.0" }, discard: {})
        }
        if replacementSucceeds {
            try await activity.prepare(replacement)
        } else {
            await #expect(throws: URLError.self) { try await activity.prepare(replacement) }
        }

        let held = replacementSucceeds ? "3.0.0" : "2.0.0"
        #expect(discarded == replacementSucceeds)
        #expect(activity.pendingVersion == held)
        #expect(tiptoe.pending?.version == held)
        #expect(try await activity.install(version: held) {
            Issue.record("The held update must be available offline.")
            return nil
        } == .attempted)
        #expect(installedVersion == held)
    }

    @Test(arguments: ["2.0.0", "4.0.0"])
    func `a different online candidate cannot replace the advertised version`(version: String) async throws {
        let activity = UpdateActivity(tiptoe: makeTiptoe(), videoWork: VideoWorkGate())
        let result = try await activity.install(version: "3.0.0") {
            .init(version: version) {
                Issue.record("A different version was prepared for the swap.")
                return .init(install: {}, discard: {})
            }
        }
        #expect(result == .noMatchingDownload)
        #expect(!activity.isReplacingApp)
    }

    private func candidate(_ version: String, install: @escaping @MainActor () async throws -> Void) -> UpdateActivity.Candidate {
        .init(version: version) { .init(install: install, discard: {}) }
    }

    private func stage(_ candidate: UpdateActivity.Candidate, in activity: UpdateActivity) async {
        do {
            try await activity.prepare(candidate)
        } catch {
            Issue.record(error)
        }
    }

    private func updateDefaults() -> UserDefaults {
        UserDefaults(suiteName: "UpdateActivityTests-\(UUID().uuidString)")!
    }

    private func makeTiptoe(defaults: UserDefaults? = nil, secondsSinceInput: TimeInterval = 600) -> Tiptoe {
        Tiptoe(
            environment: .init(
                now: { Date() },
                secondsSinceInput: { secondsSinceInput },
                windows: { .init(hasVisibleMainCapableWindow: false, hasUnsavedWork: false) },
                appVersion: { "1.0.0" },
            ),
            defaults: defaults ?? updateDefaults(),
        )
    }
}
