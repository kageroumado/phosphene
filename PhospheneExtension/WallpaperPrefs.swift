import Foundation
import os

/// Extension-side reader for shared preferences written by the main app,
/// and writer for extension state (isActive) read by the app.
///
/// Thread-safe via `OSAllocatedUnfairLock`. Observes `glass.kagerou.phosphene.prefsChanged`
/// Darwin notification to reload when the app writes new values.
final class WallpaperPrefs: @unchecked Sendable {
    static let shared = WallpaperPrefs()

    private struct PrefsFile: Codable {
        var userPaused: Bool
        var alwaysPauseDesktop: Bool
        var pauseWhenOccluded: Bool
        var desktopOccluded: Bool
        var pausedDisplays: Set<UInt32>?

        init(userPaused: Bool = false, alwaysPauseDesktop: Bool = false, pauseWhenOccluded: Bool = false, desktopOccluded: Bool = false, pausedDisplays: Set<UInt32>? = nil) {
            self.userPaused = userPaused
            self.alwaysPauseDesktop = alwaysPauseDesktop
            self.pauseWhenOccluded = pauseWhenOccluded
            self.desktopOccluded = desktopOccluded
            self.pausedDisplays = pausedDisplays
        }
    }

    private struct ContextState: Codable {
        var displayID: UInt32
        var videoID: String?
        var videoName: String?
    }

    private struct StateFile: Codable {
        var isActive: Bool
        var currentVideoID: String?
        var currentVideoName: String?
        var contexts: [ContextState]?
    }

    private let lock = OSAllocatedUnfairLock(initialState: PrefsFile())

    private static var docsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    }

    private static var prefsURL: URL {
        docsURL.appendingPathComponent("phosphene-prefs.json")
    }

    private static var stateURL: URL {
        docsURL.appendingPathComponent("phosphene-state.json")
    }

    private init() {
        reload()
    }

    // MARK: - Public (Prefs — app → extension)

    var userPaused: Bool {
        lock.withLock { $0.userPaused }
    }

    var alwaysPauseDesktop: Bool {
        lock.withLock { $0.alwaysPauseDesktop }
    }

    var pauseWhenOccluded: Bool {
        lock.withLock { $0.pauseWhenOccluded }
    }

    var desktopOccluded: Bool {
        lock.withLock { $0.desktopOccluded }
    }

    var pausedDisplays: Set<UInt32> {
        lock.withLock { $0.pausedDisplays ?? [] }
    }

    // MARK: - Public (State — extension → app)

    /// Call when the extension gains or loses active wallpaper contexts.
    func setActive(_ active: Bool) {
        let videoID = active ? WallpaperState.shared.currentVideoID : nil
        let videoName = videoID.flatMap { VideoLibrary.shared.entry(for: $0)?.name }
        let contexts = active ? buildContextStates() : nil
        let state = StateFile(isActive: active, currentVideoID: videoID, currentVideoName: videoName, contexts: contexts)
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: Self.stateURL, options: .atomic)
        postStateNotification()
        extensionLog("[WallpaperPrefs] setActive(\(active), video: \(videoName ?? "nil"))")
    }

    /// Call when the active video changes while the extension is already active.
    func updateCurrentVideo() {
        let videoID = WallpaperState.shared.currentVideoID
        let videoName = videoID.flatMap { VideoLibrary.shared.entry(for: $0)?.name }
        let contexts = buildContextStates()
        let state = StateFile(isActive: true, currentVideoID: videoID, currentVideoName: videoName, contexts: contexts)
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: Self.stateURL, options: .atomic)
        postStateNotification()
        traceLog("[WallpaperPrefs] updateCurrentVideo(\(videoName ?? "nil"))")
    }

    private func buildContextStates() -> [ContextState] {
        WallpaperState.shared.activeDisplayContexts().map { ctx in
            let name = ctx.videoID.flatMap { VideoLibrary.shared.entry(for: $0)?.name }
            return ContextState(displayID: ctx.displayID, videoID: ctx.videoID, videoName: name)
        }
    }

    // MARK: - Reload

    func reload() {
        let data: Data
        do {
            data = try Data(contentsOf: Self.prefsURL)
        } catch {
            return // File doesn't exist yet — normal on first launch
        }
        do {
            let prefs = try JSONDecoder().decode(PrefsFile.self, from: data)
            lock.withLock { state in
                state = prefs
            }
            traceLog("[WallpaperPrefs] Loaded: userPaused=\(prefs.userPaused), alwaysPauseDesktop=\(prefs.alwaysPauseDesktop), pauseWhenOccluded=\(prefs.pauseWhenOccluded), desktopOccluded=\(prefs.desktopOccluded)")
        } catch {
            extensionLog("[WallpaperPrefs] Failed to decode prefs: \(error)")
        }
    }

    // MARK: - Darwin Observer

    private var isObservingChanges = false

    func observeChanges() {
        guard !isObservingChanges else { return }
        isObservingChanges = true

        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            center,
            observer,
            { _, _, _, _, _ in
                WallpaperPrefs.shared.reload()
                WallpaperPrefs.shared.applyPauseState()
            },
            "glass.kagerou.phosphene.prefsChanged" as CFString,
            nil,
            .deliverImmediately,
        )
    }

    func stopObserving() {
        guard isObservingChanges else { return }
        isObservingChanges = false

        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterRemoveObserver(
            center,
            observer,
            CFNotificationName("glass.kagerou.phosphene.prefsChanged" as CFString),
            nil,
        )
    }

    /// Recompute playback policy and apply to all active renderers.
    /// Uses ramp animation for occlusion transitions (desktop covered/uncovered).
    private var previousDesktopOccluded = false

    private func applyPauseState() {
        let state = WallpaperState.shared
        let occlusionChanged = desktopOccluded != previousDesktopOccluded
        previousDesktopOccluded = desktopOccluded
        let animated = occlusionChanged && pauseWhenOccluded

        let displayIDs = state.uniqueDisplayIDs()
        let currentPausedDisplays = pausedDisplays

        let power = PowerMonitor.shared.currentState

        if displayIDs.isEmpty {
            // No per-display info — apply globally (backward compat)
            let policy = PlaybackPolicy.compute(
                presentationMode: state.presentationMode,
                activityState: state.activityState,
                userPaused: userPaused,
                alwaysPauseDesktop: alwaysPauseDesktop,
                pauseWhenOccluded: pauseWhenOccluded,
                desktopOccluded: desktopOccluded,
                powerState: power,
            )
            state.forEachRenderer { renderer in
                renderer.applyPolicy(policy, animated: animated)
            }
        } else {
            for displayID in displayIDs {
                let isDisplayPaused = currentPausedDisplays.contains(displayID)
                let policy = PlaybackPolicy.compute(
                    presentationMode: state.presentationMode,
                    activityState: state.activityState,
                    userPaused: userPaused || isDisplayPaused,
                    alwaysPauseDesktop: alwaysPauseDesktop,
                    pauseWhenOccluded: pauseWhenOccluded,
                    desktopOccluded: desktopOccluded,
                    powerState: power,
                )
                state.forRenderers(displayID: displayID) { renderer in
                    renderer.applyPolicy(policy, animated: animated)
                }
            }
        }
    }

    private func postStateNotification() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(
            center,
            CFNotificationName("glass.kagerou.phosphene.stateChanged" as CFString),
            nil,
            nil,
            true,
        )
    }
}
