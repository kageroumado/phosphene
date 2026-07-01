// XPC handler implementing the WallpaperExtensionXPCProtocol.
//
// Handles lifecycle (acquire/update/invalidate/snapshot), settings,
// and stub methods for choices, downloads, migration, shuffle, and debug.

import AppKit
import AVFoundation
import CoreMedia
import os
import QuartzCore

/// Builds the adaptive variant selector for a renderer. Captures only Sendable
/// values (the choice ID + a fallback URL), so it can cross into the render Task.
/// Reading the per-context `choice` (not the process-wide `currentVideoID`) keeps
/// each display on its own selection — otherwise every renderer would converge on
/// whichever choice was set most recently (multi-monitor bug).
func makeVariantSelector(choice: String?, fallback: URL) -> () -> URL {
    return {
        guard let videoID = choice else { return fallback }
        let state = WallpaperState.shared
        let prefs = WallpaperPrefs.shared
        let policy = PlaybackPolicy.compute(
            presentationMode: state.presentationMode,
            activityState: state.activityState,
            userPaused: prefs.userPaused,
            alwaysPauseDesktop: prefs.alwaysPauseDesktop,
            pauseWhenOccluded: prefs.pauseWhenOccluded,
            desktopOccluded: prefs.desktopOccluded,
            powerState: PowerMonitor.shared.currentState,
        )
        return VideoLibrary.shared.bestVariantURL(for: videoID, policy: policy) ?? fallback
    }
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

    /// PID of the peer on this connection (WallpaperAgent vs. Settings preview vs.
    /// the thumbnail service), set in `accept(connection:)`. Logged so acquire and
    /// invalidation can be attributed to a specific connection.
    var connectionPID: Int32 = -1

    // MARK: - Lifecycle

    func acquire(withId id: Any?, request: Any?, reply: @escaping @Sendable (Any?, (any Error)?) -> Void) {
        extensionLog("=== ACQUIRE ===")

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

        extensionLog("  destination: \(destSize) @\(scaleFactor)x, isPreview: \(isPreview), pid: \(connectionPID), choice: \(choiceConfiguration ?? "nil"), files: \(choiceFiles)")

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

        let key = DisplayKey(displayID: displayID ?? 0, isPreview: isPreview)
        let videoURL = findVideoURL(forChoice: choiceConfiguration)
        let cachedStill = loadCachedSnapshotImage(forChoice: choiceConfiguration)

        // ---- REUSE: a persistent context already exists for this display slot ----
        // Return the SAME contextId so the Agent keeps hosting the live context
        // (it never drops it → no gray gap, no accumulation). Only swap the video
        // if the choice actually changed; re-selecting the same wallpaper is a no-op.
        if let existing = WallpaperState.shared.context(for: key) {
            guard let replyObj = createRemoteContextXPC(contextId: existing.contextId) else {
                reply(nil, NSError(domain: "PhospheneExtension", code: 3, userInfo: nil)); return
            }
            reply(replyObj, nil)

            if existing.videoID == choiceConfiguration, existing.renderer != nil {
                extensionLog("  Reused context \(existing.contextId) (display \(key.displayID), preview \(key.isPreview)) — same choice, no swap")
                return
            }
            guard let videoURL else {
                extensionLog("  Reused context \(existing.contextId) — no video for new choice, keeping current")
                return
            }
            extensionLog("  Reused context \(existing.contextId) — swapping to \(videoURL.lastPathComponent)")
            nonisolated(unsafe) let unsafeRoot = existing.rootLayer
            let selector = makeVariantSelector(choice: choiceConfiguration, fallback: videoURL)
            Task {
                let renderer: VideoRenderer
                do {
                    renderer = try await VideoRenderer.create(rootLayer: unsafeRoot, videoURL: videoURL, stillImage: cachedStill)
                } catch {
                    extensionLog("  [Renderer] swap create failed: \(error)"); return
                }
                renderer.variantSelector = selector
                let old = WallpaperState.shared.setRenderer(renderer, videoID: choiceConfiguration, for: key)
                old?.stop()
                WallpaperPrefs.shared.setActive(true)
                renderer.start()
            }
            if !isPreview {
                let w = Int(destSize.width * scaleFactor), h = Int(destSize.height * scaleFactor)
                Task { await writeBMPSnapshot(videoURL: videoURL, videoID: choiceConfiguration, displayPixelWidth: w, displayPixelHeight: h) }
            }
            return
        }

        // ---- CREATE: first acquire for this display slot ----
        var contextOptions: [String: Any] = [:]
        if let did = displayID { contextOptions["displayId"] = did }
        let caContextRaw: Any? = contextOptions.isEmpty
            ? CAContext.remoteContext()
            : CAContext.perform(NSSelectorFromString("remoteContextWithOptions:"), with: contextOptions)?.takeUnretainedValue()
        guard let caContext = caContextRaw as? CAContext, caContext.contextId != 0 else {
            extensionLog("  ERROR: remote CAContext creation failed — failing acquire")
            reply(nil, NSError(domain: "PhospheneExtension", code: 4, userInfo: [NSLocalizedDescriptionKey: "Failed to create remote CAContext"]))
            return
        }
        let contextId = caContext.contextId

        let layerFrame = CGRect(origin: .zero, size: destSize)
        let rootLayer = CALayer()
        rootLayer.frame = layerFrame
        rootLayer.contentsScale = scaleFactor
        rootLayer.contentsGravity = .resizeAspectFill
        if let cachedStill { rootLayer.contents = cachedStill }
        caContext.layer = rootLayer
        CATransaction.flush()

        guard let replyObj = createRemoteContextXPC(contextId: contextId) else {
            reply(nil, NSError(domain: "PhospheneExtension", code: 3, userInfo: nil)); return
        }

        // Install the persistent slot now (renderer added async) so a concurrent
        // acquire for the same display reuses this context instead of creating another.
        WallpaperState.shared.installContext(
            ActiveWallpaper(caContext: caContext, contextId: contextId, rootLayer: rootLayer, renderer: nil, displayID: displayID, isPreview: isPreview, videoID: choiceConfiguration),
            for: key
        )
        reply(replyObj, nil)
        extensionLog("  Created context \(contextId) for display \(key.displayID), preview \(key.isPreview)")

        guard let videoURL else {
            // No video file — solid gradient fallback.
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
            CATransaction.begin(); CATransaction.setDisableActions(true)
            rootLayer.addSublayer(gradientLayer)
            CATransaction.commit(); CATransaction.flush()
            extensionLog("  No video file found — solid color fallback")
            return
        }

        extensionLog("  Setting up VideoRenderer with: \(videoURL.lastPathComponent)")
        nonisolated(unsafe) let unsafeRoot = rootLayer
        let selector = makeVariantSelector(choice: choiceConfiguration, fallback: videoURL)
        Task {
            let renderer: VideoRenderer
            do {
                renderer = try await VideoRenderer.create(rootLayer: unsafeRoot, videoURL: videoURL, stillImage: cachedStill)
            } catch {
                extensionLog("  [Renderer] Failed to create: \(error)"); return
            }
            renderer.variantSelector = selector
            let old = WallpaperState.shared.setRenderer(renderer, videoID: choiceConfiguration, for: key)
            old?.stop()
            WallpaperPrefs.shared.setActive(true)
            renderer.start()
        }
        if !isPreview {
            let w = Int(destSize.width * scaleFactor), h = Int(destSize.height * scaleFactor)
            Task { await writeBMPSnapshot(videoURL: videoURL, videoID: choiceConfiguration, displayPixelWidth: w, displayPixelHeight: h) }
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

    func invalidate(withId _: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        // Context-reuse model: a per-`WallpaperID` invalidate is the Agent tearing
        // down the *previous* wallpaper right before it acquires the next one on the
        // SAME display. We deliberately do NOT destroy the display's persistent
        // CAContext here — the immediately-following acquire reuses it (returns the
        // same contextId) so the Agent never drops the host and there's no gray gap.
        // A context is only torn down when its video is removed from the library
        // (`removeChoiceRequest`). If the user switches to a non-Phosphene provider
        // and no reacquire follows, the Agent stops hosting us and RunningBoard
        // suspends the process — the idle renderer costs nothing while suspended.
        extensionLog("=== INVALIDATE === (persisted \(WallpaperState.shared.activeContextCount) context(s) for reuse)")
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

        // Tear down only the contexts actually using this video — the video is gone
        // from the library, so these slots are genuinely dead (not a reuse). Other
        // displays may be playing different videos and must keep running.
        let stoppedDisplays = WallpaperState.shared.removeContexts(forVideoID: videoID)
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
