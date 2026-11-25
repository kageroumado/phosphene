import Foundation
import Testing
import Tiptoe

@MainActor
struct UpdateActivityTests {
    @Test
    func `Update Now waits for the background check and reserves through the install`() async {
        let (preparing, started) = AsyncStream<Void>.makeStream()
        let (finishPreparation, resumePreparation) = AsyncStream<Void>.makeStream()
        let (manualRequested, requested) = AsyncStream<Void>.makeStream()
        let tiptoe = makeTiptoe()
        let activity = UpdateActivity(tiptoe: tiptoe) {
            requested.yield()
            return true
        }
        var completedPreparation = false
        var installed = false
        let background = Task {
            await activity.check {
                started.yield()
                for await _ in finishPreparation { break }
                completedPreparation = true
            }
        }
        for await _ in preparing { break }
        let manual = Task {
            await activity.install {
                #expect(completedPreparation)
                #expect(activity.isReplacingApp)
                await activity.check {
                    Issue.record("A background check started during Update Now.")
                }
                installed = true
            }
        }
        for await _ in manualRequested { break }
        #expect(!installed)
        #expect(!activity.isReplacingApp)
        resumePreparation.yield()
        await background.value
        #expect(await manual.value == .attempted)
        #expect(installed)
        #expect(!activity.isReplacingApp)
    }

    @Test
    func `running video work blocks manual installation before the adapter is called`() async {
        let activity = UpdateActivity(tiptoe: makeTiptoe(), videoIsIdle: { false })
        let result = await activity.install {
            Issue.record("The updater started while video work was active.")
        }
        #expect(result == .videoWorkInProgress)
    }

    @Test
    func `video work started during background preparation blocks manual installation`() async {
        let (preparing, started) = AsyncStream<Void>.makeStream()
        let (finishPreparation, resumePreparation) = AsyncStream<Void>.makeStream()
        let (manualRequested, requested) = AsyncStream<Void>.makeStream()
        let video = VideoWork()
        let activity = UpdateActivity(tiptoe: makeTiptoe()) {
            requested.yield()
            return video.isIdle
        }
        let background = Task {
            await activity.check {
                started.yield()
                for await _ in finishPreparation { break }
            }
        }
        for await _ in preparing { break }
        let manual = Task {
            await activity.install {
                Issue.record("The updater started after video work began.")
            }
        }
        for await _ in manualRequested { break }
        video.isIdle = false
        activity.videoWorkChanged()
        resumePreparation.yield()
        await background.value
        #expect(await manual.value == .videoWorkInProgress)
        #expect(!activity.isReplacingApp)
    }

    @Test
    func `quiet installs resume when video work finishes and reserve at handoff`() async {
        let tiptoe = makeTiptoe()
        let video = VideoWork()
        let activity = UpdateActivity(tiptoe: tiptoe) { video.isIdle }
        let (installing, started) = AsyncStream<Void>.makeStream()
        video.isIdle = false
        activity.autoInstall = true
        await activity.check {
            tiptoe.hold(version: "2.0.0") {
                #expect(activity.isReplacingApp)
                started.yield()
            }
        }
        #expect(tiptoe.pending?.version == "2.0.0")
        #expect(tiptoe.justUpdatedTo == nil)
        video.isIdle = true
        activity.videoWorkChanged()
        for await _ in installing { break }
        #expect(activity.isReplacingApp)
        tiptoe.stop()
    }

    @Test
    func `a failed quiet install releases the reservation after Tiptoe rolls back its notice`() async {
        let tiptoe = makeTiptoe()
        let activity = UpdateActivity(tiptoe: tiptoe, videoIsIdle: { true })
        tiptoe.hold(version: "2.0.0", retryable: false) {
            #expect(activity.isReplacingApp)
            throw CancellationError()
        }
        await tiptoe.installNow().value
        #expect(!activity.isReplacingApp)
        #expect(tiptoe.justUpdatedTo == nil)
    }

    private func makeTiptoe() -> Tiptoe {
        Tiptoe(
            environment: .init(
                now: { Date() },
                secondsSinceInput: { 600 },
                windows: { .init(hasVisibleMainCapableWindow: false, hasUnsavedWork: false) },
                appVersion: { "1.0.0" },
            ),
            defaults: UserDefaults(suiteName: "UpdateActivityTests-\(UUID().uuidString)")!,
        )
    }

    private final class VideoWork {
        var isIdle = true
    }
}
