import Foundation
import Observation
import os

/// One surface's current target, observed by that surface's renderer alone. Keeping
/// each target in its own object means a change on one surface wakes only the
/// renderer following it.
@MainActor @Observable
final class SurfaceTargetCell {
    var target: SurfaceTarget

    init(_ target: SurfaceTarget) {
        self.target = target
    }
}

/// The single owner of playback state. Every input arrives as a `PlaybackEvent`
/// through `send`, which runs the pure reducer and republishes the derived targets.
/// Renderers follow their surface's target with `Observations`, so a renderer that
/// attaches late starts from the current target and never misses an earlier event.
@MainActor @Observable
final class PlaybackStore {
    static let shared = PlaybackStore()

    private(set) var state: PlaybackState

    @ObservationIgnored private var cells: [SurfaceKey: SurfaceTargetCell] = [:]
    @ObservationIgnored private var publisher: Task<Void, Never>?

    /// A copy of `state` readable from any thread, for code on the XPC and renderer
    /// queues that needs to peek without hopping to the main actor.
    private nonisolated static let mirror = OSAllocatedUnfairLock(initialState: PlaybackState())

    private enum Keys {
        static let lastVideoID = "selectedVideoID"
    }

    private static var stateURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("phosphene-state.json")
    }

    private init() {
        var seed = PlaybackState()
        seed.lastVideoID = UserDefaults.standard.string(forKey: Keys.lastVideoID)
        let initial = seed
        state = initial
        Self.mirror.withLock { $0 = initial }
    }

    // MARK: - Events

    /// Deliver an event from any thread. Delivery is synchronous on the main thread
    /// and FIFO from every other thread, so events from one source keep their order.
    nonisolated static func post(_ event: PlaybackEvent) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { shared.send(event) }
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated { shared.send(event) } }
        }
    }

    func send(_ event: PlaybackEvent) {
        let next = PlaybackReducer.reduce(state, event)
        traceLog("[Store] \(event)")
        guard next != state else { return }
        state = next
        Self.mirror.withLock { $0 = next }
        republishTargets()
    }

    private func republishTargets() {
        let targets = PlaybackReducer.targets(state)
        for (key, target) in targets {
            if let cell = cells[key] {
                if cell.target != target {
                    cell.target = target
                }
            } else {
                cells[key] = SurfaceTargetCell(target)
            }
        }
        for key in cells.keys where targets[key] == nil {
            cells[key] = nil
        }
    }

    // MARK: - Renderers

    /// Make `renderer` follow `key`'s target for as long as it runs. The current target
    /// is applied before this returns, so a `start()` issued afterwards already plays
    /// or holds according to it.
    func follow(_ renderer: VideoRenderer, surface key: SurfaceKey) {
        guard let cell = cells[key] else {
            extensionLog("[Store] follow: no surface \(key) — renderer #\(renderer.debugID) held paused")
            renderer.apply(.paused)
            return
        }
        renderer.apply(cell.target)
        renderer.setFollowTask(Task(name: "Follow \(key)") {
            for await target in Observations({ cell.target }) {
                renderer.apply(target)
            }
        })
    }

    // MARK: - Snapshot reads

    nonisolated static var snapshot: PlaybackState {
        mirror.withLock { $0 }
    }

    /// The video the desktop shows, or last showed.
    nonisolated static var currentVideoID: String? {
        PlaybackReducer.published(snapshot).currentVideoID
    }

    // MARK: - Publishing

    /// Keep `phosphene-state.json` equal to the derived published state.
    func startPublishing() {
        guard publisher == nil else { return }
        publisher = Task(name: "Publish extension state") {
            var last: PublishedState?
            for await published in Observations({ PlaybackReducer.published(self.state) }) {
                guard published != last else { continue }
                last = published
                Self.write(published)
            }
        }
    }

    private struct StateFile: Encodable {
        struct Context: Encodable {
            let displayID: UInt32
            let videoID: String?
            let videoName: String?
        }

        let isActive: Bool
        let currentVideoID: String?
        let currentVideoName: String?
        let contexts: [Context]
    }

    private static func write(_ published: PublishedState) {
        let library = VideoLibrary.shared
        let file = StateFile(
            isActive: published.isActive,
            currentVideoID: published.currentVideoID,
            currentVideoName: published.currentVideoID.flatMap { library.entry(for: $0)?.name },
            contexts: published.displays.map {
                StateFile.Context(displayID: $0.displayID, videoID: $0.videoID, videoName: $0.videoID.flatMap { library.entry(for: $0)?.name })
            },
        )
        if let data = try? JSONEncoder().encode(file) {
            try? data.write(to: stateURL, options: .atomic)
        }
        UserDefaults.standard.set(published.currentVideoID, forKey: Keys.lastVideoID)
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName("glass.kagerou.phosphene.stateChanged" as CFString),
            nil, nil, true,
        )
        extensionLog("[Store] published: active=\(published.isActive) video=\(file.currentVideoName ?? "nil")")
    }
}
