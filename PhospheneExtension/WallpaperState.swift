import Foundation
import os
import QuartzCore

/// One persistent per-display rendering slot. Reused across acquires (Apple's
/// model): the `caContext`/`contextId`/`rootLayer` live for the display's lifetime
/// and only the `renderer`/`videoID` swap when the wallpaper changes — so the Agent
/// never drops the context on switch (no gray gap) and contexts never accumulate.
struct ActiveWallpaper: @unchecked Sendable {
    let caContext: AnyObject // CAContext (private class, hold as AnyObject)
    let contextId: UInt32
    let rootLayer: CALayer
    var renderer: VideoRenderer?
    let displayID: UInt32?
    var videoID: String?
    /// True while a `VideoRenderer.create` is in flight for this slot. Prevents a
    /// second (e.g. preview) acquire from spinning up a *duplicate* renderer on the
    /// same rootLayer while the first acquire's async create hasn't populated
    /// `renderer` yet. Cleared when the renderer is set or the create fails.
    var rendererPending: Bool = false
}

/// Identifies one hosted wallpaper SURFACE — a distinct `CAContext`/layer tree that
/// WallpaperAgent hosts in one `CALayerHost`. There is one per **WallpaperID UUID**,
/// i.e. one per Space, per lock-screen surface, and per Settings preview.
///
/// This used to be keyed by `displayID` alone (one shared context per display), on the
/// assumption that every consumer of a display hosts the same surface. That's wrong:
/// macOS keeps multiple Spaces' wallpaper surfaces (plus the lock screen) *live at once*,
/// each a separate WallpaperID with its own `acquire`, and a `CAContext` can only be
/// hosted in ONE `CALayerHost` at a time. Handing the same `contextId` to two Spaces made
/// the second steal the surface and the first go black (permanent on a space switch, a
/// transient flash during the desktop↔lock reveal). Keying by the WallpaperID UUID gives
/// each surface its own context, so none can steal another's. `displayID` is retained for
/// display-level fan-out (policy, per-display switch).
struct DisplayKey: Hashable {
    let displayID: UInt32
    let surfaceUUID: UUID
}

final class WallpaperState: Sendable {
    static let shared = WallpaperState()

    private static let selectedVideoKey = "selectedVideoID"

    private struct State: @unchecked Sendable {
        /// Persistent contexts keyed by display slot. Reused across acquires.
        var contexts: [DisplayKey: ActiveWallpaper] = [:]
        /// WallpaperID UUID → its surface key, learned at acquire. Lets `invalidate(UUID)`
        /// resolve which surface context to tear down. Each surface owns its context, so an
        /// invalidate tears down only that surface — no cross-surface interference.
        var keyForWallpaperUUID: [UUID: DisplayKey] = [:]
        var cachedThumbnailURL: URL?
        var cacheDirectoryURL: URL?
        var currentVideoID: String? = UserDefaults.standard.string(forKey: WallpaperState.selectedVideoKey)
        var presentationMode: String = "active"
        var activityState: String = "active"
        var isDisplayAsleep: Bool = false
        var isScreenLocked: Bool = false
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())

    private init() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            center,
            observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let state = Unmanaged<WallpaperState>.fromOpaque(observer).takeUnretainedValue()
                state.clearCaches()
            },
            "glass.kagerou.phosphene.libraryChanged" as CFString,
            nil,
            .deliverImmediately,
        )
    }

    /// Clear cached URLs so the next lookup re-evaluates against the current library.
    private func clearCaches() {
        lock.withLock { state in
            state.cachedThumbnailURL = nil
        }
    }

    // MARK: - Context Management (persistent, reused per display)

    /// The existing persistent context for a display slot, if any.
    func context(for key: DisplayKey) -> ActiveWallpaper? {
        lock.withLock { $0.contexts[key] }
    }

    /// Install a freshly-created context for a display slot (first acquire).
    func installContext(_ context: ActiveWallpaper, for key: DisplayKey) {
        lock.withLock { $0.contexts[key] = context }
    }

    /// Atomically claim the right to create the renderer for a slot. Returns true
    /// only if the slot has no renderer AND no create is already in flight — in
    /// which case it marks a create pending. A concurrent (preview) acquire gets
    /// false and must NOT create a duplicate renderer. This is what guarantees
    /// exactly one renderer per display despite racing desktop+preview acquires.
    func claimRendererCreate(for key: DisplayKey) -> Bool {
        let claimed = lock.withLock { state -> Bool in
            guard var context = state.contexts[key] else { return false }
            if context.renderer != nil || context.rendererPending { return false }
            context.rendererPending = true
            state.contexts[key] = context
            return true
        }
        traceLog("  [claimRendererCreate] display=\(key.displayID) → \(claimed ? "CLAIMED (will create)" : "denied (renderer exists or create pending)")")
        return claimed
    }

    /// Release a create claim without installing a renderer (create threw).
    func clearRendererPending(for key: DisplayKey) {
        lock.withLock { state in
            guard var context = state.contexts[key] else { return }
            context.rendererPending = false
            state.contexts[key] = context
        }
    }

    /// Swap the renderer for an existing display slot (the wallpaper changed),
    /// keeping the same `caContext`/`contextId`/`rootLayer`. Returns the previous
    /// renderer for the caller to stop.
    func setRenderer(_ renderer: VideoRenderer?, videoID: String?, for key: DisplayKey) -> VideoRenderer? {
        let previous = lock.withLock { state -> VideoRenderer? in
            guard var context = state.contexts[key] else { return nil }
            let previous = context.renderer
            context.renderer = renderer
            context.videoID = videoID
            context.rendererPending = false
            state.contexts[key] = context
            return previous
        }
        traceLog("  [setRenderer] display=\(key.displayID) new=\(renderer.map { "#\($0.debugID)" } ?? "nil") replacing=\(previous.map { "#\($0.debugID)" } ?? "nil") videoID=\(videoID ?? "nil")")
        return previous
    }

    /// Update the videoID a slot is tracking after an in-place `switchVideo`
    /// (the renderer object is unchanged — only its content switched).
    func updateVideoID(_ videoID: String?, for key: DisplayKey) {
        lock.withLock { state in
            guard var context = state.contexts[key] else { return }
            context.videoID = videoID
            state.contexts[key] = context
        }
    }

    /// Execute a closure for each active renderer (snapshot copy under lock, iteration outside).
    func forEachRenderer(_ body: (VideoRenderer) -> Void) {
        let renderers = lock.withLock { state in
            state.contexts.values.compactMap(\.renderer)
        }
        for renderer in renderers {
            body(renderer)
        }
    }

    /// Execute a closure for renderers on a specific display.
    func forRenderers(displayID: UInt32, _ body: (VideoRenderer) -> Void) {
        let renderers = lock.withLock { state in
            state.contexts.values
                .filter { $0.displayID == displayID }
                .compactMap(\.renderer)
        }
        for renderer in renderers {
            body(renderer)
        }
    }

    /// Tear down (stop renderer + invalidate context) every display slot using the
    /// given videoID — the video was removed from the library, so its slots are
    /// genuinely gone (not a reuse). Returns affected displayIDs.
    @discardableResult
    func removeContexts(forVideoID videoID: String) -> [UInt32?] {
        let removed = lock.withLock { state -> [ActiveWallpaper] in
            let matches = state.contexts.filter { $0.value.videoID == videoID }
            for (key, _) in matches {
                state.contexts.removeValue(forKey: key)
            }
            return Array(matches.values)
        }
        for context in removed {
            context.renderer?.stop()
            invalidateRemoteContext(context.caContext)
        }
        return removed.map(\.displayID)
    }

    // MARK: - WallpaperID ↔ display bridge (for per-display invalidate/teardown)

    /// Learned at acquire: this WallpaperID UUID maps to this surface `key`, so a later
    /// `invalidate(UUID)` can resolve which surface context to tear down.
    func registerWallpaperID(_ uuid: UUID, key: DisplayKey) {
        lock.withLock { $0.keyForWallpaperUUID[uuid] = key }
    }

    /// The surface key an invalidate's WallpaperID targets, if we know it.
    func resolveWallpaperKey(_ uuid: UUID) -> DisplayKey? {
        lock.withLock { $0.keyForWallpaperUUID[uuid] }
    }

    /// Drop a WallpaperID mapping once its instance is invalidated.
    func forgetWallpaperID(_ uuid: UUID) {
        lock.withLock { _ = $0.keyForWallpaperUUID.removeValue(forKey: uuid) }
    }

    /// Per-surface teardown (the invalidate grace timer fired with no re-acquire — the Space
    /// closed, the preview dismissed, or the display slept): stop ONLY this surface's renderer
    /// and `-[CAContext invalidate]` its context, leaving other surfaces playing. Returns
    /// whether it tore down.
    @discardableResult
    func tearDownContext(for key: DisplayKey) -> Bool {
        let removed = lock.withLock { state -> ActiveWallpaper? in
            state.contexts.removeValue(forKey: key)
        }
        guard let removed else { return false }
        removed.renderer?.stop()
        invalidateRemoteContext(removed.caContext)
        return true
    }

    /// All unique display IDs from active contexts.
    func uniqueDisplayIDs() -> Set<UInt32> {
        lock.withLock { state in
            Set(state.contexts.values.compactMap(\.displayID))
        }
    }

    /// Get active context info for each unique display.
    func activeDisplayContexts() -> [(displayID: UInt32, videoID: String?)] {
        lock.withLock { state in
            var seen = Set<UInt32>()
            var result: [(displayID: UInt32, videoID: String?)] = []
            for context in state.contexts.values {
                guard let did = context.displayID, seen.insert(did).inserted else { continue }
                result.append((displayID: did, videoID: context.videoID))
            }
            return result
        }
    }

    var activeContextCount: Int {
        lock.withLock { $0.contexts.count }
    }

    /// Count of display slots with a running renderer.
    var liveContextCount: Int {
        lock.withLock { state in
            state.contexts.values.lazy.count(where: { $0.renderer != nil })
        }
    }

    // MARK: - Properties

    var cachedThumbnailURL: URL? {
        get { lock.withLock { $0.cachedThumbnailURL } }
        set { lock.withLock { $0.cachedThumbnailURL = newValue } }
    }

    var cacheDirectoryURL: URL? {
        get { lock.withLock { $0.cacheDirectoryURL } }
        set { lock.withLock { $0.cacheDirectoryURL = newValue } }
    }

    /// Currently selected video ID, persisted to UserDefaults.
    var currentVideoID: String? {
        get { lock.withLock { $0.currentVideoID } }
        set {
            lock.withLock { $0.currentVideoID = newValue }
            UserDefaults.standard.set(newValue, forKey: WallpaperState.selectedVideoKey)
        }
    }

    // MARK: - Display & Presentation State

    /// Last known presentation mode from the framework's `update()` call.
    var presentationMode: String {
        get { lock.withLock { $0.presentationMode } }
        set { lock.withLock { $0.presentationMode = newValue } }
    }

    /// Last known activity state from the framework's `update()` call.
    var activityState: String {
        get { lock.withLock { $0.activityState } }
        set { lock.withLock { $0.activityState = newValue } }
    }

    /// Whether all displays are currently asleep.
    var isDisplayAsleep: Bool {
        get { lock.withLock { $0.isDisplayAsleep } }
        set { lock.withLock { $0.isDisplayAsleep = newValue } }
    }

    /// Whether the screen is currently locked (lock screen showing).
    /// Tracked via `com.apple.screenIsLocked` / `com.apple.screenIsUnlocked`
    /// distributed notifications.
    var isScreenLocked: Bool {
        get { lock.withLock { $0.isScreenLocked } }
        set { lock.withLock { $0.isScreenLocked = newValue } }
    }
}

/// Force the WindowServer to reclaim a remote `CAContext`. Dropping our Swift
/// reference (ARC) is NOT enough: the context is refcounted across processes, and
/// WallpaperAgent's `CALayerHost` keeps the context's layer tree resident in the
/// render server until it's explicitly invalidated. Without this, every wallpaper
/// switch leaves a pinned tree behind → escalating composite cost / gray, reset
/// only by `killall WallpaperAgent`. `-[CAContext invalidate]` reclaims it even
/// while a consumer host is still attached.
func invalidateRemoteContext(_ caContext: AnyObject) {
    let sel = NSSelectorFromString("invalidate")
    guard let object = caContext as? NSObject, object.responds(to: sel) else { return }
    object.perform(sel)
}
