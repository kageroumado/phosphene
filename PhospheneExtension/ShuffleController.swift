import Foundation
import os

/// Drives the native "Shuffle All" choice: owns the current pick, advances it on the
/// schedule the user selected in System Settings, and retargets live renderers in
/// place via `switchVideo` (no re-acquire, no system re-selection).
///
/// The system treats `shuffle-all` as a first-class shuffle selection (the wallpaper
/// store files it under `Choices/Shuffle`), but rotation itself is the provider's
/// job — the host only supplies the frequency (an optionValues entry keyed
/// "shuffleFrequency") and the skip affordance (`skipShuffledContent`).
final class ShuffleController: @unchecked Sendable {
    static let shared = ShuffleController()

    private let queue = DispatchQueue(label: "glass.kagerou.phosphene.shuffle")
    private let lock = OSAllocatedUnfairLock(initialState: State())
    private var timer: (any DispatchSourceTimer)?

    private struct State {
        /// Whether any surface is currently acquired with the shuffle choice.
        var active = false
        var pick: String?
        var frequency: ShuffleFrequencyID = .onWakeup
        var lastAdvance: Date?
        /// A scheduled advance fired while the display slept or playback was paused;
        /// applied at the next wake.
        var pendingAdvance = false
        /// onLogin advances once per extension lifetime.
        var advancedThisLaunch = false
    }

    private enum Keys {
        static let pick = "shufflePick"
        static let lastAdvance = "shuffleLastAdvance"
    }

    private init() {
        let pick = UserDefaults.standard.string(forKey: Keys.pick)
        let lastAdvance = UserDefaults.standard.object(forKey: Keys.lastAdvance) as? Date
        lock.withLock { state in
            state.pick = pick
            state.lastAdvance = lastAdvance
        }
    }

    // MARK: - Choice resolution

    var isActive: Bool {
        lock.withLock { $0.active }
    }

    /// Map the shuffle sentinel to the current concrete video id; any other choice
    /// passes through untouched. Establishes a pick on first use.
    func resolveChoice(_ choice: String?) -> String? {
        guard choice == shuffleChoiceID else { return choice }
        return currentOrNewPick()
    }

    /// Called for every acquire. Activates/deactivates shuffle mode and adopts the
    /// frequency the host sent in the descriptor's optionValues (nil = keep current,
    /// which starts at the picker's declared default).
    func noteAcquire(choice: String?, frequencyID: String?) {
        let isShuffle = choice == shuffleChoiceID
        let frequency = frequencyID.flatMap(ShuffleFrequencyID.init(rawValue:))
        let (becameActive, frequencyChanged) = lock.withLock { state in
            let wasActive = state.active
            let oldFrequency = state.frequency
            // A non-shuffle acquire does not deactivate by itself — another display
            // may still be on shuffle. Deactivation happens when no shuffle context
            // remains (checked below).
            if isShuffle { state.active = true }
            if let frequency { state.frequency = frequency }
            return (isShuffle && !wasActive, state.frequency != oldFrequency)
        }
        if !isShuffle {
            // The acquire updates its context's videoID after this call returns —
            // check for remaining shuffle contexts once that has settled.
            queue.asyncAfter(deadline: .now() + 1.0) { [self] in syncActiveWithContexts() }
            return
        }
        if becameActive || frequencyChanged {
            extensionLog("[Shuffle] active, frequency=\(lock.withLock(\.frequency).rawValue)")
            armTimerIfNeeded()
        }
        if becameActive {
            // onLogin advances once per extension lifetime, at the first activation
            // (extension launch and login-session start coincide for wallpaper
            // extensions — the system spawns one per login session).
            let advanceForLogin = lock.withLock { state in
                guard state.frequency == .onLogin, !state.advancedThisLaunch else { return false }
                state.advancedThisLaunch = true
                return true
            }
            if advanceForLogin {
                queue.async { [self] in advance(reason: "login") }
            }
        }
    }

    /// Called when the host reports a frequency change outside an acquire (option
    /// edits can arrive on the update path).
    func noteFrequencyChange(_ frequencyID: String?) {
        guard let frequency = frequencyID.flatMap(ShuffleFrequencyID.init(rawValue:)) else { return }
        let changed = lock.withLock { state in
            let old = state.frequency
            state.frequency = frequency
            return old != frequency
        }
        if changed {
            extensionLog("[Shuffle] frequency changed → \(frequency.rawValue)")
            armTimerIfNeeded()
        }
    }

    /// Deactivate when no acquired context carries the shuffle choice anymore
    /// (the user picked a specific video, or all shuffle surfaces were torn down).
    func syncActiveWithContexts() {
        let stillShuffling = WallpaperState.shared.hasContext(forVideoID: shuffleChoiceID)
        let deactivated = lock.withLock { state in
            let was = state.active
            state.active = stillShuffling
            return was && !stillShuffling
        }
        if deactivated {
            let inventory = WallpaperState.shared.activeDisplayContexts()
                .map { "display \($0.displayID): \($0.videoID ?? "nil")" }
                .joined(separator: ", ")
            extensionLog("[Shuffle] no shuffle contexts remain — deactivated (contexts: [\(inventory)])")
            queue.async { [self] in stopTimer() }
        }
    }

    // MARK: - Advance triggers

    /// Display woke (or screen unlocked). Applies the onWakeup schedule, flushes a
    /// pending timed advance, and catches up a timed schedule that elapsed during sleep.
    func noteWake() {
        let (shouldAdvance, reason): (Bool, String) = lock.withLock { state in
            guard state.active else { return (false, "") }
            switch state.frequency {
            case .onWakeup:
                return (true, "wake")
            case .onLogin:
                return (false, "")
            default:
                if state.pendingAdvance { return (true, "pending tick") }
                if let interval = state.frequency.interval,
                   let last = state.lastAdvance,
                   Date().timeIntervalSince(last) > interval {
                    return (true, "elapsed during sleep")
                }
                return (false, "")
            }
        }
        if shouldAdvance {
            queue.async { [self] in advance(reason: reason) }
        }
    }

    /// Host asked to skip to the next item (the system shuffle affordance).
    /// Returns false when shuffle isn't active.
    func skip() -> Bool {
        guard isActive else { return false }
        queue.async { [self] in advance(reason: "skip") }
        return true
    }

    // MARK: - Private

    private func currentOrNewPick() -> String? {
        let existing = lock.withLock(\.pick)
        let library = VideoLibrary.shared.entries.map(\.id)
        if let existing, library.contains(existing) { return existing }
        guard let fresh = library.randomElement() else { return nil }
        setPick(fresh)
        return fresh
    }

    private func setPick(_ pick: String) {
        lock.withLock { state in
            state.pick = pick
            state.lastAdvance = Date()
        }
        let defaults = UserDefaults.standard
        defaults.set(pick, forKey: Keys.pick)
        defaults.set(Date(), forKey: Keys.lastAdvance)
    }

    private func armTimerIfNeeded() {
        queue.async { [self] in
            stopTimer()
            guard let interval = lock.withLock(\.frequency).interval else { return }
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now() + interval, repeating: interval)
            source.setEventHandler { [weak self] in self?.tick() }
            timer = source
            source.resume()
        }
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }

    private func tick() {
        guard isActive else { return }
        // Switching while nothing is visible would fight the paused policy and waste
        // a decode; defer to the next wake instead.
        if WallpaperState.shared.isDisplayAsleep {
            lock.withLock { $0.pendingAdvance = true }
            traceLog("[Shuffle] tick deferred — display asleep")
            return
        }
        advance(reason: "timer")
    }

    /// Pick the next video and retarget every live renderer that sits on a shuffle
    /// context. Runs on `queue`.
    private func advance(reason: String) {
        lock.withLock { $0.pendingAdvance = false }
        let library = VideoLibrary.shared.entries.map(\.id)
        guard library.count >= 2 else {
            traceLog("[Shuffle] advance skipped — \(library.count) video(s) in library")
            return
        }
        let current = lock.withLock(\.pick)
        var next = library.randomElement() ?? library[0]
        if next == current {
            let index = library.firstIndex(of: next) ?? 0
            next = library[(index + 1) % library.count]
        }
        guard let url = VideoLibrary.shared.videoURL(for: next) else {
            extensionLog("[Shuffle] advance failed — no file for \(next)")
            return
        }
        setPick(next)

        let renderers = WallpaperState.shared.renderers(forVideoID: shuffleChoiceID)
        for renderer in renderers {
            renderer.variantSelector = makeVariantSelector(choice: next, fallback: url)
            renderer.switchVideo(to: url)
        }
        // switchVideo restarts the pipeline running; immediately re-assert the
        // current policy so a paused surface (alwaysPauseDesktop, occlusion, …)
        // pauses again instead of playing through.
        PhospheneExtension.recomputeAndApplyPolicy()

        WallpaperState.shared.currentVideoID = next
        WallpaperPrefs.shared.updateCurrentVideo()
        extensionLog("[Shuffle] advanced to \(next) on \(renderers.count) renderer(s) (\(reason))")
    }
}
