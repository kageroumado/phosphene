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
        var occludedDisplays: Set<UInt32>?
        var pausedDisplays: Set<UInt32>?
        var screenSaverIsOurs: Bool?

        init(userPaused: Bool = false, alwaysPauseDesktop: Bool = false, pauseWhenOccluded: Bool = false, desktopOccluded: Bool = false, occludedDisplays: Set<UInt32>? = nil, pausedDisplays: Set<UInt32>? = nil, screenSaverIsOurs: Bool? = nil) {
            self.userPaused = userPaused
            self.alwaysPauseDesktop = alwaysPauseDesktop
            self.pauseWhenOccluded = pauseWhenOccluded
            self.desktopOccluded = desktopOccluded
            self.occludedDisplays = occludedDisplays
            self.pausedDisplays = pausedDisplays
            self.screenSaverIsOurs = screenSaverIsOurs
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

    /// Displays fully covered by windows, as computed by the app's OcclusionMonitor.
    var occludedDisplays: Set<UInt32> {
        lock.withLock { $0.occludedDisplays ?? [] }
    }

    /// Whether this display's wallpaper is invisible behind windows — either its
    /// own display is covered or every display is (global signal from an app
    /// version that predates per-display occlusion).
    func isOccluded(displayID: UInt32) -> Bool {
        desktopOccluded || occludedDisplays.contains(displayID)
    }

    var pausedDisplays: Set<UInt32> {
        lock.withLock { $0.pausedDisplays ?? [] }
    }

    /// Whether a Phosphene choice is the active screensaver (relayed by the app from
    /// the wallpaper store's Idle sections).
    var screenSaverIsOurs: Bool {
        lock.withLock { $0.screenSaverIsOurs ?? false }
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
    private var previousOccludedDisplays: Set<UInt32> = []

    private func applyPauseState() {
        let occlusionChanged = desktopOccluded != previousDesktopOccluded
            || occludedDisplays != previousOccludedDisplays
        previousDesktopOccluded = desktopOccluded
        previousOccludedDisplays = occludedDisplays

        let state = WallpaperState.shared
        applyPolicies(
            presentationMode: state.presentationMode,
            activityState: state.activityState,
            powerState: PowerMonitor.shared.currentState,
            animated: occlusionChanged && pauseWhenOccluded,
        )
    }

    /// Compute and apply the playback policy to every renderer — per display
    /// when per-display info exists, so per-display pause and occlusion survive
    /// global recomputes (thermal, battery, lock, presentation changes).
    func applyPolicies(
        presentationMode: String,
        activityState: String,
        powerState: PowerMonitor.PowerState,
        animated: Bool = false,
    ) {
        let state = WallpaperState.shared
        let displayIDs = state.uniqueDisplayIDs()

        func policy(for displayID: UInt32?) -> PlaybackPolicy {
            PlaybackPolicy.compute(
                presentationMode: presentationMode,
                activityState: activityState,
                userPaused: userPaused || displayID.map { pausedDisplays.contains($0) } ?? false,
                alwaysPauseDesktop: alwaysPauseDesktop,
                pauseWhenOccluded: pauseWhenOccluded,
                desktopOccluded: displayID.map(isOccluded(displayID:)) ?? desktopOccluded,
                screenSaverIsOurs: screenSaverIsOurs,
                powerState: powerState,
            )
        }

        if displayIDs.isEmpty {
            // No per-display info — apply globally (backward compat)
            let global = policy(for: nil)
            state.forEachRenderer { renderer in
                renderer.applyPolicy(global, animated: animated)
            }
        } else {
            for displayID in displayIDs {
                let displayPolicy = policy(for: displayID)
                state.forRenderers(displayID: displayID) { renderer in
                    renderer.applyPolicy(displayPolicy, animated: animated)
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
