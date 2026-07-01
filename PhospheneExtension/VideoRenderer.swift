// Feeds video sample buffers to an AVSampleBufferDisplayLayer.
//
// AVPlayerLayer doesn't work in remote CAContexts (DisplaySize stays 0x0),
// so we render frames manually — matching what Apple's VideoPlayer does.
//
// Looping is gapless: at each loop boundary, both DTS and PTS of new samples
// are offset to continue the timeline. This avoids flushing the renderer
// (which drops buffered frames and causes visible stuttering).

import AVFoundation
import CoreMedia
import os

final class VideoRenderer: @unchecked Sendable {
    /// Process-wide instance counter so log lines can be attributed to a specific
    /// renderer object (to catch stale/duplicate renderers from acquire races).
    private static let idCounter = OSAllocatedUnfairLock(initialState: 0)
    let debugID: Int = VideoRenderer.idCounter.withLock { $0 += 1; return $0 }

    let displayLayer: AVSampleBufferDisplayLayer
    let timebase: CMTimebase
    private let renderer: AVSampleBufferVideoRenderer
    private let stillFrameLayer: CALayer
    private var asset: AVURLAsset
    private var videoTrack: AVAssetTrack
    private let queue = DispatchQueue(label: "video-renderer", qos: .userInitiated)
    private var isRunning = true
    private(set) var isPaused = false
    private var currentPolicy: PlaybackPolicy = .full
    private var rampTimer: (any DispatchSourceTimer)?
    private var deepPauseTimer: (any DispatchSourceTimer)?

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

    /// Called at each loop boundary to select the video URL for the next iteration.
    var variantSelector: (() -> URL)?

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

        self.stillFrameLayer = CALayer()
        stillFrameLayer.frame = rootLayer.bounds
        stillFrameLayer.contentsGravity = .resizeAspectFill
        stillFrameLayer.contentsScale = rootLayer.contentsScale
        stillFrameLayer.opacity = 0
        stillFrameLayer.name = "phosphene.stillFrame"

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
        rootLayer.sublayers?.filter { $0.name == "phosphene.stillFrame" }.forEach { $0.removeFromSuperlayer() }
        rootLayer.addSublayer(displayLayer)
        rootLayer.addSublayer(stillFrameLayer)
        extensionLog("  [Renderer #\(debugID)] CREATED for \(asset.url.lastPathComponent), displayLayer=\(ObjectIdentifier(displayLayer)), rootLayer sublayers=\((rootLayer.sublayers?.count ?? 0))")
        if let stillImage, let stillBuffer = makeStillSampleBuffer(from: stillImage) {
            renderer.enqueue(stillBuffer)
            extensionLog("  [Renderer #\(debugID)] Seeded still into display layer (\(stillImage.width)x\(stillImage.height))")
        } else {
            extensionLog("  [Renderer #\(debugID)] No still to seed (stillImage present: \(stillImage != nil))")
        }
        CATransaction.commit()
        // flush() (not just commit()) is what pushes the layer tree to the render
        // server for a REMOTE context — without it the still never reaches the
        // WindowServer and the desktop stays black until a later flush.
        CATransaction.flush()
    }

    /// Start playback: decode and enqueue the first frame, then begin the feed loop.
    /// Runs on the renderer's serial queue rather than the caller's thread — the
    /// first-frame `copyNextSampleBuffer` is a blocking decode, and the caller is a
    /// Swift-concurrency (cooperative) task; blocking a cooperative thread violates
    /// forward progress and starves the extension's tiny executor.
    func start() {
        extensionLog("  [start #\(debugID)] asset=\(asset.url.lastPathComponent)")
        queue.async { [weak self] in
            guard let self else { return }
            guard isRunning else { extensionLog("  [start #\(debugID)] aborted — already stopped"); return }
            guard let reader = try? AVAssetReader(asset: self.asset) else { return }
            let output = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            reader.add(output)
            reader.startReading()

            // Reset timebase BEFORE first enqueue so the frame isn't seen as late.
            CMTimebaseSetTime(timebase, time: .zero)

            if let firstSample = output.copyNextSampleBuffer() {
                renderer.enqueue(firstSample)
            }

            currentReader = reader
            currentOutput = output
            ptsOffset = .zero
            lastEnqueuedEnd = .zero

            // Begin advancing the timebase — playback starts.
            CMTimebaseSetRate(timebase, rate: 1.0)

            prepareNextReader()
            feedFromCurrentReader()
        }
    }

    /// Switch to a different video IN PLACE, reusing this renderer's existing
    /// `displayLayer`. The layer is already attached to the display's CAContext and
    /// hosted by WallpaperAgent, so feeding it frames from a new asset updates the
    /// desktop — whereas building a fresh renderer (new `AVSampleBufferDisplayLayer`)
    /// added to an already-hosted context does NOT composite (the switch-between-
    /// videos bug). So we keep the one hosted layer and restart it on the new asset.
    ///
    /// Fully serialized on `queue`, no `Task`: the track load blocks the queue thread
    /// (a real thread we own, which already blocks for decodes). Because every switch
    /// runs to completion in FIFO order on one thread, rapid switching is naturally
    /// last-*requested*-wins with no cancellation bookkeeping — the only async hop is
    /// the renderer's `flush`, which is serialized and coalesces rapid switches.
    func switchVideo(to url: URL) {
        extensionLog("  [switchVideo #\(debugID)] REQUEST target=\(url.lastPathComponent)")
        queue.async { [weak self] in
            guard let self, isRunning else { return }
            // Same file already playing → nothing to do (defuses repeated identical picks).
            if asset.url == url {
                extensionLog("  [switchVideo #\(debugID)] DEDUP: already on \(url.lastPathComponent)")
                return
            }
            let newAsset = AVURLAsset(url: url)
            guard let track = Self.loadFirstVideoTrackBlocking(newAsset) else {
                extensionLog("  [switchVideo #\(debugID)] no video track in \(url.lastPathComponent)")
                return
            }
            asset = newAsset
            videoTrack = track
            extensionLog("  [switchVideo #\(debugID)] restarting from 0 → \(url.lastPathComponent)")
            restartWithCurrentAsset()
        }
    }

    /// Load the first video track synchronously. Call ONLY from the renderer's serial
    /// `queue` — it blocks that (real, owned) thread on a semaphore while AVFoundation
    /// loads the track on its own internal queue, so there's no cooperative-executor
    /// starvation and no out-of-order Task completion. Local files load in a few ms.
    private static func loadFirstVideoTrackBlocking(_ asset: AVURLAsset) -> AVAssetTrack? {
        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: AVAssetTrack?
        asset.loadTracks(withMediaType: .video) { tracks, _ in
            result = tracks?.first
            sem.signal()
        }
        sem.wait()
        return result
    }

    /// Stop playback. Dispatches synchronously to the renderer queue to ensure
    /// no callback is mid-flight before canceling the reader.
    func stop() {
        extensionLog("  [stop #\(debugID)] stopping renderer for \(asset.url.lastPathComponent)")
        cancelDeepPauseTimer()
        queue.sync {
            isRunning = false
            renderer.stopRequestingMediaData()
            currentReader?.cancelReading()
            nextReader?.cancelReading()
        }
        // Clean up layers from the layer tree
        displayLayer.removeFromSuperlayer()
        stillFrameLayer.removeFromSuperlayer()
    }

    func pause() {
        guard !isPaused else { return }
        extensionLog("  [pause #\(debugID)]")
        isPaused = true
        CMTimebaseSetRate(timebase, rate: 0.0)
        generateStillFrame()
        scheduleDeepPause()
    }

    func resume() {
        guard isPaused else { return }
        extensionLog("  [resume #\(debugID)] currentReader=\(currentReader == nil ? "nil(deep)" : "live")")
        isPaused = false
        cancelDeepPauseTimer()
        stillFrameLayer.opacity = 0
        if currentReader == nil {
            // Woke from deep pause — readers were freed. Recreate before resuming.
            queue.async { [weak self] in
                guard let self, isRunning else { return }
                recreatePlayback()
                CMTimebaseSetRate(timebase, rate: 1.0)
            }
        } else {
            CMTimebaseSetRate(timebase, rate: 1.0)
        }
    }

    func applyPolicy(_ policy: PlaybackPolicy, animated: Bool = false) {
        guard policy != currentPolicy else { return }
        let oldPolicy = currentPolicy
        currentPolicy = policy
        cancelRamp()

        switch policy {
        case .paused:
            if animated {
                rampDown()
            } else {
                pause()
            }
        case .full, .reduced, .minimal:
            if animated, oldPolicy == .paused {
                rampUp()
            } else {
                resume()
            }
        }
    }

    // MARK: - Ramp (Apple-like lock screen transition)

    /// Ramp duration in seconds and step interval aligned to display refresh rate.
    /// At 120Hz (8.3ms) this gives 240 steps; at 60Hz it's 120 steps.
    private static let rampDuration: TimeInterval = 2.0
    private static let rampStepInterval: TimeInterval = 1.0 / 120.0

    /// Ease-in-out cubic: smooth acceleration then deceleration.
    /// t in [0, 1] → output in [0, 1].
    private static func easeInOut(_ t: Double) -> Double {
        t < 0.5
            ? 4.0 * t * t * t
            : 1.0 - pow(-2.0 * t + 2.0, 3) / 2.0
    }

    /// Gradually reduce timebase rate to zero, then freeze.
    /// Uses a smooth ease-in curve so the deceleration looks natural.
    private func rampDown() {
        guard !isPaused else { return }
        let totalSteps = Int(Self.rampDuration / Self.rampStepInterval)
        var step = 0

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.rampStepInterval, repeating: Self.rampStepInterval)
        timer.setEventHandler { [weak self] in
            guard let self, self.isRunning else {
                timer.cancel()
                return
            }
            step += 1
            let progress = Double(step) / Double(totalSteps)
            // Ease-in: slow start, fast finish → rate drops slowly at first
            let eased = Self.easeInOut(progress)
            let rate = max(1.0 - eased, 0.0)
            CMTimebaseSetRate(self.timebase, rate: rate)

            if step >= totalSteps {
                timer.cancel()
                self.rampTimer = nil
                self.isPaused = true
                self.generateStillFrame()
                self.scheduleDeepPause()
            }
        }
        rampTimer = timer
        timer.resume()
    }

    /// Gradually increase timebase rate from zero to 1.0.
    /// Uses a smooth ease-out curve so acceleration looks natural.
    private func rampUp() {
        guard isPaused else { return }
        isPaused = false
        cancelDeepPauseTimer()
        stillFrameLayer.opacity = 0

        if currentReader == nil {
            // Deep-paused: no frames to ramp into. Wake instantly instead of
            // running a 2-second ramp against an empty pipeline.
            queue.async { [weak self] in
                guard let self, isRunning else { return }
                recreatePlayback()
                CMTimebaseSetRate(timebase, rate: 1.0)
            }
            return
        }

        let totalSteps = Int(Self.rampDuration / Self.rampStepInterval)
        var step = 0

        // Kick off immediately so there's no dead frame at rate 0
        CMTimebaseSetRate(timebase, rate: 0.01)

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.rampStepInterval, repeating: Self.rampStepInterval)
        timer.setEventHandler { [weak self] in
            guard let self, self.isRunning else {
                timer.cancel()
                return
            }
            step += 1
            let progress = Double(step) / Double(totalSteps)
            let eased = Self.easeInOut(progress)
            let rate = min(eased, 1.0)
            CMTimebaseSetRate(self.timebase, rate: rate)

            if step >= totalSteps {
                timer.cancel()
                self.rampTimer = nil
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

    /// Rebuild the playback pipeline from scratch on the renderer queue. Used
    /// by both deep-pause-wake and the error recovery path. Restarts the
    /// timeline from zero — caller is responsible for restoring timebase rate.
    private func recreatePlayback() {
        extensionLog("  [recreatePlayback #\(debugID)] asset=\(asset.url.lastPathComponent) track.mediaType=\(videoTrack.mediaType.rawValue)")
        renderer.stopRequestingMediaData()
        renderer.flush()
        ptsOffset = .zero
        lastEnqueuedEnd = .zero
        CMTimebaseSetTime(timebase, time: .zero)

        currentReader?.cancelReading()
        nextReader?.cancelReading()
        nextReader = nil
        nextOutput = nil

        guard let reader = try? AVAssetReader(asset: asset) else {
            extensionLog("  [recreatePlayback] FAILED to create AVAssetReader for \(asset.url.lastPathComponent)")
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
        extensionLog("  [recreatePlayback #\(debugID)] reader started status=\(reader.status.rawValue) for \(asset.url.lastPathComponent)")

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
        if flushInFlight {
            restartPending = true
            extensionLog("  [restart #\(debugID)] flush in flight → coalescing to latest (\(asset.url.lastPathComponent))")
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

        extensionLog("  [restart #\(debugID)] flushing decoder (removing displayed image) for \(asset.url.lastPathComponent)")
        renderer.flush(removingDisplayedImage: true) { [weak self] in
            guard let self else { return }
            queue.async { [weak self] in
                guard let self else { return }
                flushInFlight = false
                // Switches arrived during the flush → do exactly one more restart to
                // the newest asset, instead of feeding this (now stale) one.
                if restartPending {
                    restartPending = false
                    extensionLog("  [restart #\(debugID)] coalesced → restarting to \(asset.url.lastPathComponent)")
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
                // like start(), so it isn't dropped as late.
                if let first = output.copyNextSampleBuffer() {
                    renderer.enqueue(first)
                    let pts = CMSampleBufferGetPresentationTimeStamp(first)
                    let dur = CMSampleBufferGetDuration(first)
                    if pts.isValid {
                        lastEnqueuedEnd = dur.isValid && dur > .zero
                            ? CMTimeAdd(pts, dur)
                            : CMTimeAdd(pts, CMTime(value: 1, timescale: 60))
                    }
                }

                CMTimebaseSetRate(timebase, rate: isPaused ? 0.0 : 1.0)
                extensionLog("  [restart #\(debugID)] playing \(asset.url.lastPathComponent) rate=\(isPaused ? 0 : 1) rendererStatus=\(renderer.status.rawValue) requiresFlush=\(renderer.requiresFlushToResumeDecoding) readerStatus=\(reader.status.rawValue) err=\(renderer.error?.localizedDescription ?? "-")")
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
            let nextURL = variantSelector?()
            if let nextURL, nextURL != asset.url {
                let newAsset = AVURLAsset(url: nextURL)
                guard let track = Self.loadFirstVideoTrackBlocking(newAsset) else {
                    extensionLog("  [Renderer] No video track in variant: \(nextURL.lastPathComponent)")
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
            extensionLog("  [Renderer] Failed to create next reader")
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
                extensionLog("  [Renderer] Switched variant: \(nrAsset.url.lastPathComponent)")
            }
            currentReader = nr
            currentOutput = no
            nextReader = nil
            nextOutput = nil
        } else {
            extensionLog("  [Renderer] Next reader not ready, creating synchronously")
            guard let reader = try? AVAssetReader(asset: asset) else {
                extensionLog("  [Renderer] Failed to create fallback reader")
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
                extensionLog("  [feed #\(debugID)] requiresFlushToResumeDecoding=YES → renderer.flush() (frames enqueued after may be discarded); status=\(renderer.status.rawValue)")
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
                        extensionLog("  [feed #\(debugID)] reader exhausted after enqueuing this tick=\(enqueuedThisTick); status=\(renderer.status.rawValue) → swapToNextReader")
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
                extensionLog("  [feed #\(debugID)] tick enqueued=\(enqueuedThisTick) status=\(renderer.status.rawValue) requiresFlush=\(renderer.requiresFlushToResumeDecoding) ready=\(renderer.isReadyForMoreMediaData) timebase=\(CMTimebaseGetTime(timebase).seconds)")
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
            decodeTimeStamp: dts.isValid ? CMTimeAdd(dts, ptsOffset) : .invalid
        )

        var adjusted: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(
            allocator: nil,
            sampleBuffer: sample,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timingInfo,
            sampleBufferOut: &adjusted
        )

        return adjusted ?? sample
    }

    /// Reset everything and restart playback from scratch after a decoder error.
    private func recoverFromError() {
        recreatePlayback()
        CMTimebaseSetRate(timebase, rate: isPaused ? 0.0 : 1.0)
    }

    // MARK: - Still Frame

    private func generateStillFrame() {
        let captureTime = CMTimebaseGetTime(timebase)
        let currentAsset = asset

        Task.detached(priority: .userInitiated) { [weak self] in
            let generator = AVAssetImageGenerator(asset: currentAsset)
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            generator.appliesPreferredTrackTransform = true

            guard let (cgImage, _) = try? await generator.image(at: captureTime) else {
                extensionLog("  [Renderer] Failed to generate still frame")
                return
            }

            await MainActor.run { [weak self] in
                guard let self, self.isPaused else { return }
                self.stillFrameLayer.contents = cgImage
                self.stillFrameLayer.opacity = 1
            }
        }
    }
}
