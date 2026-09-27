import AVFoundation
import CoreMedia
import ObjectiveC
import os

/// Call AVSampleBufferDisplayLayer's private `_setDisallowsVideoLayerDisplayCompositing:`
/// (a BOOL setter Apple's WallpaperExtensionKit uses on every AVSBDL). Resolved via the
/// ObjC runtime so the private selector never appears in a header; a no-op if the API
/// ever disappears. Prevents the layer painting opaque black before its first frame.
private func setDisallowsVideoLayerDisplayCompositing(_ layer: CALayer, _ flag: Bool) {
    let sel = NSSelectorFromString("_setDisallowsVideoLayerDisplayCompositing:")
    guard layer.responds(to: sel),
          let imp = class_getMethodImplementation(type(of: layer), sel) else { return }
    typealias SetBoolFn = @convention(c) (AnyObject, Selector, ObjCBool) -> Void
    unsafeBitCast(imp, to: SetBoolFn.self)(layer, sel, ObjCBool(flag))
}

final class VideoRenderer: @unchecked Sendable {
    /// Process-wide instance counter so log lines can be attributed to a specific
    /// renderer object (to catch stale/duplicate renderers from acquire races).
    private static let idCounter = OSAllocatedUnfairLock(initialState: 0)
    let debugID: Int = VideoRenderer.idCounter.withLock { $0 += 1; return $0 }

    let displayLayer: AVSampleBufferDisplayLayer
    let timebase: CMTimebase
    private let renderer: AVSampleBufferVideoRenderer
    private let queue = DispatchQueue(label: "video-renderer", qos: .userInitiated)

    // Everything below is confined to `queue`.
    private var asset: AVURLAsset
    private var videoTrack: AVAssetTrack
    private var isRunning = true
    /// `start()` has built the pipeline. Before that a target only sets the logical
    /// state, which `start()` then honors.
    private var hasStarted = false
    /// The logical pause state. The timebase rate follows it, through a ramp or a cut.
    private var isPaused = false
    private var currentPolicy: PlaybackPolicy = .full
    private var rampTimer: (any DispatchSourceTimer)?
    private var deepPauseTimer: (any DispatchSourceTimer)?
    /// Picks the file for the next loop from the current policy (full-rate original or
    /// a reduced-frame-rate variant).
    private var variantSelector: (@Sendable (PlaybackPolicy) -> URL)?

    /// The task feeding this renderer its surface's targets (`PlaybackStore.follow`).
    private let followTask = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)

    private var currentReader: AVAssetReader?
    private var currentOutput: AVAssetReaderTrackOutput?
    private var nextReader: AVAssetReader?
    private var nextOutput: AVAssetReaderTrackOutput?

    /// A renderer `flush` (decoder reset) is the one async hop in the pipeline, and
    /// TWO overlapping flushes corrupt the renderer (rapid-switch breakage). These two
    /// flags — touched ONLY on `queue` — serialize it: at most one flush is ever in
    /// flight, and a switch arriving during a flush is coalesced, so when the flush
    /// completes we restart once to whatever the latest selected asset is.
    private var flushInFlight = false
    private var restartPending = false

    /// Diagnostic: number of remaining feed-loop ticks to log after a restart.
    private var feedLogBudget = 0

    // Gapless looping state.
    // ptsOffset accumulates across loops so both DTS and PTS are monotonically increasing.
    // lastEnqueuedEnd tracks the highest sample end time (max, not last — handles B-frames).
    private var ptsOffset: CMTime = .zero
    private var lastEnqueuedEnd: CMTime = .zero

    static func create(
        rootLayer: CALayer,
        videoURL: URL,
        stillImage: CGImage? = nil,
    ) async throws -> VideoRenderer {
        let asset = AVURLAsset(url: videoURL)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [
                NSLocalizedDescriptionKey: "No video track found in \(videoURL.lastPathComponent)",
            ])
        }

        let displayLayer = AVSampleBufferDisplayLayer()
        displayLayer.videoGravity = .resizeAspectFill
        displayLayer.frame = rootLayer.bounds
        displayLayer.contentsScale = rootLayer.contentsScale
        // Opaque: the per-surface context fix (each Space/lock surface owns its own
        // CAContext) is what stops the black, not this layer's opacity. Leaving the
        // layer non-opaque only adds a per-frame blend against what's behind it, which
        // makes the layer visibly blink while the compositor rebuilds it during a
        // switch. Opaque keeps the switch seamless.
        displayLayer.isOpaque = true
        // Match Apple's WallpaperExtensionKit: stop the AVSampleBufferDisplayLayer from
        // painting opaque BLACK before its first frame is composited. On a cold start the
        // Agent hosts our context the instant we reply, and without this an as-yet-empty
        // layer flashes black (the residual "black still"). Apple sets this on every AVSBDL.
        setDisallowsVideoLayerDisplayCompositing(displayLayer, true)
        // Added to the tree in init() inside an action-free transaction (below).

        return VideoRenderer(
            rootLayer: rootLayer,
            displayLayer: displayLayer,
            asset: asset,
            videoTrack: track,
            stillImage: stillImage,
        )
    }

    private init(
        rootLayer: CALayer,
        displayLayer: AVSampleBufferDisplayLayer,
        asset: AVURLAsset,
        videoTrack: AVAssetTrack,
        stillImage: CGImage?,
    ) {
        self.displayLayer = displayLayer
        self.renderer = displayLayer.sampleBufferRenderer
        self.asset = asset
        self.videoTrack = videoTrack

        var tb: CMTimebase?
        CMTimebaseCreateWithSourceClock(
            allocator: kCFAllocatorDefault,
            sourceClock: CMClockGetHostTimeClock(),
            timebaseOut: &tb,
        )
        self.timebase = tb!
        CMTimebaseSetTime(timebase, time: .zero)
        // Rate stays 0 until start() — prevents the timebase from advancing
        // during the async gap between init and start, which would cause
        // the first batch of frames to be considered "late" and dropped.
        CMTimebaseSetRate(timebase, rate: 0.0)
        displayLayer.controlTimebase = timebase

        // Install the layers and seed the still in ONE action-free transaction, so
        // Core Animation doesn't play an implicit "onOrderIn" animation (the video
        // appearing to zoom/fade in). The still is an IOSurface-backed sample buffer
        // at PTS 0 — unlike CALayer.contents (black when hosted cross-process) it
        // composites into WallpaperAgent's CALayerHost, so the desktop shows the
        // still immediately; the video's first real frame (also PTS 0) plays over it
        // once rate=1.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rootLayer.addSublayer(displayLayer)
        traceLog("  [Renderer #\(debugID)] CREATED for \(asset.url.lastPathComponent), displayLayer=\(ObjectIdentifier(displayLayer)), rootLayer sublayers=\((rootLayer.sublayers?.count ?? 0))")
        if let stillImage, let stillBuffer = makeStillSampleBuffer(from: stillImage) {
            // Tag DisplayImmediately so the still is shown the instant it's enqueued,
            // rather than waiting on the control timebase (which is frozen at rate 0 here).
            // Without this the frame can sit undisplayed → the layer reads empty → black.
            Self.setDisplayImmediately(stillBuffer)
            renderer.enqueue(stillBuffer)
            traceLog("  [Renderer #\(debugID)] Seeded still into display layer (\(stillImage.width)x\(stillImage.height))")
        } else {
            traceLog("  [Renderer #\(debugID)] No still to seed (stillImage present: \(stillImage != nil))")
        }
        CATransaction.commit()
        // flush() (not just commit()) is what pushes the layer tree to the render
        // server for a REMOTE context — without it the still never reaches the
        // WindowServer and the desktop stays black until a later flush.
        CATransaction.flush()
    }

    /// Start playback and return once the first frame is on screen.
    ///
    /// The work runs on the renderer's queue: the first-frame `copyNextSampleBuffer` is
    /// a blocking decode, and blocking a cooperative thread would starve the
    /// extension's executor. It returns after the first frame is enqueued and flushed
    /// to the render server, i.e. once this renderer's context is displaying video. The
    /// acquire path awaits it before replying on a switch, so WallpaperAgent keeps
    /// compositing the old wallpaper until then and the host swap lands on live video,
    /// as Apple's own extensions do. It returns on every path, including early exits,
    /// so a gated reply can never hang.
    ///
    /// A target applied before `start()` (see `PlaybackStore.follow`) takes effect right
    /// after the first frame.
    func start() async {
        await withCheckedContinuation { (firstFrame: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                beginPlayback { firstFrame.resume() }
            }
        }
    }

    /// Runs on `queue`. Calls `firstFrameShown` exactly once.
    private func beginPlayback(firstFrameShown: () -> Void) {
        traceLog("  [start #\(debugID)] asset=\(asset.url.lastPathComponent) paused=\(isPaused)")
        guard isRunning else {
            traceLog("  [start #\(debugID)] aborted — already stopped")
            firstFrameShown()
            return
        }
        guard let reader = try? AVAssetReader(asset: asset) else {
            firstFrameShown()
            return
        }
        let output = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        reader.startReading()
        hasStarted = true

        // Reset the timebase before the first enqueue so the frame isn't seen as late.
        CMTimebaseSetTime(timebase, time: .zero)

        // Enqueue the first frame and flush it to the render server inside an
        // action-free transaction, so the context is displaying video before the
        // acquire reply is released.
        if let firstSample = output.copyNextSampleBuffer() {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            renderer.enqueue(firstSample)
            CATransaction.commit()
            CATransaction.flush()
        }

        currentReader = reader
        currentOutput = output
        ptsOffset = .zero
        lastEnqueuedEnd = .zero

        CMTimebaseSetRate(timebase, rate: 1.0)
        firstFrameShown()
        if isPaused {
            holdAfterFirstFrame()
            scheduleDeepPause()
        }

        prepareNextReader()
        feedFromCurrentReader()
    }

    /// Re-frame the video layer to a new destination geometry (points) and backing
    /// scale, used when a display reconnects at, or switches to, a different
    /// resolution. The layer fills the root with `resizeAspectFill`, so re-framing it
    /// to the full bounds is all that's needed. Synchronous, inside an action-free
    /// flushed transaction, like the acquire path's own layer mutations.
    func resize(to destSize: CGSize, scale: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = CGRect(origin: .zero, size: destSize)
        displayLayer.contentsScale = scale
        CATransaction.commit()
        CATransaction.flush()
        traceLog("  [resize #\(debugID)] → \(destSize) @\(scale)x")
    }

    /// Replace the loop-boundary variant selector.
    func setVariantSelector(_ selector: @escaping @Sendable (PlaybackPolicy) -> URL) {
        queue.async { [self] in variantSelector = selector }
    }

    /// Switch to a different video in place, reusing this renderer's `displayLayer`.
    /// The layer is already attached to the surface's context and hosted by
    /// WallpaperAgent, so feeding it frames from a new asset updates the desktop,
    /// whereas a fresh `AVSampleBufferDisplayLayer` added to an already-hosted context
    /// does not composite.
    ///
    /// Serialized on `queue`: the track load blocks the queue thread (one we own,
    /// which already blocks for decodes), every switch runs to completion in FIFO
    /// order, and rapid switching is last-requested-wins. The only async hop is the
    /// renderer's `flush`, which is serialized and coalesces rapid switches. The pause
    /// state carries over: a paused surface shows the new video's first frame.
    func switchVideo(to url: URL, selector: @escaping @Sendable (PlaybackPolicy) -> URL) {
        queue.async { [self] in
            variantSelector = selector
            guard isRunning else { return }
            if asset.url == url {
                traceLog("  [switchVideo #\(debugID)] already on \(url.lastPathComponent)")
                return
            }
            let newAsset = AVURLAsset(url: url)
            guard let track = Self.loadFirstVideoTrackBlocking(newAsset) else {
                traceLog("  [switchVideo #\(debugID)] no video track in \(url.lastPathComponent)")
                return
            }
            asset = newAsset
            videoTrack = track
            traceLog("  [switchVideo #\(debugID)] restarting from 0 → \(url.lastPathComponent)")
            restartWithCurrentAsset()
        }
    }

    /// Tag a sample buffer so the renderer displays it immediately, replacing all
    /// previously enqueued/displayed images regardless of timestamps (per
    /// AVQueuedSampleBufferRendering docs). Used for the first frame of a switched
    /// video so the swap is instant and doesn't wait on the control timebase.
    private static func setDisplayImmediately(_ sample: CMSampleBuffer) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) else { return }
        let count = CFArrayGetCount(attachments)
        for i in 0 ..< count {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, i), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque(),
            )
        }
    }

    /// Load the first video track synchronously. Call ONLY from the renderer's serial
    /// `queue` — it blocks that (real, owned) thread on a semaphore while AVFoundation
    /// loads the track on its own internal queue, so there's no cooperative-executor
    /// starvation and no out-of-order Task completion. Local files load in a few ms.
    private static func loadFirstVideoTrackBlocking(_ asset: AVURLAsset) -> AVAssetTrack? {
        traceLog("  [load] blocking-load START \(asset.url.lastPathComponent) (queue will block until AVF replies)")
        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: AVAssetTrack?
        asset.loadTracks(withMediaType: .video) { tracks, _ in
            result = tracks?.first
            sem.signal()
        }
        sem.wait()
        traceLog("  [load] blocking-load DONE \(asset.url.lastPathComponent) track=\(result != nil ? "ok" : "nil")")
        return result
    }

    /// Stop playback for good. Synchronous with the renderer queue, so no callback is
    /// mid-flight when the readers are cancelled. Must not be called on that queue.
    func stop() {
        followTask.withLock { $0?.cancel(); $0 = nil }
        queue.sync {
            extensionLog("  [stop #\(debugID)] stopping renderer for \(asset.url.lastPathComponent)")
            isRunning = false
            cancelRamp()
            cancelDeepPauseTimer()
            renderer.stopRequestingMediaData()
            currentReader?.cancelReading()
            nextReader?.cancelReading()
        }
        displayLayer.removeFromSuperlayer()
    }

    /// Adopt the task that feeds this renderer its targets; `stop()` cancels it.
    func setFollowTask(_ task: Task<Void, Never>) {
        followTask.withLock { $0?.cancel(); $0 = task }
    }

    // MARK: - Targets

    /// Move toward `target`. Safe from any thread; applied in order on the renderer
    /// queue, and a repeat of the current policy is ignored.
    func apply(_ target: SurfaceTarget) {
        queue.async { [self] in reconcile(to: target) }
    }

    private func reconcile(to target: SurfaceTarget) {
        guard isRunning, target.policy != currentPolicy else { return }
        extensionLog("  [target #\(debugID)] \(currentPolicy) → \(target.policy)\(target.ramps ? " (ramp)" : "") asset=\(asset.url.lastPathComponent)")
        currentPolicy = target.policy
        switch (target.policy, target.ramps) {
        case (.paused, true): rampDown()
        case (.paused, false): pause()
        case (_, true): rampUp()
        case (_, false): resume()
        }
    }

    private func pause() {
        guard !isPaused else { return }
        isPaused = true
        cancelRamp()
        CMTimebaseSetRate(timebase, rate: 0.0)
        scheduleDeepPause()
    }

    private func resume() {
        guard isPaused else { return }
        isPaused = false
        cancelRamp()
        cancelDeepPauseTimer()
        if currentReader == nil {
            wakeFromDeepPause()
        } else {
            CMTimebaseSetRate(timebase, rate: 1.0)
        }
    }

    /// The readers were freed by a deep pause. Rebuild them continuing from the paused
    /// position, so a lock or display-sleep wake resumes the same moment of the video.
    private func wakeFromDeepPause() {
        guard hasStarted else { return }
        recreatePlayback(seamlessResume: true)
        CMTimebaseSetRate(timebase, rate: 1.0)
    }

    // MARK: - Ramp (Apple-like lock screen transition)

    /// Ramp durations in seconds and step interval aligned to display refresh rate.
    /// Ramp-down (unlock → desktop pause) matches the ~6 s deceleration of Apple's
    /// built-in wallpapers after unlock; ramp-up (→ lock screen) stays short so
    /// playback reaches full speed while the lock reveal is still on screen.
    private static let rampUpDuration: TimeInterval = 2.0
    private static let rampDownDuration: TimeInterval = 6.0
    private static let rampStepInterval: TimeInterval = 1.0 / 120.0

    /// How long a paused surface's clock runs after its first frame is enqueued.
    private static let firstFrameRunway: TimeInterval = 0.25

    /// Let the clock run briefly, then stop it. A display layer whose clock stops at
    /// time 0 before it has shown a frame never shows one: the surface stays black
    /// until playback next runs, e.g. on the lock screen. Runs on `queue`.
    private func holdAfterFirstFrame() {
        queue.asyncAfter(deadline: .now() + Self.firstFrameRunway) { [self] in
            guard isRunning, isPaused, rampTimer == nil else { return }
            CMTimebaseSetRate(timebase, rate: 0.0)
        }
    }

    /// Gradually reduce the timebase rate to zero, then freeze.
    ///
    /// `isPaused` flips immediately: it is the logical state, and the rate follows.
    /// Flipping it at ramp completion would make a resume arriving mid-ramp look like
    /// a no-op and strand the rate wherever the cancelled ramp left it (slow motion).
    private func rampDown() {
        guard !isPaused else { return }
        isPaused = true
        cancelDeepPauseTimer()
        ramp(to: 0.0, over: Self.rampDownDuration) { [self] in scheduleDeepPause() }
    }

    /// Gradually raise the timebase rate to 1.0 from wherever it is now, so reversing
    /// a mid-flight ramp-down accelerates from the current speed.
    private func rampUp() {
        guard isPaused else { return }
        isPaused = false
        cancelDeepPauseTimer()
        guard currentReader != nil else {
            // No frames to ramp into: wake instantly instead.
            cancelRamp()
            wakeFromDeepPause()
            return
        }
        ramp(to: 1.0, over: Self.rampUpDuration)
    }

    /// Ease the timebase rate from its CURRENT value to `target`.
    ///
    /// Starting from the live rate is what makes ramps reversible: a reversal
    /// mid-flight travels the remaining distance in proportionally less time,
    /// keeping the rate curve continuous instead of replaying a full schedule
    /// from 1.0 or 0 (which made a paused wallpaper leap to speed and decelerate).
    private func ramp(to target: Double, over fullDuration: TimeInterval, then completion: (() -> Void)? = nil) {
        cancelRamp()
        let start = Double(CMTimebaseGetRate(timebase))
        let distance = abs(target - start)
        guard distance > 0.001 else {
            CMTimebaseSetRate(timebase, rate: target)
            completion?()
            return
        }
        let totalSteps = RampMath.steps(distance: distance, fullDuration: fullDuration, stepInterval: Self.rampStepInterval)
        var step = 0

        // First step lands immediately so a resume never sits on a dead frame.
        if target > start {
            CMTimebaseSetRate(timebase, rate: max(start, 0.01))
        }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.rampStepInterval, repeating: Self.rampStepInterval)
        timer.setEventHandler { [weak self] in
            guard let self, isRunning else {
                timer.cancel()
                return
            }
            step += 1
            let progress = Double(step) / Double(totalSteps)
            let rate = RampMath.rate(from: start, to: target, progress: progress)
            CMTimebaseSetRate(timebase, rate: rate)

            if step >= totalSteps {
                timer.cancel()
                rampTimer = nil
                completion?()
            }
        }
        rampTimer = timer
        timer.resume()
    }

    private func cancelRamp() {
        rampTimer?.cancel()
        rampTimer = nil
    }

    // MARK: - Deep Pause

    //
    // After a sustained pause (lock screen overnight, brightness at zero, etc.)
    // the asset reader still holds decoded buffers and the underlying video
    // decoder. Tearing them down frees memory and lets the system fully idle.
    // On resume we recreate the pipeline from scratch via `recreatePlayback()`.

    private static let deepPauseDelay: TimeInterval = 30

    private func scheduleDeepPause() {
        cancelDeepPauseTimer()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.deepPauseDelay)
        timer.setEventHandler { [weak self] in
            self?.enterDeepPause()
        }
        deepPauseTimer = timer
        timer.resume()
    }

    private func cancelDeepPauseTimer() {
        deepPauseTimer?.cancel()
        deepPauseTimer = nil
    }

    /// Runs on the renderer queue when the deep-pause timer fires.
    private func enterDeepPause() {
        deepPauseTimer = nil
        guard isRunning, isPaused, currentReader != nil else { return }
        renderer.stopRequestingMediaData()
        currentReader?.cancelReading()
        nextReader?.cancelReading()
        currentReader = nil
        currentOutput = nil
        nextReader = nil
        nextOutput = nil
        extensionLog("  [Renderer] Deep-paused — freed asset readers")
    }

    /// Rebuild the playback pipeline on the renderer queue. Two modes:
    /// - `seamlessResume: true` (deep-pause wake): CONTINUE from the paused timebase
    ///   position, keeping the last frame on screen — no black flash, no restart-from-0.
    ///   This is what a screen-lock/display-sleep wake uses so the video resumes where it
    ///   left off (Kiri: "show the same video continuously", not blink-and-restart).
    /// - `seamlessResume: false` (error recovery): hard reset to time 0 and clear the
    ///   (possibly corrupt) displayed frame.
    /// Caller restores the timebase rate.
    private func recreatePlayback(seamlessResume: Bool = false) {
        traceLog("  [recreatePlayback #\(debugID)] seamless=\(seamlessResume) asset=\(asset.url.lastPathComponent)")
        renderer.stopRequestingMediaData()
        currentReader?.cancelReading()
        nextReader?.cancelReading()
        nextReader = nil
        nextOutput = nil

        let resumeTime = CMTimebaseGetTime(timebase)
        let continuing = seamlessResume && resumeTime.isNumeric && resumeTime > .zero
        // Keep the last displayed frame when continuing (no black); clear it on error reset.
        renderer.flush(removingDisplayedImage: !continuing)

        guard let reader = try? AVAssetReader(asset: asset) else {
            extensionLog("  [recreatePlayback] FAILED to create AVAssetReader for \(asset.url.lastPathComponent)")
            currentReader = nil
            currentOutput = nil
            return
        }
        if continuing {
            // Resume reading from the paused position (AVAssetReader seeks to the enclosing
            // keyframe and emits from here) so playback continues instead of restarting.
            reader.timeRange = CMTimeRange(start: resumeTime, duration: .positiveInfinity)
        }
        let output = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        reader.startReading()
        currentReader = reader
        currentOutput = output

        ptsOffset = .zero
        lastEnqueuedEnd = continuing ? resumeTime : .zero
        if !continuing {
            CMTimebaseSetTime(timebase, time: .zero)
        }

        // Enqueue the first frame tagged DisplayImmediately so it replaces the held frame the
        // instant it decodes — seamless when continuing, and no wait-on-timebase on reset.
        if let first = output.copyNextSampleBuffer() {
            Self.setDisplayImmediately(first)
            renderer.enqueue(first)
            let pts = CMSampleBufferGetPresentationTimeStamp(first)
            let dur = CMSampleBufferGetDuration(first)
            if pts.isValid {
                lastEnqueuedEnd = dur.isValid && dur > .zero
                    ? CMTimeAdd(pts, dur)
                    : CMTimeAdd(pts, CMTime(value: 1, timescale: 60))
            }
        }

        prepareNextReader()
        feedFromCurrentReader()
    }

    /// Restart playback on the already-set `asset`/`videoTrack` from time 0 — the
    /// video changed, so there's no timeline to preserve (that's only for gapless
    /// looping of the SAME clip). This is `start()`'s sequence applied to a live
    /// renderer: freeze the clock (rate 0) so the fresh PTS-0 frames aren't judged
    /// "late", async-flush the decoder (a `flush` is a decoder RESET and discards
    /// anything enqueued before it completes — that was the "no reaction" bug), then
    /// in the completion reset the timeline to 0, enqueue the first IDR frame, and
    /// resume at rate 1. `removingDisplayedImage:false` holds the last frame (no
    /// black) until that first frame lands. Must run on `queue`.
    private func restartWithCurrentAsset() {
        // Serialize the decoder reset: if a flush is already in flight, just mark that
        // a restart is wanted. When that flush completes it will restart to whatever
        // `asset` is by then (the latest pick) — so rapid switching coalesces to one
        // reset per settle, never two overlapping flushes.
        traceLog("  [restart #\(debugID)] ENTER flushInFlight=\(flushInFlight) restartPending=\(restartPending) asset=\(asset.url.lastPathComponent)")
        if flushInFlight {
            restartPending = true
            traceLog("  [restart #\(debugID)] flush in flight → coalescing to latest (\(asset.url.lastPathComponent))")
            return
        }
        flushInFlight = true
        // Freeze the clock up front so it can't advance past PTS 0 during the async
        // flush — otherwise the first frames arrive "late" and get dropped.
        CMTimebaseSetRate(timebase, rate: 0.0)
        renderer.stopRequestingMediaData()
        currentReader?.cancelReading()
        nextReader?.cancelReading()
        nextReader = nil
        nextOutput = nil

        traceLog("  [restart #\(debugID)] flushing decoder for \(asset.url.lastPathComponent)")
        // Keep the currently displayed frame (no blank) — the first new frame below is
        // tagged DisplayImmediately, which replaces it the instant it decodes.
        renderer.flush(removingDisplayedImage: false) { [weak self] in
            guard let self else { extensionLog("  [restart] FLUSH-CB but self gone (flushInFlight leaks!)"); return }
            traceLog("  [restart #\(debugID)] FLUSH-CB fired (rendererStatus=\(renderer.status.rawValue)) → hop to queue")
            queue.async { [weak self] in
                guard let self else { return }
                flushInFlight = false
                traceLog("  [restart #\(debugID)] FLUSH-CB on queue: flushInFlight→false, restartPending=\(restartPending), asset=\(asset.url.lastPathComponent), isRunning=\(isRunning)")
                // Switches arrived during the flush → do exactly one more restart to
                // the newest asset, instead of feeding this (now stale) one.
                if restartPending {
                    restartPending = false
                    traceLog("  [restart #\(debugID)] coalesced → restarting to \(asset.url.lastPathComponent)")
                    restartWithCurrentAsset()
                    return
                }
                guard isRunning else { return }
                guard let reader = try? AVAssetReader(asset: asset) else {
                    extensionLog("  [restart #\(debugID)] FAILED to create AVAssetReader for \(asset.url.lastPathComponent)")
                    currentReader = nil
                    currentOutput = nil
                    return
                }
                let output = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
                output.alwaysCopiesSampleData = false
                reader.add(output)
                reader.startReading()
                currentReader = reader
                currentOutput = output

                // Fresh timeline from 0.
                ptsOffset = .zero
                lastEnqueuedEnd = .zero
                CMTimebaseSetTime(timebase, time: .zero)

                // Enqueue the first (IDR) frame while the clock is still frozen, exactly
                // like start(), so it isn't dropped as late. Tag it DisplayImmediately so
                // it replaces the retained old frame the moment it decodes — an instant,
                // blank-free swap that doesn't depend on the timebase (important since a
                // switch can land while paused, rate=0).
                if let first = output.copyNextSampleBuffer() {
                    Self.setDisplayImmediately(first)
                    renderer.enqueue(first)
                    let pts = CMSampleBufferGetPresentationTimeStamp(first)
                    let dur = CMSampleBufferGetDuration(first)
                    if pts.isValid {
                        lastEnqueuedEnd = dur.isValid && dur > .zero
                            ? CMTimeAdd(pts, dur)
                            : CMTimeAdd(pts, CMTime(value: 1, timescale: 60))
                    }
                }

                CMTimebaseSetRate(timebase, rate: 1.0)
                if isPaused {
                    holdAfterFirstFrame()
                }
                traceLog("  [restart #\(debugID)] playing \(asset.url.lastPathComponent) rate=\(isPaused ? 0 : 1) rendererStatus=\(renderer.status.rawValue) requiresFlush=\(renderer.requiresFlushToResumeDecoding) readerStatus=\(reader.status.rawValue) err=\(renderer.error?.localizedDescription ?? "-")")
                feedLogBudget = 4
                prepareNextReader()
                feedFromCurrentReader()
            }
        }
    }

    // MARK: - Preloaded Loop Reader

    private func prepareNextReader() {
        // Deferred to a separate queue job so the (brief, blocking) variant track load
        // doesn't stall whatever called us — but still strictly ordered on `queue`,
        // no Task.
        queue.async { [weak self] in
            guard let self, isRunning else { return }
            let nextURL = variantSelector?(currentPolicy)
            if let nextURL, nextURL != asset.url {
                let newAsset = AVURLAsset(url: nextURL)
                guard let track = Self.loadFirstVideoTrackBlocking(newAsset) else {
                    traceLog("  [Renderer] No video track in variant: \(nextURL.lastPathComponent)")
                    return
                }
                installNextReader(asset: newAsset, track: track)
            } else {
                installNextReader(asset: asset, track: videoTrack)
            }
        }
    }

    /// Build an asset reader on the renderer queue and store it as the
    /// preloaded next reader. Must run on `queue`.
    private func installNextReader(asset: AVURLAsset, track: AVAssetTrack) {
        guard let reader = try? AVAssetReader(asset: asset) else {
            traceLog("  [Renderer] Failed to create next reader")
            return
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        nextReader = reader
        nextOutput = output
    }

    /// Swap to the preloaded next reader at a loop boundary.
    /// Uses timing offset for gapless continuation — no flush, no timebase reset.
    private func swapToNextReader() {
        renderer.stopRequestingMediaData()

        // Advance offset so the next loop's DTS/PTS continue the timeline.
        ptsOffset = lastEnqueuedEnd

        if let nr = nextReader, let no = nextOutput {
            if let nrAsset = nr.asset as? AVURLAsset, nrAsset.url != asset.url {
                asset = nrAsset
                videoTrack = no.track
                traceLog("  [Renderer] Switched variant: \(nrAsset.url.lastPathComponent)")
            }
            currentReader = nr
            currentOutput = no
            nextReader = nil
            nextOutput = nil
        } else {
            traceLog("  [Renderer] Next reader not ready, creating synchronously")
            guard let reader = try? AVAssetReader(asset: asset) else {
                traceLog("  [Renderer] Failed to create fallback reader")
                return
            }
            let output = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            reader.add(output)
            currentReader = reader
            currentOutput = output
        }

        currentReader?.startReading()

        prepareNextReader()
        feedFromCurrentReader()
    }

    // MARK: - Playback Loop

    private func feedFromCurrentReader() {
        renderer.requestMediaDataWhenReady(on: queue) { [weak self] in
            guard let self, isRunning else {
                self?.renderer.stopRequestingMediaData()
                return
            }

            // Unrecoverable failure — full reset.
            // Dispatch async: requestMediaDataWhenReady is not reentrant.
            if renderer.status == .failed {
                extensionLog("  [Renderer] Status failed: \(renderer.error?.localizedDescription ?? "unknown"), recovering")
                renderer.stopRequestingMediaData()
                queue.async { [weak self] in
                    self?.recoverFromError()
                }
                return
            }

            // Decoder hit a discontinuity or error — flush and continue feeding.
            if renderer.requiresFlushToResumeDecoding {
                traceLog("  [feed #\(debugID)] requiresFlushToResumeDecoding=YES → renderer.flush() (frames enqueued after may be discarded); status=\(renderer.status.rawValue)")
                renderer.flush()
            }

            var enqueuedThisTick = 0
            while renderer.isReadyForMoreMediaData {
                if let sample = currentOutput?.copyNextSampleBuffer() {
                    let adjusted = offsetTimingForLoop(sample)
                    enqueuedThisTick += 1

                    // Track the highest end time (max handles B-frame reordering).
                    // Some containers emit padding samples with invalid PTS — skip those
                    // to prevent NaN from poisoning the timeline offset.
                    let pts = CMSampleBufferGetPresentationTimeStamp(adjusted)
                    let dur = CMSampleBufferGetDuration(adjusted)
                    if pts.isValid {
                        let sampleEnd = dur.isValid && dur > .zero
                            ? CMTimeAdd(pts, dur)
                            : CMTimeAdd(pts, CMTime(value: 1, timescale: 60))
                        if sampleEnd > lastEnqueuedEnd {
                            lastEnqueuedEnd = sampleEnd
                        }
                    }

                    renderer.enqueue(adjusted)
                } else {
                    // Dispatch async: requestMediaDataWhenReady is not reentrant.
                    if feedLogBudget > 0 {
                        traceLog("  [feed #\(debugID)] reader exhausted after enqueuing this tick=\(enqueuedThisTick); status=\(renderer.status.rawValue) → swapToNextReader")
                    }
                    renderer.stopRequestingMediaData()
                    queue.async { [weak self] in
                        self?.swapToNextReader()
                    }
                    return
                }
            }
            if feedLogBudget > 0 {
                feedLogBudget -= 1
                traceLog("  [feed #\(debugID)] tick enqueued=\(enqueuedThisTick) status=\(renderer.status.rawValue) requiresFlush=\(renderer.requiresFlushToResumeDecoding) ready=\(renderer.isReadyForMoreMediaData) timebase=\(CMTimebaseGetTime(timebase).seconds)")
            }
        }
    }

    /// Offset both DTS and PTS of a sample for gapless looping.
    /// Returns the original sample unchanged for the first loop (no copy needed).
    /// For subsequent loops, creates a lightweight copy with adjusted timing
    /// (shares the underlying data buffer — only the timing metadata differs).
    private func offsetTimingForLoop(_ sample: CMSampleBuffer) -> CMSampleBuffer {
        guard ptsOffset > .zero else { return sample }

        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        let dts = CMSampleBufferGetDecodeTimeStamp(sample)
        let dur = CMSampleBufferGetDuration(sample)

        var timingInfo = CMSampleTimingInfo(
            duration: dur,
            presentationTimeStamp: pts.isValid ? CMTimeAdd(pts, ptsOffset) : pts,
            decodeTimeStamp: dts.isValid ? CMTimeAdd(dts, ptsOffset) : .invalid,
        )

        var adjusted: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(
            allocator: nil,
            sampleBuffer: sample,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timingInfo,
            sampleBufferOut: &adjusted,
        )

        return adjusted ?? sample
    }

    /// Reset everything and restart playback from scratch after a decoder error.
    private func recoverFromError() {
        recreatePlayback()
        CMTimebaseSetRate(timebase, rate: isPaused ? 0.0 : 1.0)
    }
}
