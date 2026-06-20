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

final class VideoRenderer: @unchecked Sendable {
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
        rootLayer.addSublayer(displayLayer)

        return VideoRenderer(
            rootLayer: rootLayer,
            displayLayer: displayLayer,
            asset: asset,
            videoTrack: track,
        )
    }

    private init(
        rootLayer: CALayer,
        displayLayer: AVSampleBufferDisplayLayer,
        asset: AVURLAsset,
        videoTrack: AVAssetTrack,
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
        rootLayer.addSublayer(stillFrameLayer)

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
    }

    /// Start playback. Synchronously decodes and enqueues the first frame
    /// for immediate display, then begins the continuous feed loop.
    func start() {
        guard let reader = try? AVAssetReader(asset: asset) else { return }
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

    /// Stop playback. Dispatches synchronously to the renderer queue to ensure
    /// no callback is mid-flight before canceling the reader.
    func stop() {
        cancelDeepPauseTimer()
        queue.sync {
            isRunning = false
            renderer.stopRequestingMediaData()
            currentReader?.cancelReading()
            nextReader?.cancelReading()
        }
    }

    func pause() {
        guard !isPaused else { return }
        isPaused = true
        CMTimebaseSetRate(timebase, rate: 0.0)
        generateStillFrame()
        scheduleDeepPause()
    }

    func resume() {
        guard isPaused else { return }
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
            extensionLog("  [Renderer] Failed to create reader during recreate")
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

        prepareNextReader()
        feedFromCurrentReader()
    }

    // MARK: - Preloaded Loop Reader

    private func prepareNextReader() {
        queue.async { [weak self] in
            guard let self, isRunning else { return }

            // The selector is synchronous; the only async work is loading the
            // track for a *new* asset URL. Do that in a Task and hop back to
            // the renderer queue to install the resulting reader, instead of
            // blocking this queue thread on a DispatchSemaphore.
            let nextURL = variantSelector?()
            if let nextURL, nextURL != asset.url {
                let newAsset = AVURLAsset(url: nextURL)
                Task.detached { @Sendable [weak self] in
                    guard let self else { return }
                    guard let track = try? await newAsset.loadTracks(withMediaType: .video).first else {
                        extensionLog("  [Renderer] No video track in variant: \(nextURL.lastPathComponent)")
                        return
                    }
                    nonisolated(unsafe) let loadedTrack = track
                    queue.async { [weak self] in
                        guard let self, isRunning else { return }
                        installNextReader(asset: newAsset, track: loadedTrack)
                    }
                }
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
                renderer.flush()
            }

            while renderer.isReadyForMoreMediaData {
                if let sample = currentOutput?.copyNextSampleBuffer() {
                    let adjusted = offsetTimingForLoop(sample)

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
                    renderer.stopRequestingMediaData()
                    queue.async { [weak self] in
                        self?.swapToNextReader()
                    }
                    return
                }
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
