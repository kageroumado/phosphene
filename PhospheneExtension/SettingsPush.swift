import Foundation

/// Pushes freshly built settings view models to every live host connection.
///
/// The system caches each provider's view models on disk and — on macOS 26.6, unlike
/// 26.5 — serves that cache on every Settings launch, re-querying the extension only
/// after an extension (re)installation or an OS update. Without a push, a library
/// change made between queries never becomes visible; in particular, the first query
/// fires at registration, before the user has added any video, so a fresh install
/// caches an empty group and the Phosphene section stays missing across reboots
/// (issue #27). `updateSettingsViewModels` is the host callback that refreshes that
/// cache and updates an open Settings pane in place.
enum SettingsPush {
    /// One entry per live XPC connection, registered in `accept(connection:)` and
    /// removed by the connection's invalidation handler. Weak so a connection that
    /// dies without unregistering can't pin its handler. `NSLock` around
    /// `nonisolated(unsafe)` storage because `WallpaperXPCHandler` and its proxy
    /// are non-Sendable (same pattern as the handler's own `agentProxy`).
    private struct WeakHandler {
        weak var handler: WallpaperXPCHandler?
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var handlers: [WeakHandler] = []

    static func register(_ handler: WallpaperXPCHandler) {
        lock.lock()
        defer { lock.unlock() }
        handlers.removeAll { $0.handler == nil }
        handlers.append(WeakHandler(handler: handler))
    }

    static func unregister(_ handler: WallpaperXPCHandler) {
        lock.lock()
        defer { lock.unlock() }
        handlers.removeAll { $0.handler == nil || $0.handler === handler }
    }

    /// Pending debounce work. Touched only on the main thread — Darwin
    /// notifications are delivered on the registering thread's run loop, and the
    /// observer is registered from the extension's init on main.
    private nonisolated(unsafe) static var pending: DispatchWorkItem?

    /// Debounced entry point for library-change notifications: a burst of changes
    /// (an import plus its rename, a multi-file drop) collapses into one rebuild
    /// half a second after the last one.
    static func libraryDidChange() {
        pending?.cancel()
        let work = DispatchWorkItem {
            pending = nil
            Task { await push() }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Snapshot the live proxies synchronously — `NSLock` may not be taken from an
    /// async context.
    private static func liveProxies() -> [any WallpaperExtensionProxyXPCProtocol] {
        lock.lock()
        defer { lock.unlock() }
        return handlers.compactMap { $0.handler?.agentProxy }
    }

    /// Build the current view models once and send them over every live connection.
    static func push() async {
        guard let models = await buildSettingsViewModelsXPC() else {
            extensionLog("[SettingsPush] Build failed — nothing pushed")
            return
        }
        let proxies = liveProxies()
        guard !proxies.isEmpty else {
            extensionLog("[SettingsPush] No live host connection — cache refreshes on the next query")
            return
        }
        extensionLog("[SettingsPush] Pushing view models to \(proxies.count) connection(s)")
        for proxy in proxies {
            proxy.updateSettingsViewModels(models) { error in
                if let error {
                    extensionLog("[SettingsPush] updateSettingsViewModels error: \(error)")
                }
            }
        }
    }
}
