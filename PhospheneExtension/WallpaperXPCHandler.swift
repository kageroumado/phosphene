// XPC handler implementing the WallpaperExtensionXPCProtocol.
//
// Handles lifecycle (acquire/update/invalidate/snapshot), settings,
// and stub methods for choices, downloads, migration, shuffle, and debug.

import AppKit
import AVFoundation
import CoreMedia
import os
import QuartzCore

/// One-way "this connection died" flag, shared between a handler and any of its
/// in-flight `acquire` Tasks. Sendable so a Task can capture it without retaining
/// the (non-Sendable) handler.
final class InvalidationFlag: Sendable {
    private let invalidated = OSAllocatedUnfairLock(initialState: false)
    var isInvalidated: Bool { invalidated.withLock { $0 } }
    func markInvalidated() { invalidated.withLock { $0 = true } }
}

final class WallpaperXPCHandler: NSObject, WallpaperExtensionXPCProtocol {
    /// Proxy to call methods on WallpaperAgent (ping, invalidateSnapshots, etc.).
    /// Lock-backed: it's assigned in `accept(connection:)` and nilled from the
    /// invalidation queue, while XPC callbacks read it from the message queue.
    /// The proxy existential isn't Sendable, so this uses a plain `NSLock` around
    /// `nonisolated(unsafe)` storage rather than `OSAllocatedUnfairLock` (whose
    /// `withLock` body is `@Sendable` and would reject the non-Sendable value).
    private let agentProxyLock = NSLock()
    nonisolated(unsafe) private var _agentProxy: (any WallpaperExtensionProxyXPCProtocol)?
    var agentProxy: (any WallpaperExtensionProxyXPCProtocol)? {
        get { agentProxyLock.lock(); defer { agentProxyLock.unlock() }; return _agentProxy }
        set { agentProxyLock.lock(); defer { agentProxyLock.unlock() }; _agentProxy = newValue }
    }

    /// Stable identity for this connection's handler. Every context this handler
    /// acquires is tagged with it, so the connection's invalidation tears down
    /// only its own contexts — never another connection's live render.
    let ownerToken = UUID()

    /// Set the moment this connection invalidates (before its contexts are torn
    /// down). An `acquire` Task started before the drop but resolving after it
    /// checks this under `WallpaperState`'s lock and refuses to store, so a late
    /// store can't leave an orphaned live context that masks future recovery.
    let invalidation = InvalidationFlag()

    /// PID of the peer on this connection (WallpaperAgent vs. Settings preview vs.
    /// the thumbnail service), set in `accept(connection:)`. Logged so acquire and
    /// invalidation can be attributed to a specific connection.
    var connectionPID: Int32 = -1

    // MARK: - Lifecycle

    func acquire(withId id: Any?, request: Any?, reply: @escaping @Sendable (Any?, (any Error)?) -> Void) {
        extensionLog("=== ACQUIRE ===")
        WallpaperState.shared.noteAcquire()

        // Extract WallpaperID UUID for mapping to context — required for cleanup in invalidate()
        var wallpaperIDString: String?
        if let idObj = id as? NSObject {
            let idStr = String(describing: Mirror(reflecting: idObj).children.first?.value ?? "")
            if let range = idStr.range(of: "[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}", options: .regularExpression) {
                wallpaperIDString = String(idStr[range])
            }
        }
        if wallpaperIDString == nil {
            extensionLog("  WARNING: Could not extract wallpaperID — context will not be individually removable")
        }

        // Extract destination size from WallpaperCreationRequestXPC
        var destSize = CGSize(width: 2_560, height: 1_440) // fallback
        var scaleFactor: CGFloat = 2.0
        var isPreview = false
        var displayID: UInt32?
        if let reqObj = request as? NSObject {
            let mirror = Mirror(reflecting: reqObj)
            for child in mirror.children {
                let reqMirror = Mirror(reflecting: child.value)
                for prop in reqMirror.children {
                    if prop.label == "destination" {
                        let destMirror = Mirror(reflecting: prop.value)
                        for destProp in destMirror.children {
                            if destProp.label == "size", let size = destProp.value as? CGSize {
                                destSize = size
                            } else if destProp.label == "scaleFactor", let sf = destProp.value as? CGFloat {
                                scaleFactor = sf
                            } else if destProp.label == "directDisplayID", let did = destProp.value as? UInt32 {
                                displayID = did
                            }
                        }
                    } else if prop.label == "isPreview", let preview = prop.value as? Bool {
                        isPreview = preview
                    } else if prop.label == "cacheDirectory" {
                        if let url = prop.value as? URL {
                            WallpaperState.shared.cacheDirectoryURL = url
                        }
                    }
                }
            }
        }
        // Extract choice configuration and files from descriptor via Mirror traversal
        // Path: WallpaperCreationRequestXPC.rawValue.descriptor.{configuration, files}
        var choiceConfiguration: String?
        var choiceFiles: [URL] = []
        if let reqObj = request as? NSObject {
            let mirror = Mirror(reflecting: reqObj)
            if let rawValue = mirror.children.first?.value {
                let rawMirror = Mirror(reflecting: rawValue)
                for prop in rawMirror.children where prop.label == "descriptor" {
                    let descMirror = Mirror(reflecting: prop.value)
                    for descProp in descMirror.children {
                        if descProp.label == "configuration" {
                            if let data = descProp.value as? Data, !data.isEmpty {
                                choiceConfiguration = String(data: data, encoding: .utf8)
                            }
                        } else if descProp.label == "files" {
                            if let urls = descProp.value as? [URL] {
                                choiceFiles = urls
                            }
                        }
                    }
                }
            }
            // If direct Mirror didn't work, try string description parsing as fallback
            if choiceConfiguration == nil {
                let desc = String(describing: reqObj)
                // Look for our identifier in the description
                if let idRange = desc.range(of: "identifier: \"") {
                    let after = desc[idRange.upperBound...]
                    if let endQuote = after.firstIndex(of: "\"") {
                        let identifier = String(after[..<endQuote])
                        extensionLog("  [Choice] Fallback extraction from description: identifier=\(identifier)")
                        choiceConfiguration = identifier
                    }
                }
            }
        }

        extensionLog("  destination: \(destSize) @\(scaleFactor)x, isPreview: \(isPreview), pid: \(connectionPID), id: \(wallpaperIDString ?? "nil"), choice: \(choiceConfiguration ?? "nil"), files: \(choiceFiles)")

        // Each acquire's `choiceConfiguration` is authoritative for *this* display's
        // context. Do NOT mutate the process-wide `currentVideoID` here based on a
        // diff — concurrent acquires for different displays would race and a renderer
        // can end up initialized with the wrong monitor's video. The global tracks
        // the last user-picked choice (via `selectedChoicesDidChange`); we only seed
        // it on first launch when UserDefaults has no value yet, so the menu-bar UI
        // has something sensible to show before the user picks anything.
        if WallpaperState.shared.currentVideoID == nil, let videoID = choiceConfiguration {
            WallpaperState.shared.currentVideoID = videoID
        }

        // 1. Create a remote CAContext for cross-process rendering. `remoteContext`
        // is purpose-built for CALayerHost hosting by another process (the Agent);
        // `contextWithCGSConnection:` binds to our own window-server connection and
        // the Agent hosts it slowly/unreliably (seconds of gray), so we use the
        // remote context. (It doesn't render a plain CALayer.contents cross-process
        // either — the still needs an IOSurface-backed layer — but hosting is fast.)
        var contextOptions: [String: Any] = [:]
        if let did = displayID {
            contextOptions["displayId"] = did
        }
        let caContextRaw: Any? = if contextOptions.isEmpty {
            CAContext.remoteContext()
        } else {
            CAContext.perform(NSSelectorFromString("remoteContextWithOptions:"), with: contextOptions)?.takeUnretainedValue()
        }
        guard let caContext = caContextRaw as? CAContext else {
            extensionLog("  ERROR: remote CAContext creation failed — failing acquire")
            reply(nil, NSError(domain: "PhospheneExtension", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "Failed to create remote CAContext",
            ]))
            return
        }
        extensionLog("  Created remote CAContext (id: \(caContext.contextId), options: \(contextOptions))")

        let contextId = caContext.contextId
        guard contextId != 0 else {
            extensionLog("  ERROR: CAContext has contextId 0 — creation failed")
            reply(nil, NSError(domain: "PhospheneExtension", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Failed to create CAContext",
            ]))
            return
        }

        // 2. Create WallpaperRemoteContextXPC early — needed before deferred reply
        guard let replyObj = createRemoteContextXPC(contextId: contextId) else {
            reply(nil, NSError(domain: "PhospheneExtension", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Failed to create WallpaperRemoteContextXPC",
            ]))
            return
        }

        // Thread-safe one-shot reply
        nonisolated(unsafe) let unsafeReplyObj = replyObj
        let hasReplied = OSAllocatedUnfairLock(initialState: false)
        let doReply: @Sendable (String) -> Void = { source in
            let shouldReply = hasReplied.withLock { replied in
                if replied { return false }
                replied = true
                return true
            }
            if shouldReply {
                extensionLog("  Replying to acquire [\(source)] (contextId: \(contextId))")
                reply(unsafeReplyObj, nil)
            }
        }

        // 3. Create root layer with cached snapshot as initial content
        let layerFrame = CGRect(origin: .zero, size: destSize)
        let rootLayer = CALayer()
        rootLayer.frame = layerFrame
        rootLayer.contentsScale = scaleFactor
        rootLayer.contentsGravity = .resizeAspectFill

        if let cachedImage = loadCachedSnapshotImage(forChoice: choiceConfiguration) {
            rootLayer.contents = cachedImage
            extensionLog("  Set cached snapshot as initial layer content")
        }

        // 4. Set up video rendering — resolve per this context's choice, not the
        // process-wide singleton, otherwise concurrent acquires can race.
        let videoURL = findVideoURL(forChoice: choiceConfiguration)

        // Sendable locals so the store path (sync fallback or async Task) tags the
        // context with this connection and can refuse a store after invalidation.
        let owner = ownerToken
        let invalidation = invalidation

        if let videoURL {
            extensionLog("  Setting up VideoRenderer with: \(videoURL.lastPathComponent)")

            // 5. Set layer on context and flush to WindowServer immediately.
            caContext.layer = rootLayer
            CATransaction.flush()

            // Re-bind non-Sendable locals for Task capture safety
            nonisolated(unsafe) let unsafeCAContext = caContext
            nonisolated(unsafe) let unsafeRootLayer = rootLayer

            Task {
                let videoRenderer: VideoRenderer
                do {
                    videoRenderer = try await VideoRenderer.create(
                        rootLayer: unsafeRootLayer, videoURL: videoURL,
                    )
                } catch {
                    extensionLog("  [Renderer] Failed to create: \(error)")
                    doReply("renderer failed")
                    return
                }

                // Adaptive playback at loop boundaries. Capture the per-context
                // videoID from this acquire — each rendering scope keeps its own
                // selection. Reading the global `currentVideoID` would cause every
                // renderer to converge on whichever choice was set most recently
                // (multi-monitor bug: after one loop, all monitors play the same video).
                let perContextVideoID = choiceConfiguration
                videoRenderer.variantSelector = {
                    guard let videoID = perContextVideoID else {
                        return videoURL
                    }
                    let power = PowerMonitor.shared.currentState
                    let prefs = WallpaperPrefs.shared
                    let state = WallpaperState.shared
                    let policy = PlaybackPolicy.compute(
                        presentationMode: state.presentationMode,
                        activityState: state.activityState,
                        userPaused: prefs.userPaused,
                        alwaysPauseDesktop: prefs.alwaysPauseDesktop,
                        pauseWhenOccluded: prefs.pauseWhenOccluded,
                        desktopOccluded: prefs.desktopOccluded,
                        powerState: power,
                    )
                    return VideoLibrary.shared.bestVariantURL(for: videoID, policy: policy) ?? videoURL
                }

                // Stop any existing renderer for this wallpaperID before storing.
                // If this connection invalidated while the renderer was being
                // created, refuse the store and discard the renderer — otherwise it
                // would orphan a live context tagged to a dead connection and mask
                // future recovery.
                let outcome = WallpaperState.shared.storeContext(
                    ActiveWallpaper(caContext: unsafeCAContext, rootLayer: unsafeRootLayer, renderer: videoRenderer, displayID: displayID, videoID: choiceConfiguration, isPreview: isPreview, owner: owner),
                    id: contextId,
                    wallpaperID: wallpaperIDString,
                    abortIfInvalidated: { invalidation.isInvalidated },
                )
                switch outcome {
                case .ownerInvalidated:
                    videoRenderer.stop()
                    extensionLog("  Connection invalidated mid-acquire — discarded renderer (contextId: \(contextId))")
                    doReply("connection gone")
                    return
                case let .stored(existing):
                    if let existing {
                        existing.renderer?.stop()
                        invalidateRemoteContext(existing.caContext)
                        extensionLog("  Stopped existing renderer for wallpaperID: \(wallpaperIDString ?? "?")")
                    }
                }
                // A live desktop render is up — cancel any pending recovery.
                if !isPreview {
                    RecoveryCoordinator.shared.cancel()
                }
                WallpaperPrefs.shared.setActive(true)

                // 6. Start renderer, then defer reply for the render pipeline to
                // stabilize (the Agent shows its cached BMP snapshot meanwhile).
                videoRenderer.start()
                try? await Task.sleep(for: .milliseconds(500))
                doReply("pipeline ready")
            }

            // Safety net timeout
            DispatchQueue.global().asyncAfter(deadline: .now() + 5.0) {
                doReply("timeout")
            }

            // Write BMP snapshot cache — keyed on this context's choice, not the
            // global, so each display gets its own correctly-keyed snapshot file.
            if !isPreview {
                let displayW = Int(destSize.width * scaleFactor)
                let displayH = Int(destSize.height * scaleFactor)
                Task {
                    await writeBMPSnapshot(videoURL: videoURL, videoID: choiceConfiguration, displayPixelWidth: displayW, displayPixelHeight: displayH)
                }
            }
        } else {
            extensionLog("  No video file found — using solid color fallback")
            let gradientLayer = CAGradientLayer()
            gradientLayer.colors = [
                CGColor(red: 0.2, green: 0.0, blue: 0.5, alpha: 1.0),
                CGColor(red: 0.0, green: 0.3, blue: 0.7, alpha: 1.0),
                CGColor(red: 0.0, green: 0.6, blue: 0.4, alpha: 1.0),
            ]
            gradientLayer.startPoint = CGPoint(x: 0, y: 0)
            gradientLayer.endPoint = CGPoint(x: 1, y: 1)
            gradientLayer.frame = layerFrame
            gradientLayer.contentsScale = scaleFactor
            rootLayer.addSublayer(gradientLayer)

            caContext.layer = rootLayer
            let outcome = WallpaperState.shared.storeContext(
                ActiveWallpaper(caContext: caContext, rootLayer: rootLayer, renderer: nil, displayID: displayID, videoID: choiceConfiguration, isPreview: isPreview, owner: owner),
                id: contextId,
                wallpaperID: wallpaperIDString,
                abortIfInvalidated: { invalidation.isInvalidated },
            )
            if case .stored = outcome, !isPreview {
                RecoveryCoordinator.shared.cancel()
            }

            doReply("no video")
        }
    }

    private var previousPresentationMode = "default"

    func update(withId _: Any?, request: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        // Extract presentation mode / activity state by walking the request's Mirror
        // for the named properties and reading the enum case, rather than scanning a
        // stringified description (which silently fell through to "?" — and so failed
        // to pause — whenever the description format didn't match). Default to the
        // benign desktop-active values if a field genuinely can't be found.
        var presentationMode = "default"
        var activityState = "active"
        if let request {
            if let mode = mirrorFindProperty("presentationMode", in: request) {
                presentationMode = enumCaseName(mode)
            }
            if let activity = mirrorFindProperty("activityState", in: request) {
                activityState = enumCaseName(activity)
            }
        }

        // Store current mode/state so other policy paths use the correct values.
        WallpaperState.shared.presentationMode = presentationMode
        WallpaperState.shared.activityState = activityState

        // Agent is the authoritative source for presentation mode.
        // Clear the screen-lock override when the Agent confirms the screen isn't locked.
        WallpaperState.shared.isScreenLocked = (presentationMode == "locked")

        let prefs = WallpaperPrefs.shared
        let power = PowerMonitor.shared.currentState

        let policy = PlaybackPolicy.compute(
            presentationMode: presentationMode,
            activityState: activityState,
            userPaused: prefs.userPaused,
            alwaysPauseDesktop: prefs.alwaysPauseDesktop,
            pauseWhenOccluded: prefs.pauseWhenOccluded,
            desktopOccluded: prefs.desktopOccluded,
            powerState: power,
        )

        // Apple-like ramp when alwaysPauseDesktop is on:
        // desktop → lock = ramp up (start playing), lock → desktop = ramp down (pause).
        // Only ramp when activity is active (suspended = hard pause, process may sleep).
        let modeChanged = presentationMode != previousPresentationMode
        let animated = prefs.alwaysPauseDesktop
            && activityState == "active"
            && modeChanged

        WallpaperState.shared.forEachRenderer { renderer in
            renderer.applyPolicy(policy, animated: animated)
        }

        previousPresentationMode = presentationMode
        extensionLog("=== UPDATE === mode: \(presentationMode), activity: \(activityState)")
        reply(nil)
    }

    func invalidate(withId id: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        var cleaned = false
        if let idObj = id as? NSObject {
            let idStr = String(describing: Mirror(reflecting: idObj).children.first?.value ?? "")
            if let range = idStr.range(of: "[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}", options: .regularExpression) {
                let uuid = String(idStr[range])
                if let active = WallpaperState.shared.removeContext(wallpaperID: uuid) {
                    active.renderer?.stop()
                    invalidateRemoteContext(active.caContext)
                    cleaned = true
                } else {
                    extensionLog("  WARNING: No context found for wallpaperID \(uuid)")
                }
            } else {
                extensionLog("  WARNING: Could not extract UUID from id: \(idStr)")
            }
        } else {
            extensionLog("  WARNING: invalidate called with nil id")
        }
        let remaining = WallpaperState.shared.activeContextCount
        WallpaperPrefs.shared.setActive(WallpaperState.shared.liveContextCount > 0)
        extensionLog("=== INVALIDATE === (cleaned: \(cleaned), remaining: \(remaining))")
        reply(nil)
    }

    func snapshot(withId _: Any?, reply: @escaping @Sendable (Any?, (any Error)?) -> Void) {
        extensionLog("=== SNAPSHOT ===")

        // Get current time from any active renderer for a more representative snapshot
        var currentTime: CMTime?
        WallpaperState.shared.forEachRenderer { renderer in
            currentTime = CMTimebaseGetTime(renderer.timebase)
        }

        Task {
            if let snapshotXPC = await createSnapshotViaRuntime(currentTime: currentTime) {
                reply(snapshotXPC, nil)
                extensionLog("  Snapshot replied (IOSurface)")
            } else {
                reply(nil, nil)
                extensionLog("  Snapshot replied (nil)")
            }
        }
    }

    // MARK: - Settings

    func provideSettingsViewModels(withContentTypes _: Any?, reply: @escaping @Sendable (Any?, (any Error)?) -> Void) {
        extensionLog("=== PROVIDE SETTINGS VIEW MODELS ===")

        Task {
            if let result = await buildSettingsViewModelsXPC() {
                extensionLog("  [Settings] Remapped to \(NSStringFromClass(type(of: result as AnyObject)))")
                reply(result, nil)
            } else {
                extensionLog("  [Settings] Build failed, using empty fallback")
                reply(makeEmptyGroupsResponse(), nil)
            }
        }
    }

    // MARK: - Choices

    func addChoiceRequest(withChoiceRequest request: Any?, onBehalfOfProcess process: Any?, reply: @escaping @Sendable (Any?, (any Error)?) -> Void) {
        extensionLog("=== ADD CHOICE REQUEST ===")
        reply(nil, nil)
    }

    func removeChoiceRequest(withChoiceRequest request: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        extensionLog("=== REMOVE CHOICE REQUEST ===")

        // Extract video ID from the choice request using Mirror (same pattern as selectedChoicesDidChange)
        var videoID: String?
        if let reqObj = request as? NSObject {
            let desc = String(describing: reqObj)
            if let range = desc.range(of: "identifier: \"") {
                let after = desc[range.upperBound...]
                if let endQuote = after.firstIndex(of: "\"") {
                    videoID = String(after[..<endQuote])
                }
            }
        }

        guard let videoID else {
            extensionLog("  [Remove] Could not extract video ID from request")
            reply(nil)
            return
        }

        extensionLog("  [Remove] Removing video: \(videoID)")

        // Remove from library (deletes files + metadata)
        VideoLibrary.shared.removeVideo(id: videoID)

        // Stop only the renderers whose context was actually using this video —
        // other displays may be playing different videos and must keep running.
        let stoppedDisplays = WallpaperState.shared.stopRenderers(forVideoID: videoID)
        if !stoppedDisplays.isEmpty {
            if WallpaperState.shared.currentVideoID == videoID {
                WallpaperState.shared.currentVideoID = nil
                WallpaperState.shared.cachedThumbnailURL = nil
            }
            WallpaperPrefs.shared.updateCurrentVideo()
            extensionLog("  [Remove] Stopped \(stoppedDisplays.count) renderer(s) for removed video")
        }

        // Invalidate Agent snapshots so Settings refreshes
        if let proxy = agentProxy {
            proxy.invalidateSnapshots { error in
                if let error {
                    extensionLog("  [Remove] invalidateSnapshots error: \(error)")
                }
            }
        }

        reply(nil)
    }

    func selectedChoicesDidChange(for id: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        extensionLog("=== SELECTED CHOICES DID CHANGE ===")

        // Extract the choice identifier from the WallpaperChoiceID
        var choiceIdentifier: String?
        if let idObj = id as? NSObject {
            let mirror = Mirror(reflecting: idObj)
            for child in mirror.children {
                let desc = String(describing: child.value)
                // Look for the identifier field which contains our video UUID
                if let range = desc.range(of: "identifier: \"") {
                    let after = desc[range.upperBound...]
                    if let endQuote = after.firstIndex(of: "\"") {
                        choiceIdentifier = String(after[..<endQuote])
                    }
                }
            }
        }

        guard let videoID = choiceIdentifier else {
            extensionLog("selectedChoicesDidChange: unknown choice \(String(describing: choiceIdentifier))")
            reply(nil)
            return
        }

        guard VideoLibrary.shared.entry(for: videoID) != nil else {
            extensionLog("selectedChoicesDidChange: unknown video \(videoID)")
            reply(nil)
            return
        }

        extensionLog("=== CHOICE CHANGED === videoID: \(videoID)")

        // Track the last user-picked video (for menu-bar UI / new-acquire fallback).
        // The XPC API does NOT tell us which display this choice is for — only that
        // the user picked it. We can't safely touch any renderer here; doing so used
        // to flip the wrong display, because stopping all renderers forced macOS to
        // re-acquire every display, and the racing acquires would pick up the wrong
        // per-context choiceConfiguration. macOS issues `invalidate(oldID)` and
        // `acquire(newID)` for the affected display on its own; let it.
        WallpaperState.shared.currentVideoID = videoID
        WallpaperState.shared.cachedThumbnailURL = nil
        WallpaperPrefs.shared.updateCurrentVideo()

        // Invalidate Agent snapshots so the picker re-fetches with the new video.
        if let proxy = agentProxy {
            proxy.invalidateSnapshots { error in
                if let error {
                    extensionLog("  [Choice] invalidateSnapshots error: \(error)")
                }
            }
        }

        reply(nil)
    }

    func invokeContextMenuAction(withMenuItemID menuItemID: Any?, groupItemID _: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        let identifier = (menuItemID as? String) ?? String(describing: menuItemID ?? "nil")
        extensionLog("=== CONTEXT MENU ACTION === identifier: \(identifier)")

        if identifier == "add-video" {
            extensionLog("  Launching companion app via NSWorkspace")
            if let url = URL(string: "phosphene://add-video") {
                let opened = NSWorkspace.shared.open(url)
                extensionLog("  NSWorkspace.open = \(opened)")
            }
        }

        reply(nil)
    }

    // MARK: - Downloads

    func isChoiceDownloaded(with _: Any?, reply: @escaping @Sendable (Bool, (any Error)?) -> Void) {
        extensionLog("isChoiceDownloaded")
        reply(true, nil)
    }

    func download(withChoiceID _: Any?, reply: ((any Error)?) -> Void) -> Any? {
        extensionLog("download")
        reply(nil)
        return nil
    }

    func pauseDownload(for _: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        reply(nil)
    }

    func cancelDownload(for _: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        reply(nil)
    }

    func resumeDownload(for _: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        reply(nil)
    }

    func removeDownload(for _: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        reply(nil)
    }

    // MARK: - Migration

    func migrateSelectedChoice(for _: Any?, reply: @escaping @Sendable (Any?, (any Error)?) -> Void) {
        extensionLog("migrateSelectedChoice")
        reply(nil, nil)
    }

    func migrate(from _: Any?, to _: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        extensionLog("migrate")
        reply(nil)
    }

    // MARK: - Shuffle

    func skipShuffledContent(withId _: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        extensionLog("skipShuffledContent")
        reply(nil)
    }

    func canSkipShuffledContent(withId _: Any?, reply: @escaping @Sendable (Bool, (any Error)?) -> Void) {
        extensionLog("canSkipShuffledContent")
        reply(false, nil)
    }

    // MARK: - Debug & Notifications

    func handleDebugRequest(for _: Any?, reply: @escaping @Sendable (Any?, (any Error)?) -> Void) {
        extensionLog("handleDebugRequest")
        reply(nil, nil)
    }

    func handleNotification(withNamed name: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        extensionLog("handleNotification(\(name ?? "nil"))")
        reply(nil)
    }
}

/// Recursively search a value's `Mirror` for a stored property with the given
/// label, to a shallow depth. Robust to the XPC wrapper nesting, unlike scanning
/// a stringified description.
private func mirrorFindProperty(_ label: String, in value: Any, depth: Int = 0) -> Any? {
    guard depth < 6 else { return nil }
    for child in Mirror(reflecting: value).children {
        if child.label == label { return child.value }
        if let found = mirrorFindProperty(label, in: child.value, depth: depth + 1) { return found }
    }
    return nil
}

/// Extract an enum case name from a value: `.idle` → `"idle"`,
/// `.suspended(reason)` → `"suspended"`. Falls back to `String(describing:)` for
/// non-enums or payload-less cases (whose description is already the case name).
private func enumCaseName(_ value: Any) -> String {
    let mirror = Mirror(reflecting: value)
    if mirror.displayStyle == .enum, let label = mirror.children.first?.label {
        return label
    }
    return String(describing: value)
}
