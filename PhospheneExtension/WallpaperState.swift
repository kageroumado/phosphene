// Thread-safe shared state for the wallpaper extension.
//
// All access goes through `OSAllocatedUnfairLock`-protected accessors
// so concurrent XPC callbacks don't race.

import Foundation
import os
import QuartzCore

struct ActiveWallpaper: @unchecked Sendable {
    let caContext: AnyObject // CAContext (private class, hold as AnyObject)
    let rootLayer: CALayer
    let renderer: VideoRenderer?
    let displayID: UInt32?
    let videoID: String?
    /// `true` for Settings/picker preview acquires (`WallpaperCreationRequest.isPreview`).
    /// Only non-preview contexts represent the live desktop render we must protect.
    let isPreview: Bool
    /// Identity of the XPC connection that created this context. A connection only
    /// owns the contexts it acquired, so its teardown must not touch another
    /// connection's render (the cross-connection clobber behind issue #13).
    let owner: UUID
}

final class WallpaperState: Sendable {
    static let shared = WallpaperState()

    private static let selectedVideoKey = "selectedVideoID"

    private struct State: @unchecked Sendable {
        var activeContexts: [UInt32: ActiveWallpaper] = [:]
        var wallpaperIDToContext: [String: UInt32] = [:]
        var acquireGeneration: Int = 0
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
            .deliverImmediately
        )
    }

    /// Clear cached URLs so the next lookup re-evaluates against the current library.
    private func clearCaches() {
        lock.withLock { state in
            state.cachedThumbnailURL = nil
        }
    }

    // MARK: - Acquire Activity

    /// Monotonic counter bumped at the start of every `acquire`. The recovery
    /// path compares it across the grace window: if it changed, WallpaperAgent is
    /// actively acquiring (e.g. rapid wallpaper switching) and a momentarily-empty
    /// live set is just a transient gap, not the genuine quiescent loss that
    /// warrants a recovery exit.
    func noteAcquire() {
        lock.withLock { $0.acquireGeneration += 1 }
    }

    var acquireGeneration: Int {
        lock.withLock { $0.acquireGeneration }
    }

    // MARK: - Context Management

    /// Result of attempting to store a context.
    enum StoreOutcome {
        /// Stored; `replaced` is any prior context for the same wallpaperID (stop its renderer).
        case stored(replaced: ActiveWallpaper?)
        /// Refused because the owning connection invalidated mid-acquire.
        case ownerInvalidated
    }

    /// Store a new rendering context, stopping any existing renderer for the same
    /// wallpaperID. `abortIfInvalidated` is evaluated under the lock so the
    /// store and the owning connection's teardown can't interleave: if the
    /// connection died while this acquire was in flight, the store is refused and
    /// no orphaned context is left behind.
    func storeContext(_ context: ActiveWallpaper, id: UInt32, wallpaperID: String?, abortIfInvalidated: @Sendable () -> Bool) -> StoreOutcome {
        lock.withLock { state in
            if abortIfInvalidated() { return .ownerInvalidated }
            var existing: ActiveWallpaper?
            if let wid = wallpaperID, let oldId = state.wallpaperIDToContext[wid] {
                existing = state.activeContexts.removeValue(forKey: oldId)
            }
            state.activeContexts[id] = context
            if let wid = wallpaperID {
                state.wallpaperIDToContext[wid] = id
            }
            return .stored(replaced: existing)
        }
    }

    /// Remove and return the context for a wallpaperID UUID string.
    func removeContext(wallpaperID: String) -> ActiveWallpaper? {
        lock.withLock { state in
            guard let contextId = state.wallpaperIDToContext.removeValue(forKey: wallpaperID) else { return nil }
            return state.activeContexts.removeValue(forKey: contextId)
        }
    }

    /// Execute a closure for each active renderer (snapshot copy under lock, iteration outside).
    func forEachRenderer(_ body: (VideoRenderer) -> Void) {
        let renderers = lock.withLock { state in
            state.activeContexts.values.compactMap(\.renderer)
        }
        for renderer in renderers {
            body(renderer)
        }
    }

    /// Execute a closure for renderers on a specific display.
    func forRenderers(displayID: UInt32, _ body: (VideoRenderer) -> Void) {
        let renderers = lock.withLock { state in
            state.activeContexts.values
                .filter { $0.displayID == displayID }
                .compactMap(\.renderer)
        }
        for renderer in renderers {
            body(renderer)
        }
    }

    /// Stop and remove every renderer whose context owns the given videoID.
    /// Returns the displayIDs that were affected so callers can log/react.
    /// Other contexts keep running — they belong to displays with a different choice.
    @discardableResult
    func stopRenderers(forVideoID videoID: String) -> [UInt32?] {
        let affected = lock.withLock { state -> [(UInt32, ActiveWallpaper)] in
            let matches = state.activeContexts.filter { $0.value.videoID == videoID }
            for (contextId, _) in matches {
                state.activeContexts.removeValue(forKey: contextId)
            }
            state.wallpaperIDToContext = state.wallpaperIDToContext.filter { state.activeContexts[$0.value] != nil }
            return matches.map { ($0.key, $0.value) }
        }
        for (_, ctx) in affected {
            ctx.renderer?.stop()
        }
        return affected.map { $0.1.displayID }
    }

    /// All unique display IDs from active contexts.
    func uniqueDisplayIDs() -> Set<UInt32> {
        lock.withLock { state in
            Set(state.activeContexts.values.compactMap(\.displayID))
        }
    }

    /// Get active context info for each unique display.
    func activeDisplayContexts() -> [(displayID: UInt32, videoID: String?)] {
        lock.withLock { state in
            var seen = Set<UInt32>()
            var result: [(displayID: UInt32, videoID: String?)] = []
            for ctx in state.activeContexts.values {
                guard let did = ctx.displayID, seen.insert(did).inserted else { continue }
                result.append((displayID: did, videoID: ctx.videoID))
            }
            return result
        }
    }

    var activeContextCount: Int {
        lock.withLock { $0.activeContexts.count }
    }

    /// Count of live (non-preview) desktop render contexts. Preview contexts from
    /// the Settings picker don't count — losing them must not look like losing the
    /// desktop wallpaper.
    var liveContextCount: Int {
        lock.withLock { state in
            state.activeContexts.values.lazy.filter { !$0.isPreview }.count
        }
    }

    /// Remove and stop only the contexts owned by the given XPC connection. Other
    /// connections' contexts (e.g. the live desktop render owned by WallpaperAgent)
    /// are left untouched. Returns the removed contexts.
    @discardableResult
    func removeContexts(ownedBy owner: UUID) -> [ActiveWallpaper] {
        let removed = lock.withLock { state -> [ActiveWallpaper] in
            let matches = state.activeContexts.filter { $0.value.owner == owner }
            for (contextId, _) in matches {
                state.activeContexts.removeValue(forKey: contextId)
            }
            state.wallpaperIDToContext = state.wallpaperIDToContext.filter { state.activeContexts[$0.value] != nil }
            return Array(matches.values)
        }
        for ctx in removed {
            ctx.renderer?.stop()
        }
        return removed
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
