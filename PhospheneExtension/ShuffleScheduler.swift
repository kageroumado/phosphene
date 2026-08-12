//
//  ShuffleScheduler.swift
//  PhospheneExtension
//
//  Created by Nathan Ellis on 12/08/2026.
//

import Foundation
import os

final class ShuffleScheduler: @unchecked Sendable {
    static let shared = ShuffleScheduler()

    private let queue = DispatchQueue(label: "glass.kagerou.phosphene.shuffle")
    private let lock = OSAllocatedUnfairLock(initialState: State())

    private struct State {
        var enabled = false
        var pick: String?
    }

    private var timer: DispatchSourceTimer?

    private init() {}

    func startObserving() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        for name in ["glass.kagerou.phosphene.prefsChanged", "glass.kagerou.phosphene.libraryChanged"] {
            CFNotificationCenterAddObserver(
                center,
                observer,
                { _, _, _, _, _ in ShuffleScheduler.shared.reconfigure() },
                name as CFString,
                nil,
                .deliverImmediately,
            )
        }
        reconfigure()
    }

    func activeOverride() -> String? {
        lock.withLock { $0.enabled ? $0.pick : nil }
    }

    func reconfigure() {
        queue.async { [self] in
            let prefs = WallpaperPrefs.shared
            guard prefs.shuffleEnabled else {
                stopTimer()
                lock.withLock { $0.enabled = false; $0.pick = nil }
                extensionLog("[Shuffle] disabled")
                return
            }

            let pool = currentPool()
            guard pool.count >= 2 else {
                stopTimer()
                lock.withLock { $0.enabled = true; $0.pick = pool.first }
                extensionLog("[Shuffle] enabled but pool has \(pool.count) video(s) — nothing to rotate")
                return
            }

            let seed = lock.withLock { state -> String in
                let existing = WallpaperState.shared.currentVideoID
                let start = (existing.map(pool.contains) == true ? existing : pool.randomElement()) ?? pool[0]
                state.enabled = true
                state.pick = start
                return start
            }
            apply(pick: seed)
            armTimer(interval: prefs.shuffleIntervalSeconds)
            extensionLog("[Shuffle] enabled — \(pool.count) videos, every \(prefs.shuffleIntervalSeconds)s, starting on \(seed)")
        }
    }

    // MARK: - Private

    private func currentPool() -> [String] {
        let library = VideoLibrary.shared.entries.map(\.id)
        guard let chosen = WallpaperPrefs.shared.shuffleVideoIDs else { return library }
        let allowed = Set(chosen)
        return library.filter(allowed.contains)
    }

    private func armTimer(interval: Int) {
        stopTimer()
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + .seconds(interval), repeating: .seconds(interval))
        source.setEventHandler { [weak self] in self?.tick() }
        timer = source
        source.resume()
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }

    private func tick() {
        let state = WallpaperState.shared
        guard !state.isDisplayAsleep, !WallpaperPrefs.shared.userPaused else {
            traceLog("[Shuffle] tick skipped — display asleep or paused")
            return
        }

        let pool = currentPool()
        guard pool.count >= 2 else { return }

        let next = lock.withLock { s -> String in
            var candidate = pool.randomElement() ?? pool[0]
            if pool.count > 1, candidate == s.pick {
                let index = pool.firstIndex(of: candidate) ?? 0
                candidate = pool[(index + 1) % pool.count]
            }
            s.pick = candidate
            return candidate
        }
        apply(pick: next)
        traceLog("[Shuffle] rotated to \(next)")
    }

    private func apply(pick: String) {
        guard let url = VideoLibrary.shared.videoURL(for: pick),
              FileManager.default.fileExists(atPath: url.path) else {
            extensionLog("[Shuffle] pick \(pick) has no file — skipping")
            return
        }
        WallpaperState.shared.currentVideoID = pick
        let renderers = WallpaperState.shared.retargetAllRenderers(toVideoID: pick)
        for renderer in renderers {
            renderer.variantSelector = makeVariantSelector(choice: pick, fallback: url)
            renderer.switchVideo(to: url)
        }
        WallpaperPrefs.shared.updateCurrentVideo()
    }
}
