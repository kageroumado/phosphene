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
func makeVariantSelector(choice: String?, fallback: URL) -> @Sendable () -> URL {
    {
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
            screenSaverIsOurs: prefs.screenSaverIsOurs,
            powerState: PowerMonitor.shared.currentState,
        )
        return VideoLibrary.shared.bestVariantURL(for: videoID, policy: policy) ?? fallback
    }
}

/// Process-wide serialization for wallpaper lifecycle XPC. Every connection gets its
/// own `WallpaperXPCHandler`, but the Agent multiplexes desktop + Settings-preview +
/// thumbnail connections, so lifecycle callbacks (acquire/update/invalidate/choice
/// change) can otherwise interleave across connections. We funnel them all through ONE
/// serial queue — mirroring Apple's single `Controller`-actor `AsyncQueue` — so an
/// invalidate can't slip between the halves of an acquire.
/// Carries a non-Sendable value (e.g. a `CALayer`) into a `Task` without tainting the
/// closure's isolation region. `nonisolated(unsafe)` on a local isn't enough under Swift 6.2
/// region-based isolation — capturing the raw layer merges other (Sendable) captures like
/// `videoURL` into a non-Sendable region, which then trips the `sending` checker across the
/// sibling BMP-snapshot Task. Boxing makes the capture genuinely Sendable.
struct SendableBox<T>: @unchecked Sendable { let value: T }

enum Lifecycle {
    static let queue = DispatchQueue(label: "glass.kagerou.phosphene.lifecycle")

    /// Pending per-display teardown timers. Touched ONLY on `queue`.
    nonisolated(unsafe) static var teardownTimers: [DisplayKey: DispatchWorkItem] = [:]

    /// Grace between an invalidate of a display's LIVE wallpaper and actually tearing it
    /// down. A re-acquire (display woke / switched) cancels it; only a display that stays
    /// gone (asleep/removed) lets it fire. Short enough to save power promptly, long enough
    /// to ride out a brief sleep/wake flicker.
    static let teardownGrace: TimeInterval = 15.0
}

/// Arm (or re-arm) the teardown timer for a display whose live wallpaper was invalidated.
/// MUST be called on `Lifecycle.queue`.
private func scheduleTeardown(for key: DisplayKey) {
    Lifecycle.teardownTimers[key]?.cancel()
    let item = DispatchWorkItem {
        Lifecycle.teardownTimers[key] = nil
        let torn = WallpaperState.shared.tearDownContext(for: key)
        extensionLog("  [teardown] grace fired for display \(key.displayID) → \(torn ? "stopped renderer + invalidated CAContext" : "nothing to tear down")")
        ShuffleController.shared.syncActiveWithContexts()
    }
    Lifecycle.teardownTimers[key] = item
    Lifecycle.queue.asyncAfter(deadline: .now() + Lifecycle.teardownGrace, execute: item)
}

/// Cancel a display's pending teardown because it was re-acquired (woke / switched).
/// MUST be called on `Lifecycle.queue`.
private func cancelTeardown(for key: DisplayKey) {
    if let item = Lifecycle.teardownTimers.removeValue(forKey: key) {
        item.cancel()
        extensionLog("  [teardown] cancelled pending teardown for display \(key.displayID) (re-acquired)")
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
    private nonisolated(unsafe) var _agentProxy: (any WallpaperExtensionProxyXPCProtocol)?
    var agentProxy: (any WallpaperExtensionProxyXPCProtocol)? {
        get { agentProxyLock.lock(); defer { agentProxyLock.unlock() }; return _agentProxy }
        set { agentProxyLock.lock(); defer { agentProxyLock.unlock() }; _agentProxy = newValue }
    }

    /// PID of the peer on this connection (WallpaperAgent vs. Settings preview vs.
    /// the thumbnail service), set in `accept(connection:)`. Logged so acquire and
    /// invalidation can be attributed to a specific connection.
    var connectionPID: Int32 = -1

    /// Whether this connection's most recent acquire was a Settings *preview*
    /// (`isPreview: true`). A preview connection reports its own presentation state
    /// (which idles/toggles as the picker is interacted with), and since every
    /// connection shares the one desktop renderer, letting a preview's `update()`
    /// apply pause policy would freeze the visible desktop wallpaper. Preview
    /// connections therefore don't drive playback; only the live desktop connection
    /// (`isPreview: false`) does.
    private var acquiredAsPreview = false

    /// Whether any exported method has been invoked on this connection. Read by the
    /// invalidationHandler: a connection that is accepted and invalidated without ever
    /// serving a method is "empty" — the WallpaperAgent spiral-of-death signal
    /// (see SpiralRecovery). Set synchronously at each method's entry, before any queue hop.
    private let servedMethod = OSAllocatedUnfairLock(initialState: false)
    var didServeMethod: Bool {
        servedMethod.withLock { $0 }
    }

    /// Mark this connection as healthy (a real method arrived) and clear any spiral run.
    /// Call first thing in every exported entry point.
    private func markServed() {
        servedMethod.withLock { $0 = true }
        SpiralRecovery.noteHealthyConnection()
    }

    // MARK: - Lifecycle

    /// Stable per-display surface UUID for the rare acquire that carries no WallpaperID — so
    /// such acquires still collapse to one context per display (old behavior) instead of
    /// minting a fresh context each time. Encodes the displayID into a fixed UUID layout.
    static func fallbackSurfaceUUID(forDisplay displayID: UInt32) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012x", displayID))
            ?? UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    }

    func acquire(withId id: Any?, request: Any?, reply: @escaping @Sendable (Any?, (any Error)?) -> Void) {
        markServed()
        nonisolated(unsafe) let unsafeRequest = request
        nonisolated(unsafe) let unsafeID = id
        nonisolated(unsafe) let handler = self
        Lifecycle.queue.async { handler.acquireBody(id: unsafeID, request: unsafeRequest, reply: reply) }
    }

    private func acquireBody(id: Any?, request: Any?, reply: @escaping @Sendable (Any?, (any Error)?) -> Void) {
        traceLog("=== ACQUIRE ===")

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
                        traceLog("  [Choice] Fallback extraction from description: identifier=\(identifier)")
                        choiceConfiguration = identifier
                    }
                }
            }
        }

        traceLog("  destination: \(destSize) @\(scaleFactor)x, isPreview: \(isPreview), pid: \(connectionPID), choice: \(choiceConfiguration ?? "nil"), files: \(choiceFiles)")

        // Native shuffle: adopt the frequency the host sent (optionValues in the
        // descriptor; absent until the user touches the picker), then resolve the
        // sentinel to the concrete video this surface should render. Contexts keep
        // the RAW choice so re-acquires and switch decisions compare correctly.
        let shuffleFrequency = extractPickerOptionValue("shuffleFrequency", fromRequest: request)
        ShuffleController.shared.noteAcquire(choice: choiceConfiguration, frequencyID: shuffleFrequency)
        let renderChoice = ShuffleController.shared.resolveChoice(choiceConfiguration)
        acquiredAsPreview = isPreview

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

        // Each WallpaperID (a Space, the lock-screen surface, or a Settings preview) is its own
        // hosted surface and must get its OWN CAContext — sharing one context per display let a
        // second Space or the lock surface steal it and black out the first. Key the context by
        // the WallpaperID UUID; fall back to a per-display constant if an id ever lacks one.
        let displayID0 = displayID ?? 0
        let surfaceUUID = extractWallpaperUUID(fromID: id) ?? Self.fallbackSurfaceUUID(forDisplay: displayID0)
        let key = DisplayKey(displayID: displayID0, surfaceUUID: surfaceUUID)
        WallpaperState.shared.registerWallpaperID(surfaceUUID, key: key)
        // A re-acquire of THIS surface (display woke / preview refresh / switch) cancels its
        // pending teardown so a brief invalidate→re-acquire flicker doesn't drop it.
        cancelTeardown(for: key)
        let videoURL = findVideoURL(forChoice: renderChoice)
        let cachedStill = loadCachedSnapshotImage(forChoice: choiceConfiguration)

        // Diagnostic bisection: host a still only (no video pipeline). Same context
        // reuse/create/reply as below — that's what we're stress-testing — but no renderer.
        if Bisect.stillOnly {
            acquireStillOnlyBisect(key: key, displayID: displayID, destSize: destSize, scaleFactor: scaleFactor, videoURL: videoURL, cachedStill: cachedStill, choice: choiceConfiguration, reply: reply)
            return
        }

        // ---- REUSE: the display's single persistent context already exists ----
        // Return the SAME contextId regardless of whether this is the desktop or a
        // Settings-preview acquire — both host one surface (no gray gap, no
        // accumulation, no orphan). Only swap the video if the choice actually
        // changed; re-selecting the same wallpaper is a no-op.
        if let existing = WallpaperState.shared.context(for: key) {
            traceLog("  [acquire] REUSE ctx=\(existing.contextId) display=\(key.displayID) storedVideoID=\(existing.videoID ?? "nil") newChoice=\(choiceConfiguration ?? "nil") renderer=\(existing.renderer.map { "#\($0.debugID)" } ?? "nil") videoURL=\(findVideoURL(forChoice: choiceConfiguration)?.lastPathComponent ?? "nil")")

            // Geometry may have changed since this surface was created — a bigger/smaller
            // display reconnected, or the same display switched resolution. The REUSE path
            // otherwise keeps the original frame, so the wallpaper renders into a sub-region
            // of the now-larger panel (issue #21). Re-frame the root + renderer layers to the
            // new destination before re-hosting. Unchanged geometry (the common wake/revisit
            // re-acquire) returns nil and skips the relayout.
            if let resized = WallpaperState.shared.updateGeometryIfChanged(destSize: destSize, scaleFactor: scaleFactor, for: key) {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                resized.rootLayer.frame = CGRect(origin: .zero, size: destSize)
                resized.rootLayer.contentsScale = scaleFactor
                CATransaction.commit()
                CATransaction.flush()
                resized.renderer?.resize(to: destSize, scale: scaleFactor)
                extensionLog("  [acquire] REUSE geometry changed → resized surface on display \(key.displayID) to \(destSize) @\(scaleFactor)x")
            }

            guard let replyObj = createRemoteContextXPC(contextId: existing.contextId) else {
                reply(nil, NSError(domain: "PhospheneExtension", code: 3, userInfo: nil)); return
            }
            reply(replyObj, nil)

            if ColorDiag.enabled { colorDiagInstall(rootLayer: existing.rootLayer, for: key); return }

            if existing.videoID == choiceConfiguration, existing.renderer != nil {
                traceLog("  [acquire] SAME choice (\(choiceConfiguration ?? "nil")) + renderer present → no swap")
                return
            }
            guard let videoURL else {
                traceLog("  [acquire] no video for new choice, keeping current")
                return
            }
            extensionLog("  [acquire] switching to \(videoURL.lastPathComponent) (renderer \(existing.renderer != nil ? "present → switchVideo" : "nil → create"))")
            let selector = makeVariantSelector(choice: renderChoice, fallback: videoURL)
            if let renderer = existing.renderer {
                // Switch the video IN PLACE on the already-hosted display layer.
                // Building a fresh renderer here (new AVSampleBufferDisplayLayer) is
                // what broke switching — a layer added to an already-hosted context
                // doesn't composite. Reuse the existing layer instead.
                renderer.variantSelector = selector
                renderer.switchVideo(to: videoURL)
                WallpaperState.shared.updateVideoID(choiceConfiguration, for: key)
                WallpaperPrefs.shared.setActive(true)
            } else if WallpaperState.shared.claimRendererCreate(for: key) {
                // Context exists but no renderer yet AND no create already in flight —
                // attach one to the existing root layer. The claim prevents a racing
                // (preview) acquire from creating a duplicate renderer on the same layer.
                let boxedRoot = SendableBox(value: existing.rootLayer)
                Task { [boxedRoot, videoURL, cachedStill, selector, key, choiceConfiguration] in
                    let renderer: VideoRenderer
                    do {
                        renderer = try await VideoRenderer.create(rootLayer: boxedRoot.value, videoURL: videoURL, stillImage: cachedStill)
                    } catch {
                        extensionLog("  [Renderer] swap create failed: \(error)")
                        WallpaperState.shared.clearRendererPending(for: key)
                        return
                    }
                    renderer.variantSelector = selector
                    let old = WallpaperState.shared.setRenderer(renderer, videoID: choiceConfiguration, for: key)
                    old?.stop()
                    WallpaperPrefs.shared.setActive(true)
                    renderer.start()
                }
            } else {
                traceLog("  [acquire] renderer create already in flight for display \(key.displayID) — skipping duplicate")
            }
            let w = Int(destSize.width * scaleFactor), h = Int(destSize.height * scaleFactor)
            Task { [videoURL, choiceConfiguration, w, h] in await writeBMPSnapshot(videoURL: videoURL, videoID: choiceConfiguration, displayPixelWidth: w, displayPixelHeight: h) }
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
            ActiveWallpaper(caContext: caContext, contextId: contextId, rootLayer: rootLayer, renderer: nil, displayID: displayID, videoID: choiceConfiguration, isPreview: isPreview, destSize: destSize, scaleFactor: scaleFactor),
            for: key,
        )
        extensionLog("  Created context \(contextId) for display \(key.displayID)")

        // NB: the XPC reply is DEFERRED until the new context is actually displaying
        // video (in the render Task below). WallpaperAgent hosts a context only after it
        // receives this reply, and keeps compositing the OLD wallpaper's context until
        // then. Replying immediately (as before) made the agent swap to a not-yet-
        // rendering context — the blink / still-flash / zoom on every switch. Gating the
        // reply on the first composited frame makes the host swap land directly on live
        // video, matching Apple's own extensions (which likewise don't reply until ready).
        // Every branch below still replies exactly once so the acquire can never hang.

        if ColorDiag.enabled { reply(replyObj, nil); colorDiagInstall(rootLayer: rootLayer, for: key); return }

        guard let videoURL else {
            // No video file — solid gradient fallback. Static content, so it's ready as
            // soon as it's installed; reply immediately.
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
            reply(replyObj, nil)
            extensionLog("  No video file found — solid color fallback")
            return
        }

        // Cold start = no existing Phosphene surface on this display for the SAME surface
        // role (preview vs. live desktop) that the agent could keep compositing during the
        // swap. Unlike a switch (where the outgoing context is OURS and stays hosted, via
        // the teardown grace, until we reply), here the agent has nothing of ours to hold
        // in THIS role's CALayerHost — the instant it hosts our context it shows whatever
        // the context contains. `rootLayer.contents` is BLACK cross-process (only IOSurface-
        // backed AVSampleBufferDisplayLayer content composites remotely — see
        // Research/wallpaper-extension-issue13-and-rendering-findings.md), so replying
        // before the renderer exists paints black. Instead, on a cold start we reply the
        // instant VideoRenderer.create() has seeded + flushed the IOSurface still into the
        // display layer: the agent then hosts a context already showing the still, and the
        // video plays over it in place. A switch keeps deferring until the first video frame.
        //
        // Filtering by `isPreview` is what fixes the WallpaperAgent-restart ordering bug:
        // a preview-first / desktop-second boot must NOT let the preview renderer trip this
        // check for the incoming desktop acquire, because the desktop CALayerHost has never
        // hosted anything of ours — deferring there paints black.
        let coldStart = !WallpaperState.shared.hasLiveRenderer(onDisplay: displayID0, isPreview: isPreview)

        // Claim the single create slot for this display. If a racing (preview)
        // acquire beat us to it, skip — exactly one renderer per display.
        if WallpaperState.shared.claimRendererCreate(for: key) {
            traceLog("  Setting up VideoRenderer with: \(videoURL.lastPathComponent) (coldStart=\(coldStart))")
            let boxedRoot = SendableBox(value: rootLayer)
            // The reply object is non-Sendable; box it to cross into the render Task.
            let boxedReply = SendableBox(value: replyObj)
            let selector = makeVariantSelector(choice: renderChoice, fallback: videoURL)
            Task { [coldStart, boxedRoot, boxedReply, videoURL, cachedStill, selector, key, choiceConfiguration] in
                let renderer: VideoRenderer
                do {
                    renderer = try await VideoRenderer.create(rootLayer: boxedRoot.value, videoURL: videoURL, stillImage: cachedStill)
                } catch {
                    extensionLog("  [Renderer] Failed to create: \(error)")
                    WallpaperState.shared.clearRendererPending(for: key)
                    reply(boxedReply.value, nil) // unblock the acquire regardless (create failed)
                    return
                }
                // Cold start: the IOSurface still is now seeded + flushed into the display
                // layer, so reply — the agent hosts our context already showing the still
                // (no black gap), and video plays over it.
                if coldStart {
                    reply(boxedReply.value, nil)
                    traceLog("  [acquire] cold start → replied after still seeded for \(videoURL.lastPathComponent)")
                }
                renderer.variantSelector = selector
                let old = WallpaperState.shared.setRenderer(renderer, videoID: choiceConfiguration, for: key)
                WallpaperPrefs.shared.setActive(true)
                // Switch: reply only once the first video frame is composited (cold start
                // already replied with the still). Either way, stop the old renderer once
                // we've told the agent to swap off it.
                renderer.start(onFirstFrameReady: {
                    if !coldStart { reply(boxedReply.value, nil) }
                    old?.stop()
                })
            }
        } else {
            traceLog("  [acquire] renderer create already in flight for display \(key.displayID) — skipping duplicate (create path)")
            reply(replyObj, nil)
        }
        let w = Int(destSize.width * scaleFactor), h = Int(destSize.height * scaleFactor)
        Task { await writeBMPSnapshot(videoURL: videoURL, videoID: choiceConfiguration, displayPixelWidth: w, displayPixelHeight: h) }
    }

    /// Bisection acquire: identical CAContext reuse/create/reply as `acquireBody`, but
    /// hosts a still (via `bisectShowStill`) instead of a VideoRenderer. Runs on
    /// `Lifecycle.queue`. See StillBisect.swift.
    private func acquireStillOnlyBisect(key: DisplayKey, displayID: UInt32?, destSize: CGSize, scaleFactor: CGFloat, videoURL: URL?, cachedStill: CGImage?, choice: String?, reply: @escaping @Sendable (Any?, (any Error)?) -> Void) {
        if let existing = WallpaperState.shared.context(for: key) {
            traceLog("  [bisect] REUSE ctx=\(existing.contextId) display=\(key.displayID) stored=\(existing.videoID ?? "nil") new=\(choice ?? "nil")")
            guard let replyObj = createRemoteContextXPC(contextId: existing.contextId) else {
                reply(nil, NSError(domain: "PhospheneExtension", code: 3, userInfo: nil)); return
            }
            reply(replyObj, nil)
            if existing.videoID == choice {
                traceLog("  [bisect] SAME choice → no re-seed")
                return
            }
            bisectShowStill(videoURL: videoURL, cachedStill: cachedStill, rootLayer: existing.rootLayer, for: key)
            WallpaperState.shared.updateVideoID(choice, for: key)
            return
        }

        var contextOptions: [String: Any] = [:]
        if let did = displayID { contextOptions["displayId"] = did }
        let caContextRaw: Any? = contextOptions.isEmpty
            ? CAContext.remoteContext()
            : CAContext.perform(NSSelectorFromString("remoteContextWithOptions:"), with: contextOptions)?.takeUnretainedValue()
        guard let caContext = caContextRaw as? CAContext, caContext.contextId != 0 else {
            reply(nil, NSError(domain: "PhospheneExtension", code: 4, userInfo: [NSLocalizedDescriptionKey: "Failed to create remote CAContext"]))
            return
        }
        let rootLayer = CALayer()
        rootLayer.frame = CGRect(origin: .zero, size: destSize)
        rootLayer.contentsScale = scaleFactor
        rootLayer.contentsGravity = .resizeAspectFill
        caContext.layer = rootLayer
        CATransaction.flush()
        guard let replyObj = createRemoteContextXPC(contextId: caContext.contextId) else {
            reply(nil, NSError(domain: "PhospheneExtension", code: 3, userInfo: nil)); return
        }
        WallpaperState.shared.installContext(
            ActiveWallpaper(caContext: caContext, contextId: caContext.contextId, rootLayer: rootLayer, renderer: nil, displayID: displayID, videoID: choice, isPreview: acquiredAsPreview, destSize: destSize, scaleFactor: scaleFactor),
            for: key,
        )
        reply(replyObj, nil)
        traceLog("  [bisect] CREATED ctx=\(caContext.contextId) display=\(key.displayID) choice=\(choice ?? "nil")")
        bisectShowStill(videoURL: videoURL, cachedStill: cachedStill, rootLayer: rootLayer, for: key)
    }

    private var previousPresentationMode = "default"

    func update(withId _: Any?, request: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        markServed()
        nonisolated(unsafe) let unsafeRequest = request
        nonisolated(unsafe) let handler = self
        Lifecycle.queue.async { handler.updateBody(request: unsafeRequest, reply: reply) }
    }

    private func updateBody(request: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        // Option edits can travel on the update path; adopt a shuffle-frequency
        // change without waiting for the next acquire.
        if let frequency = extractPickerOptionValue("shuffleFrequency", fromRequest: request) {
            ShuffleController.shared.noteFrequencyChange(frequency)
        }

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
            screenSaverIsOurs: prefs.screenSaverIsOurs,
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
        extensionLog("=== UPDATE (desktop pid \(connectionPID)) === mode: \(presentationMode), activity: \(activityState), policy: \(policy)")
        reply(nil)
    }

    func invalidate(withId id: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        markServed()
        nonisolated(unsafe) let unsafeID = id
        nonisolated(unsafe) let handler = self
        Lifecycle.queue.async { handler.invalidateBody(id: unsafeID, reply: reply) }
    }

    private func invalidateBody(id: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        // Per-SURFACE teardown, resolved via the WallpaperID UUID learned at acquire. Each
        // surface (Space / lock screen / Settings preview) owns its own context, so we simply
        // tear down THIS surface after a short grace — a re-acquire of the same UUID (display
        // sleep/wake, a quick space revisit, a switch that reuses the id) cancels it. Because
        // teardown is scoped to one surface, it can never black out another Space (the old
        // shared-context cross-kill) and a superseded UUID just cleans up its own orphaned
        // context instead of leaking it.
        guard let uuid = extractWallpaperUUID(fromID: id) else {
            extensionLog("=== INVALIDATE === no UUID in id → ignore (kept \(WallpaperState.shared.activeContextCount) context(s))")
            reply(nil); return
        }
        guard let key = WallpaperState.shared.resolveWallpaperKey(uuid) else {
            extensionLog("=== INVALIDATE === UUID \(uuid) unknown (not ours / already forgotten) → ignore")
            reply(nil); return
        }
        WallpaperState.shared.forgetWallpaperID(uuid)
        scheduleTeardown(for: key)
        extensionLog("=== INVALIDATE === UUID \(uuid) → tear down surface on display \(key.displayID) in \(Lifecycle.teardownGrace)s unless re-acquired")
        reply(nil)
    }

    func snapshot(withId _: Any?, reply: @escaping @Sendable (Any?, (any Error)?) -> Void) {
        markServed()
        traceLog("=== SNAPSHOT ===")

        // Get current time from any active renderer for a more representative snapshot
        var currentTime: CMTime?
        WallpaperState.shared.forEachRenderer { renderer in
            currentTime = CMTimebaseGetTime(renderer.timebase)
        }

        Task {
            if let snapshotXPC = await createSnapshotViaRuntime(currentTime: currentTime) {
                reply(snapshotXPC, nil)
                traceLog("  Snapshot replied (IOSurface)")
            } else {
                reply(nil, nil)
                traceLog("  Snapshot replied (nil)")
            }
        }
    }

    // MARK: - Settings

    func provideSettingsViewModels(withContentTypes _: Any?, reply: @escaping @Sendable (Any?, (any Error)?) -> Void) {
        markServed()
        traceLog("=== PROVIDE SETTINGS VIEW MODELS ===")

        Task {
            if let result = await buildSettingsViewModelsXPC() {
                traceLog("  [Settings] Remapped to \(NSStringFromClass(type(of: result as AnyObject)))")
                reply(result, nil)
            } else {
                traceLog("  [Settings] Build failed, using empty fallback")
                reply(makeEmptyGroupsResponse(), nil)
            }
        }
    }

    // MARK: - Choices

    func addChoiceRequest(withChoiceRequest _: Any?, onBehalfOfProcess _: Any?, reply: @escaping @Sendable (Any?, (any Error)?) -> Void) {
        markServed()
        traceLog("=== ADD CHOICE REQUEST ===")
        reply(nil, nil)
    }

    func removeChoiceRequest(withChoiceRequest request: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        markServed()
        nonisolated(unsafe) let unsafeRequest = request
        nonisolated(unsafe) let handler = self
        Lifecycle.queue.async { handler.removeChoiceRequestBody(request: unsafeRequest, reply: reply) }
    }

    private func removeChoiceRequestBody(request: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
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
        markServed()
        nonisolated(unsafe) let unsafeID = id
        nonisolated(unsafe) let handler = self
        Lifecycle.queue.async { handler.selectedChoicesDidChangeBody(id: unsafeID, reply: reply) }
    }

    private func selectedChoicesDidChangeBody(id: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
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

        // The shuffle choice: no fixed video to record — resolve the current pick for
        // the menu-bar UI and refresh snapshots. The acquire that follows activates
        // rotation and does the rendering.
        if choiceIdentifier == shuffleChoiceID {
            extensionLog("=== CHOICE CHANGED === shuffle")
            if let pick = ShuffleController.shared.resolveChoice(shuffleChoiceID) {
                WallpaperState.shared.currentVideoID = pick
                WallpaperState.shared.cachedThumbnailURL = nil
                WallpaperPrefs.shared.updateCurrentVideo()
            }
            if let proxy = agentProxy {
                proxy.invalidateSnapshots { error in
                    if let error {
                        extensionLog("  [Choice] invalidateSnapshots error: \(error)")
                    }
                }
            }
            reply(nil)
            return
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

        let urlByAction = [
            "add-video": "phosphene://add-video",
            "manage-library": "phosphene://library",
        ]
        if let urlString = urlByAction[identifier], let url = URL(string: urlString) {
            extensionLog("  Launching companion app via NSWorkspace: \(urlString)")
            let opened = NSWorkspace.shared.open(url)
            traceLog("  NSWorkspace.open = \(opened)")
        }

        reply(nil)
    }

    // MARK: - Downloads

    func isChoiceDownloaded(with _: Any?, reply: @escaping @Sendable (Bool, (any Error)?) -> Void) {
        traceLog("isChoiceDownloaded")
        reply(true, nil)
    }

    func download(withChoiceID _: Any?, reply: ((any Error)?) -> Void) -> Any? {
        traceLog("download")
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
        traceLog("migrateSelectedChoice")
        reply(nil, nil)
    }

    func migrate(from _: Any?, to _: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        traceLog("migrate")
        reply(nil)
    }

    // MARK: - Shuffle

    func skipShuffledContent(withId _: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        markServed()
        let handled = ShuffleController.shared.skip()
        extensionLog("=== SKIP SHUFFLED CONTENT === handled=\(handled)")
        reply(nil)
    }

    func canSkipShuffledContent(withId _: Any?, reply: @escaping @Sendable (Bool, (any Error)?) -> Void) {
        traceLog("canSkipShuffledContent")
        reply(ShuffleController.shared.isActive, nil)
    }

    // MARK: - Debug & Notifications

    func handleDebugRequest(for _: Any?, reply: @escaping @Sendable (Any?, (any Error)?) -> Void) {
        traceLog("handleDebugRequest")
        reply(nil, nil)
    }

    func handleNotification(withNamed name: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        traceLog("handleNotification(\(name ?? "nil"))")
        reply(nil)
    }
}

/// Extract the selected id of a picker option (e.g. "shuffleFrequency") from an XPC
/// request whose descriptor carries `optionValues` — a
/// `WallpaperChoiceOptionValues(values: [String: Kind])` map where a picker's value
/// is `Kind.picker(PickerValue(id:))`. The key is absent until the user touches the
/// picker; callers treat nil as "keep the declared default".
func extractPickerOptionValue(_ optionID: String, fromRequest request: Any?) -> String? {
    guard let request,
          let optionValues = mirrorFindProperty("optionValues", in: request),
          let values = mirrorFindProperty("values", in: optionValues)
    else { return nil }
    for entry in Mirror(reflecting: values).children {
        var key: String?
        var kind: Any?
        for pair in Mirror(reflecting: entry.value).children {
            if pair.label == "key" { key = pair.value as? String }
            if pair.label == "value" { kind = pair.value }
        }
        guard key == optionID, let kind else { continue }
        let kindMirror = Mirror(reflecting: kind)
        guard kindMirror.displayStyle == .enum,
              let payload = kindMirror.children.first, payload.label == "picker"
        else { return nil }
        return mirrorFindProperty("id", in: payload.value) as? String
    }
    return nil
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
