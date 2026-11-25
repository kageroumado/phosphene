import AVFoundation
import CoreMedia

extension VideoRenderer {
    // MARK: - Targets

    /// Move toward `target`. Safe from any thread; applied in order on the renderer
    /// queue, and a repeat of the current policy is ignored.
    func apply(_ target: SurfaceTarget) {
        queue.async { [self] in reconcile(to: target) }
    }

    private func reconcile(to target: SurfaceTarget) {
        guard isRunning else { return }
        if displayLayer.preferredDynamicRange != target.hdrMode.dynamicRange {
            displayLayer.preferredDynamicRange = target.hdrMode.dynamicRange
            spareLayer?.preferredDynamicRange = target.hdrMode.dynamicRange
        }
        let blendModeChanged = frameMatchedTransitions != target.frameMatchedTransitions
        frameMatchedTransitions = target.frameMatchedTransitions
        let paired = variantSelector?.pair != nil
        let mustStopSettling = paired && settlesAfterSelection && !target.settlesAfterSelection && target.policy == .paused
        let waking = renderingSuspended && !target.renderingSuspended
        settlesAfterSelection = target.settlesAfterSelection
        renderingSuspended = target.renderingSuspended
        let appearanceChanged = wantsDark != target.wantsDark
        wantsDark = target.wantsDark
        let policyChanged = target.policy != currentPolicy
        let pauseChanged = (target.policy == .paused) != (currentPolicy == .paused)
        let retargetTier = paired && policyChanged && target.policy != .paused
        let retargetAppearance = appearanceChanged || blendModeChanged || (pauseChanged && movingAppearance == nil)
        if appearanceChanged, currentFade != nil, !renderingSuspended, !mustStopSettling, !retargetTier,
           let leg = movingAppearance, let pair = variantSelector?.pair, let activePair {
            fadeMovingAppearance(leg, towardIncoming: pair.url(dark: wantsDark, in: activePair) != asset.url)
        } else if renderingSuspended || retargetTier || (matchedDissolve == nil && retargetAppearance) {
            cancelAppearanceCut()
        }
        if renderingSuspended || mustStopSettling {
            if isPaused, rampTimer != nil {
                scheduleDeepPause()
            }
            cancelRamp()
            CMTimebaseSetRate(timebase, rate: 0)
            suspendPairFeed()
            if renderingSuspended {
                appearanceTransition.cancel()
            }
        }
        guard target.policy != currentPolicy else {
            if appearanceChanged || waking || blendModeChanged {
                prepareAppearanceCut()
            }
            return
        }
        extensionLog("  [target #\(debugID)] \(currentPolicy) → \(target.policy)\(target.ramps ? " (ramp)" : "") asset=\(asset.url.lastPathComponent)")
        currentPolicy = target.policy
        switch (target.policy, target.ramps || (paired && hasStarted && settlesAfterSelection)) {
        case (.paused, true): rampDown()
        case (.paused, false): pause()
        case (_, true): rampUp()
        case (_, false): resume()
        }
        prepareAppearanceCut()
    }

    private func pause() {
        guard !isPaused else { return }
        isPaused = true
        cancelRamp()
        CMTimebaseSetRate(timebase, rate: 0.0)
        suspendPairFeed()
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
            resumePairFeed()
            prepareAppearanceCut()
        }
    }

    /// The readers were freed by a deep pause. Rebuild them continuing from the paused
    /// position, so a lock or display-sleep wake resumes the same moment of the video.
    private func wakeFromDeepPause() {
        guard hasStarted, !flushInFlight, !renderingSuspended else { return }
        if pairReadersReleased {
            prepareAppearanceCut()
            return
        }
        recreatePlayback(seamlessResume: true)
        CMTimebaseSetRate(timebase, rate: 1.0)
    }

    // MARK: - Ramp (Apple-like lock screen transition)

    /// Ramp durations in seconds and step interval aligned to display refresh rate.
    /// Ramp-down (unlock → desktop pause) matches the ~6 s deceleration of Apple's
    /// built-in wallpapers after unlock; ramp-up (→ lock screen) stays short so
    /// playback reaches full speed while the lock reveal is still on screen.
    private static let rampUpDuration: TimeInterval = 2.0
    static let rampDownDuration: TimeInterval = 6.0
    private static let rampStepInterval: TimeInterval = 1.0 / 120.0

    /// Run the upstream single-video startup clock long enough to present its first frame.
    func holdAfterFirstFrame() {
        queue.asyncAfter(deadline: .now() + 0.25) { [self] in
            guard isRunning, isPaused, rampTimer == nil else { return }
            CMTimebaseSetRate(timebase, rate: 0)
        }
    }

    func firstFrame(from output: AVAssetReaderTrackOutput) -> CMSampleBuffer? {
        while let sample = output.copyNextSampleBuffer() {
            if sample.numSamples > 0 {
                return sample
            }
        }
        return nil
    }

    /// Gradually reduce the timebase rate to zero, then freeze.
    ///
    /// `isPaused` flips immediately: it is the logical state, and the rate follows.
    /// Flipping it at ramp completion would make a resume arriving mid-ramp look like
    /// a no-op and strand the rate wherever the cancelled ramp left it (slow motion).
    private func rampDown() {
        guard !isPaused || variantSelector?.pair != nil else { return }
        isPaused = true
        cancelDeepPauseTimer()
        ramp(to: 0.0, over: Self.rampDownDuration) { [self] in
            suspendPairFeed()
            scheduleDeepPause()
        }
    }

    /// The selected source can start moving even though the desktop's target is already paused.
    func settleSelection() {
        CMTimebaseSetRate(timebase, rate: 1)
        resumePairFeed()
        rampDown()
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
        resumePairFeed()
        prepareAppearanceCut()
    }

    /// Ease the timebase rate from its CURRENT value to `target`.
    ///
    /// Starting from the live rate is what makes ramps reversible: a reversal
    /// mid-flight travels the remaining distance in proportionally less time,
    /// keeping the rate curve continuous instead of replaying a full schedule
    /// from 1.0 or 0 (which made a paused wallpaper leap to speed and decelerate).
    func ramp(
        to target: Double, over fullDuration: TimeInterval, continuing phase: RampPhase? = nil, then completion: (() -> Void)? = nil,
    ) {
        cancelRamp()
        let liveRate = CMTimebaseGetRate(timebase)
        let distance = abs(target - liveRate)
        guard phase != nil || distance > 0.001 else {
            CMTimebaseSetRate(timebase, rate: target)
            completion?()
            return
        }
        let interval = Self.rampStepInterval
        let start = phase?.startRate ?? liveRate
        let totalSteps = phase?.totalSteps ?? RampMath.steps(distance: distance, fullDuration: fullDuration, stepInterval: interval)
        let firstTick = phase?.firstTick ?? .now() + interval
        var step = phase?.index ?? 0
        if target == 0 {
            rampDownPhase = RampPhase(startRate: start, totalSteps: totalSteps, firstTick: firstTick, index: step)
        }

        // First step lands immediately so a resume never sits on a dead frame.
        if target > start {
            CMTimebaseSetRate(timebase, rate: max(start, 0.01))
        }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: firstTick + Double(step) * interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            guard let self, isRunning else {
                timer.cancel()
                return
            }
            step += 1
            if phase != nil {
                // Catch up to the original schedule if the reader took another tick to install.
                let now = DispatchTime.now().uptimeNanoseconds
                let elapsed = max(now, firstTick.uptimeNanoseconds) - firstTick.uptimeNanoseconds
                let scheduled = Int(Double(elapsed) / (interval * 1_000_000_000)) + 1
                step = min(totalSteps, max(step, scheduled))
            }
            rampDownPhase?.index = step
            let progress = Double(step) / Double(totalSteps)
            let rate = RampMath.rate(from: start, to: target, progress: progress)
            CMTimebaseSetRate(timebase, rate: phase == nil ? rate : min(rate, CMTimebaseGetRate(timebase)))

            if step >= totalSteps {
                timer.cancel()
                rampTimer = nil
                rampDownPhase = nil
                completion?()
            }
        }
        rampTimer = timer
        timer.resume()
    }

    func cancelRamp() {
        rampTimer?.cancel()
        rampTimer = nil
        rampDownPhase = nil
    }

    // MARK: - Deep Pause

    //
    // After a sustained pause (lock screen overnight, brightness at zero, etc.)
    // the asset reader still holds decoded buffers and the underlying video
    // decoder. Tearing them down frees memory and lets the system fully idle.
    // On resume we recreate the pipeline from scratch via `recreatePlayback()`.

    private static let deepPauseDelay: TimeInterval = 30

    func scheduleDeepPause() {
        cancelDeepPauseTimer()
        // Startup arms this timer after installing the readers.
        guard hasStarted, !pairReadersReleased else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.deepPauseDelay)
        timer.setEventHandler { [weak self] in
            self?.enterDeepPause()
        }
        deepPauseTimer = timer
        timer.resume()
    }

    func cancelDeepPauseTimer() {
        deepPauseTimer?.cancel()
        deepPauseTimer = nil
    }

    /// Runs on the renderer queue when the deep-pause timer fires.
    private func enterDeepPause() {
        cancelDeepPauseTimer()
        guard isRunning, isPaused, currentReader != nil, !flushInFlight else { return }
        if variantSelector?.pair != nil {
            pairReadersReleased = true
            pairFeedSuspended = true
            cancelAppearanceCut()
        }
        releaseReaders()
        extensionLog("  [Renderer] Deep-paused — freed asset readers")
        if pairReadersReleased {
            // Discard queued samples while keeping the current image on the display layer.
            renderer.flush()
            prepareAppearanceCut()
        }
    }

    func releaseReaders() {
        cancelPairRefill()
        feedGeneration &+= 1
        renderer.stopRequestingMediaData()
        currentReader?.cancelReading()
        currentReader = nil
        currentOutput = nil
        discardNextReader()
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
        discardNextReader()

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
            // Readers seek within the file; the clock also includes completed loops.
            ptsOffset = CMTimeMinimum(ptsOffset, resumeTime)
            reader.timeRange = CMTimeRange(start: resumeTime - ptsOffset, duration: .positiveInfinity)
        }
        let output = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        reader.startReading()
        currentReader = reader
        currentOutput = output

        lastEnqueuedEnd = continuing ? resumeTime : .zero
        if !continuing {
            ptsOffset = .zero
            CMTimebaseSetTime(timebase, time: .zero)
        }
        recordSnapshotSource(at: continuing ? resumeTime : .zero)

        // Enqueue the first frame tagged DisplayImmediately so it replaces the held frame the
        // instant it decodes — seamless when continuing, and no wait-on-timebase on reset.
        enqueueRestartFrame(firstFrame(from: output).map(offsetTimingForLoop))

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
    func restartWithCurrentAsset(_ reason: SourceChange) {
        // Serialize the decoder reset: if a flush is already in flight, just mark that
        // a restart is wanted. When that flush completes it will restart to whatever
        // `asset` is by then (the latest pick) — so rapid switching coalesces to one
        // reset per settle, never two overlapping flushes.
        traceLog("  [restart #\(debugID)] ENTER flushInFlight=\(flushInFlight) pending=\(pendingRestart != nil) asset=\(asset.url.lastPathComponent)")
        if flushInFlight {
            pendingRestart = reason
            traceLog("  [restart #\(debugID)] flush in flight → coalescing to latest (\(asset.url.lastPathComponent))")
            return
        }
        needsMatchedRecovery = false
        cancelDeepPauseTimer()
        flushInFlight = true
        appearanceTransition.cancel()
        if isPaused, settlesAfterSelection, variantSelector?.pair != nil {
            cancelRamp()
        }
        // Freeze the clock up front so it can't advance past PTS 0 during the async
        // flush — otherwise the first frames arrive "late" and get dropped.
        CMTimebaseSetRate(timebase, rate: 0.0)
        releaseReaders()

        traceLog("  [restart #\(debugID)] flushing decoder for \(asset.url.lastPathComponent)")
        // Keep the currently displayed frame (no blank) — the first new frame below is
        // tagged DisplayImmediately, which replaces it the instant it decodes.
        renderer.flush(removingDisplayedImage: false) { [weak self] in
            guard let self else { return }
            queue.async { [weak self] in
                self?.finishRestart(reason)
            }
        }
    }

    private func finishRestart(_ reason: SourceChange) {
        flushInFlight = false
        guard isRunning else { return }
        traceLog("  [restart #\(debugID)] FLUSH-CB on queue: flushInFlight→false, pending=\(pendingRestart != nil), asset=\(asset.url.lastPathComponent), isRunning=\(isRunning)")
        // Switches arrived during the flush → do exactly one more restart to
        // the newest asset, instead of feeding this (now stale) one.
        if let pendingRestart {
            self.pendingRestart = nil
            traceLog("  [restart #\(debugID)] coalesced → restarting to \(asset.url.lastPathComponent)")
            restartWithCurrentAsset(pendingRestart)
            return
        }
        guard let (reader, output) = startSelectedReader() else {
            extensionLog("  [restart #\(debugID)] FAILED to create AVAssetReader for \(asset.url.lastPathComponent)")
            currentReader = nil
            currentOutput = nil
            return
        }
        currentReader = reader
        currentOutput = output

        // Fresh timeline from 0.
        ptsOffset = .zero
        lastEnqueuedEnd = .zero
        CMTimebaseSetTime(timebase, time: .zero)
        recordSnapshotSource(at: .zero)

        // Enqueue the first (IDR) frame while the clock is still frozen, exactly
        // like start(), so it isn't dropped as late. Tag it DisplayImmediately so
        // it replaces the retained old frame the moment it decodes — an instant,
        // blank-free swap that doesn't depend on the timebase (important since a
        // switch can land while paused, rate=0).
        let paired = variantSelector?.pair != nil
        enqueueRestartFrame(paired ? firstFrame(from: output) : output.copyNextSampleBuffer())

        if !paired, !renderingSuspended {
            CMTimebaseSetRate(timebase, rate: 1)
            if isPaused {
                holdAfterFirstFrame()
                scheduleDeepPause()
            }
        } else if reason == .selection, isPaused, settlesAfterSelection, !renderingSuspended {
            settleSelection()
        } else if rampTimer == nil {
            CMTimebaseSetRate(timebase, rate: isPaused || renderingSuspended ? 0.0 : 1.0)
            if isPaused {
                suspendPairFeed()
                scheduleDeepPause()
            }
        }
        traceLog(
            "  [restart #\(debugID)] playing \(asset.url.lastPathComponent) rate=\(CMTimebaseGetRate(timebase)) " +
                "rendererStatus=\(renderer.status.rawValue) requiresFlush=\(renderer.requiresFlushToResumeDecoding) " +
                "readerStatus=\(reader.status.rawValue) err=\(renderer.error?.localizedDescription ?? "-")",
        )
        prepareAppearanceCut()
        feedLogBudget = 4
        prepareNextReader()
        feedFromCurrentReader()
    }

    private func enqueueRestartFrame(_ frame: CMSampleBuffer?) {
        guard let frame else { return }
        Self.setAttachment(kCMSampleAttachmentKey_DisplayImmediately, on: frame)
        renderer.enqueue(frame)
        if let end = sampleEnd(frame) {
            lastEnqueuedEnd = end
        }
    }

    // MARK: - Preloaded Loop Reader

    func prepareNextReader() {
        // Deferred to a separate queue job so the (brief, blocking) variant track load
        // doesn't stall whatever called us — but still strictly ordered on `queue`,
        // no Task.
        queue.async { [weak self] in
            guard let self, isRunning, !flushInFlight, !renderingSuspended, !pairReadersReleased else { return }
            if let pair = variantSelector?.pair {
                _ = preloadLoopReader(for: pair.url(dark: nextLoopIsDark(for: pair), in: nextPlayback(for: pair)))
            } else {
                _ = preloadLoopReader(for: nextSingleURL())
            }
        }
    }

    private func nextLoopIsDark(for pair: PairRendition) -> Bool {
        guard !useKeyframeCut, let activePair else { return wantsDark }
        return asset.url == pair.url(dark: true, in: activePair)
    }

    private func nextPlayback(for pair: PairRendition) -> PairRendition.Playback {
        // A ramp to pause can cross a loop boundary. Keep its validated tier.
        if isPaused || movingAppearance != nil || matchedDissolve != nil || cutTask != nil, let activePair, pair.retains(activePair) {
            return activePair
        }
        return pair.playback(for: currentPolicy)
    }

    private func nextSingleURL() -> URL {
        variantSelector?.variant(for: currentPolicy) ?? asset.url
    }

    func discardNextReader() {
        nextReader?.cancelReading()
        nextReader = nil
        nextOutput = nil
        nextFile = nil
    }

    private func preloadLoopReader(for url: URL) -> Bool {
        guard let identity = FileIdentity(of: url) else { return false }
        if (nextReader?.asset as? AVURLAsset)?.url == url, nextFile == identity {
            return true
        }
        discardNextReader()

        let sameFile = asset.url == url && openedFile == identity
        let nextAsset = sameFile ? asset : AVURLAsset(url: url)
        guard let track = sameFile ? videoTrack : Self.loadFirstVideoTrackBlocking(nextAsset),
              FileIdentity(of: url) == identity,
              let reader = try? AVAssetReader(asset: nextAsset) else {
            return false
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return false }
        reader.add(output)
        nextReader = reader
        nextOutput = output
        nextFile = identity
        return true
    }

    private func startLoopReader(for url: URL, pair: PairRendition.Playback?) -> Bool {
        guard preloadLoopReader(for: url), let nextReader,
              nextReader.startReading(), nextFile == FileIdentity(of: url),
              pair.map({ $0.identity(for: url) == nextFile && $0.filesMatch }) ?? true else {
            discardNextReader()
            return false
        }
        return true
    }

    /// Swap to the preloaded next reader at a loop boundary.
    /// Uses timing offset for gapless continuation — no flush, no timebase reset.
    private func swapToNextReader() {
        guard isRunning, !flushInFlight, !pairFeedSuspended else { return }
        renderer.stopRequestingMediaData()

        let playback: PairRendition.Playback?
        if let pair = variantSelector?.pair {
            let desired = nextPlayback(for: pair)
            let dark = nextLoopIsDark(for: pair)
            if startLoopReader(for: pair.url(dark: dark, in: desired), pair: desired) {
                playback = desired
            } else if desired != pair.originals, startLoopReader(for: pair.url(dark: dark), pair: pair.originals) {
                playback = pair.originals
            } else {
                extensionLog("  [Renderer #\(debugID)] No validated pair reader for next loop")
                return
            }
        } else {
            let desired = nextSingleURL()
            let original = variantSelector?.fallback ?? asset.url
            guard startLoopReader(for: desired, pair: nil)
                || (desired != original && startLoopReader(for: original, pair: nil)) else {
                extensionLog("  [Renderer #\(debugID)] No reader for next loop")
                return
            }
            playback = nil
        }

        guard let reader = nextReader, let output = nextOutput, let nextAsset = reader.asset as? AVURLAsset else { return }
        if activePair != playback || useKeyframeCut {
            cancelAppearanceCut()
        }
        if asset.url != nextAsset.url {
            traceLog("  [Renderer] Switched variant: \(nextAsset.url.lastPathComponent)")
        }
        ptsOffset = lastEnqueuedEnd
        currentReader = reader
        currentOutput = output
        asset = nextAsset
        videoTrack = output.track
        openedFile = nextFile
        activePair = playback
        nextReader = nil
        nextOutput = nil
        nextFile = nil
        recordSnapshotSource(at: ptsOffset)
        prepareNextReader()
        prepareAppearanceCut()
        feedFromCurrentReader()
    }

    // MARK: - Playback Loop

    func cancelPairRefill() {
        guard let timer = pairRefill else { return }
        pairRefill = nil
        if let source = timer as? DispatchSource {
            CMTimebaseRemoveTimerDispatchSource(timebase, timerSource: source)
        }
        timer.cancel()
    }

    /// Keep enough frames for decoding without queuing seconds of an appearance that may be retired.
    private func deferPairFeedIfFull(_ playback: PairRendition.Playback, generation: Int) -> Bool {
        let frame = CMTime(value: playback.validation.frameTicks, timescale: playback.validation.timescale)
        let reserve: CMTime
        if matchedDissolve != nil {
            // Keep the output surface pool small while blending HDR frames.
            reserve = CMTimeMultiply(frame, multiplier: 2)
        } else {
            // A matched transition can only start after the last queued compressed frame.
            let minimum = CMTime(value: 1, timescale: frameMatchedTransitions ? 24 : 8)
            reserve = CMTimeMaximum(minimum, CMTimeMultiply(frame, multiplier: 3))
        }
        guard lastEnqueuedEnd - CMTimebaseGetTime(timebase) >= reserve + reserve else { return false }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.setEventHandler { [weak self] in
            guard let self, feedGeneration == generation, isRunning, !flushInFlight, !pairFeedSuspended else { return }
            feedFromCurrentReader()
        }
        timer.resume()
        guard let source = timer as? DispatchSource,
              CMTimebaseAddTimerDispatchSource(timebase, timerSource: source) == noErr else {
            timer.cancel()
            return false
        }
        guard CMTimebaseSetTimerDispatchSourceNextFireTime(timebase, timerSource: source, fireTime: lastEnqueuedEnd - reserve, flags: 0) == noErr else {
            CMTimebaseRemoveTimerDispatchSource(timebase, timerSource: source)
            timer.cancel()
            return false
        }
        pairRefill = timer
        renderer.stopRequestingMediaData()
        return true
    }

    func feedFromCurrentReader() {
        guard !pairFeedSuspended, !needsMatchedRecovery else { return }
        cancelPairRefill()
        feedGeneration &+= 1
        let generation = feedGeneration
        renderer.requestMediaDataWhenReady(on: queue) { [weak self] in
            guard self?.feedGeneration == generation else { return }
            guard let self, isRunning, !pairFeedSuspended, !flushInFlight else {
                self?.renderer.stopRequestingMediaData()
                return
            }
            feedReadyFrames(generation: generation)
        }
    }

    private func feedReadyFrames(generation: Int) {
        guard decoderAllowsFeed(generation: generation), pairRefill == nil else { return }
        if let activePair, deferPairFeedIfFull(activePair, generation: generation) {
            return
        }
        var enqueuedThisTick = 0
        // Let the other feed and appearance events run between batches.
        while renderer.isReadyForMoreMediaData, activePair == nil || enqueuedThisTick < 8 {
            if let blend = matchedDissolve, lastEnqueuedEnd >= blend.stream.frontier {
                autoreleasepool { enqueueMatchedFrame() }
                return
            }
            guard let input = currentOutput?.copyNextSampleBuffer() else {
                finishLoop(generation: generation, enqueuedThisTick: enqueuedThisTick)
                return
            }
            if variantSelector?.pair != nil, input.numSamples == 0 {
                continue
            }
            let sample = appearanceSample(input)
            let adjusted = offsetTimingForLoop(sample)
            enqueuedThisTick += 1

            // Track the highest end time for B-frame reordering. Padding samples
            // with invalid PTS must not poison the timeline offset.
            if let end = sampleEnd(adjusted), end > lastEnqueuedEnd {
                lastEnqueuedEnd = end
            }
            renderer.enqueue(adjusted)
        }
        if feedLogBudget > 0 {
            feedLogBudget -= 1
            traceLog(
                "  [feed #\(debugID)] tick enqueued=\(enqueuedThisTick) status=\(renderer.status.rawValue) " +
                    "requiresFlush=\(renderer.requiresFlushToResumeDecoding) ready=\(renderer.isReadyForMoreMediaData) " +
                    "timebase=\(CMTimebaseGetTime(timebase).seconds)",
            )
        }
    }

    private func decoderAllowsFeed(generation: Int) -> Bool {
        if variantSelector?.pair != nil, renderer.status == .failed || renderer.requiresFlushToResumeDecoding {
            requestPairedDecoderRecovery()
            return false
        }

        // Dispatch async: requestMediaDataWhenReady is not reentrant.
        if renderer.status == .failed {
            extensionLog("  [Renderer] Status failed: \(renderer.error?.localizedDescription ?? "unknown"), recovering")
            renderer.stopRequestingMediaData()
            queue.async { [weak self] in
                guard self?.feedGeneration == generation else { return }
                self?.recoverFromError()
            }
            return false
        }

        if renderer.requiresFlushToResumeDecoding {
            traceLog(
                "  [feed #\(debugID)] requiresFlushToResumeDecoding=YES → renderer.flush() " +
                    "(frames enqueued after may be discarded); status=\(renderer.status.rawValue)",
            )
            renderer.flush()
        }
        return true
    }

    private func finishLoop(generation: Int, enqueuedThisTick: Int) {
        // Dispatch async: requestMediaDataWhenReady is not reentrant.
        if feedLogBudget > 0 {
            traceLog(
                "  [feed #\(debugID)] reader exhausted after enqueuing this tick=\(enqueuedThisTick); " +
                    "status=\(renderer.status.rawValue) → swapToNextReader",
            )
        }
        renderer.stopRequestingMediaData()
        queue.async { [weak self] in
            guard self?.feedGeneration == generation else { return }
            self?.swapToNextReader()
        }
    }

    private func sampleEnd(_ sample: CMSampleBuffer) -> CMTime? {
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        guard pts.isValid else { return nil }
        let duration = CMSampleBufferGetDuration(sample)
        return pts + (duration.isValid && duration > .zero ? duration : CMTime(value: 1, timescale: 60))
    }

    /// Offset both DTS and PTS of a sample for gapless looping.
    /// Returns the original sample unchanged for the first loop (no copy needed).
    /// For subsequent loops, creates a lightweight copy with adjusted timing
    /// (shares the underlying data buffer — only the timing metadata differs).
    func offsetTimingForLoop(_ sample: CMSampleBuffer) -> CMSampleBuffer {
        offsetSampleTiming(sample, by: ptsOffset) ?? sample
    }

    /// Resume the chosen member from a validated sync sample after a decoder reset.
    func requestPairedDecoderRecovery() {
        guard isRunning, hasStarted, !flushInFlight, !pairReadersReleased, variantSelector?.pair != nil, !needsMatchedRecovery else { return }
        cancelAppearanceCut()
        needsMatchedRecovery = true
        renderer.stopRequestingMediaData()
        cancelPairRefill()
        feedGeneration &+= 1
        let generation = cutGeneration
        // Repeated hardware failures must not spin the media queue retrying the same file.
        let deadline = max(.now(), nextDecoderRetry)
        nextDecoderRetry = deadline + .seconds(1)
        extensionLog("[Appearance #\(debugID)] Recovering paired decoder from a sync frame")
        queue.asyncAfter(deadline: deadline) { [weak self] in
            guard let self, cutGeneration == generation, needsMatchedRecovery else { return }
            prepareAppearanceCut()
        }
    }

    /// Reset everything and restart playback from scratch after a decoder error.
    private func recoverFromError() {
        recreatePlayback()
        CMTimebaseSetRate(timebase, rate: isPaused ? 0.0 : 1.0)
    }
}
