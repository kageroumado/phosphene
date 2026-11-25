import AVFoundation
import CoreMedia

extension VideoRenderer {
    func suspendPairFeed() {
        guard variantSelector?.pair != nil, hasStarted, !pairFeedSuspended else { return }
        pairFeedSuspended = true
        cancelPairRefill()
        renderer.stopRequestingMediaData()
        // Both live layers freeze at the same instant; let an ongoing wall-clock fade finish.
        if currentFade != nil, !renderingSuspended {
            return
        }
        cancelAppearanceCut()
        prepareAppearanceCut()
    }

    func resumePairFeed() {
        guard pairFeedSuspended, !pairReadersReleased else { return }
        if movingAppearance == nil {
            cancelAppearanceCut()
        }
        pairFeedSuspended = false
        feedFromCurrentReader()
    }

    func cancelAppearanceCut() {
        if let blend = matchedDissolve {
            if blend.submitted > 0 {
                needsMatchedRecovery = true
                renderer.stopRequestingMediaData()
                cancelPairRefill()
                feedGeneration &+= 1
            }
            blend.stream.cancel()
            matchedDissolve = nil
        }
        if let leg = movingAppearance {
            leg.cancel()
            retireSpareLayer()
            movingAppearance = nil
        }
        endMovingFade()
        useKeyframeCut = false
        cutGeneration &+= 1
        cutTask?.cancel()
        cutTask = nil
        pendingCut?.reader.cancelReading()
        pendingCut = nil
    }

    func discardSpareLayer() {
        guard let spareLayer else { return }
        self.spareLayer = nil
        spareFlushInFlight = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        spareLayer.removeFromSuperlayer()
        CATransaction.commit()
        CATransaction.flush()
    }

    private func retireSpareLayer() {
        guard let retiring = spareLayer else { return }
        let id = ObjectIdentifier(retiring)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        retiring.removeAnimation(forKey: "appearanceOpacity")
        retiring.opacity = 0
        retiring.zPosition = 0
        displayLayer.zPosition = 0
        CATransaction.commit()
        CATransaction.flush()
        spareFlushInFlight = true
        retiring.sampleBufferRenderer.flush(removingDisplayedImage: true) { [weak self] in
            self?.queue.async { [weak self] in
                guard let self, let spareLayer, ObjectIdentifier(spareLayer) == id else { return }
                spareFlushInFlight = false
                prepareAppearanceCut()
            }
        }
    }

    func prepareAppearanceCut() {
        guard hasStarted, isRunning, !flushInFlight,
              !renderingSuspended, cutTask == nil, pendingCut == nil, movingAppearance == nil, matchedDissolve == nil else { return }
        if needsMatchedRecovery || pairReadersReleased {
            prepareHeldAppearance(for: variantSelector?.pair)
            return
        }
        guard let pair = variantSelector?.pair, let activePair else { return }
        let now = CMTimebaseGetTime(timebase)
        if CMTimebaseGetRate(timebase) == 0 {
            if isPaused {
                prepareHeldAppearance(for: pair)
            }
            return
        }
        let wanted = pair.url(dark: wantsDark, in: activePair)
        guard wanted != asset.url, let openedFile, activePair.identity(for: asset.url) == openedFile,
              let identity = activePair.identity(for: wanted), identity != failedSource, activePair.filesMatch else { return }
        let preferred = nextAppearancePlayback(for: pair, retaining: activePair)
        if preferred != activePair, preferred.identity(for: pair.url(dark: wantsDark, in: preferred)) != failedSource {
            prepareHeldAppearance(for: pair, switchingTo: preferred)
            return
        }
        if frameMatchedTransitions, !useKeyframeCut {
            if AppearanceTransition.reduceMotion {
                useKeyframeCut = true
            } else {
                prepareMatchedAppearance(playback: activePair, incoming: wanted)
                return
            }
        }
        if spareLayer == nil {
            // A layer added after the context is hosted cannot be used for a live dissolve.
            useKeyframeCut = true
        }
        if !useKeyframeCut, spareFlushInFlight {
            return
        }
        if !useKeyframeCut,
           let visible = visibleSources.last(where: { $0.start <= now }), visible.playback == activePair {
            prepareMovingAppearance(playback: activePair, url: wanted, at: now, origin: visible.loopStart)
            return
        }
        guard let cut = activePair.nextCut(frontier: lastEnqueuedEnd, loopStart: ptsOffset) else { return }
        let generation = cutGeneration
        cutTask = Task { [weak self] in
            let prepared = await PreparedAppearanceCut.prepare(url: wanted, local: cut.local, at: cut.global, identity: identity)
            guard !Task.isCancelled, let self else {
                prepared?.reader.cancelReading()
                return
            }
            queue.async { [self] in
                guard cutGeneration == generation else {
                    prepared?.reader.cancelReading()
                    return
                }
                cutTask = nil
                guard let prepared else {
                    failedSource = identity
                    extensionLog("[Appearance] Could not prepare \(wanted.lastPathComponent) at \(cut.local.seconds)")
                    return
                }
                if prepared.at < lastEnqueuedEnd {
                    prepared.reader.cancelReading()
                    prepareAppearanceCut()
                } else {
                    pendingCut = prepared
                }
            }
        }
    }

    private func prepareMatchedAppearance(playback: PairRendition.Playback, incoming: URL) {
        let generation = cutGeneration
        let step = CMTime(value: playback.validation.frameTicks, timescale: playback.validation.timescale)
        let leadFrames = Int32(min(8, max(0, (0.08 / step.seconds).rounded(.down))))
        let lead = CMTimeMultiply(step, multiplier: leadFrames)
        let frontier = lastEnqueuedEnd + lead, origin = ptsOffset, outgoing = asset.url
        cutTask = Task { [weak self] in
            var prepared = await MatchedFrameStream.prepare(
                playback: playback,
                from: outgoing,
                to: incoming,
                at: frontier,
                origin: origin,
            )
            guard let self else { return }
            // Keep the current movie feeding while the two decoders catch up to its queued samples.
            for attempt in 0 ... 2 where !Task.isCancelled {
                let candidate = prepared
                let next: CMTime? = await withCheckedContinuation { reply in
                    queue.async { [self] in
                        guard cutGeneration == generation else { reply.resume(returning: nil); return }
                        if let candidate, activePair == playback, asset.url == outgoing {
                            if candidate.frontier >= lastEnqueuedEnd {
                                cutTask = nil
                                matchedDissolve = MatchedDissolve(stream: candidate, incoming: incoming)
                                feedFromCurrentReader()
                                reply.resume(returning: nil)
                                return
                            }
                            if attempt < 2 {
                                reply.resume(returning: lastEnqueuedEnd + lead)
                                return
                            }
                        }
                        fallBackToKeyframe()
                        reply.resume(returning: nil)
                    }
                }
                guard let next, let candidate, !Task.isCancelled else { return }
                if await !(candidate.catchUp(to: next)) {
                    prepared = nil
                }
            }
        }
    }

    /// This feed replaces the compressed feed on the same layer. Its cursor is the first unqueued PTS.
    func enqueueMatchedFrame() {
        guard var blend = matchedDissolve, let playback = activePair, let pair = variantSelector?.pair, CMTimebaseGetRate(timebase) > 0 else { return }
        let desired: Double = pair.url(dark: wantsDark, in: playback) == blend.incoming ? 1 : 0
        if desired != blend.target {
            blend.finishing = false
        }
        let step = CMTime(value: playback.validation.frameTicks, timescale: playback.validation.timescale)
        guard skipLateMatchedFrames(blend, step: step) else {
            fallBackToKeyframe()
            return
        }
        let pts = lastEnqueuedEnd
        let fraction = matchedFraction(&blend, at: pts, desired: desired)
        let terminal: MatchedFrameStream.Endpoint? = blend.finishing ? (blend.target == 1 ? .to : .from) : nil
        guard let result = blend.stream.next(at: pts, fraction: Float(fraction), finishing: terminal) else {
            if retryMatchedFrameIfPoolIsBusy(blend, step: step) {
                return
            }
            extensionLog("[Appearance #\(debugID)] Matched feed unavailable")
            fallBackToKeyframe()
            return
        }
        switch result {
        case let .sample(sample):
            enqueueMatchedSample(sample, blend: &blend, playback: playback, at: pts, fraction: fraction)
        case let .handoff(handoff):
            resumeCompressedFeed(handoff, playback: playback, at: pts)
        }
    }

    private func skipLateMatchedFrames(_ blend: MatchedDissolve, step: CMTime) -> Bool {
        let late = CMTimeConvertScale(CMTimebaseGetTime(timebase) - lastEnqueuedEnd, timescale: step.timescale, method: .roundTowardZero)
        guard blend.submitted > 0, !blend.finishing, late.isNumeric, late.value / step.value >= 2 else { return true }
        // Drop complete pairs whose presentation slots have passed, without submitting GPU work for them.
        let count = Int32(min(4, late.value / step.value))
        let pts = lastEnqueuedEnd + CMTimeMultiply(step, multiplier: count)
        guard blend.stream.advance(to: pts) else { return false }
        lastEnqueuedEnd = pts
        return true
    }

    private func matchedFraction(_ blend: inout MatchedDissolve, at pts: CMTime, desired: Double) -> Double {
        guard !blend.finishing else { return blend.fraction }
        let presentedAt = CMSyncConvertTime(pts, from: timebase, to: CMClockGetHostTimeClock())
        let hostTime = presentedAt.isNumeric ? presentedAt.seconds : CACurrentMediaTime()
        if blend.startHostTime == nil || desired != blend.target {
            blend.startHostTime = hostTime
            blend.initial = blend.fraction
            blend.target = desired
        }
        let elapsed = max(0, hostTime - (blend.startHostTime ?? hostTime))
        let fraction = AppearanceTransition.fraction(from: blend.initial, to: blend.target, elapsed: elapsed)
        if !frameMatchedTransitions || abs(fraction - blend.target) <= 0.001 {
            blend.finishing = true
            return blend.target
        }
        return fraction
    }

    private func retryMatchedFrameIfPoolIsBusy(_ blend: MatchedDissolve, step: CMTime) -> Bool {
        guard blend.stream.poolIsBusy else { return false }
        let now = CACurrentMediaTime()
        let since = blend.waitingForBufferSince ?? now
        guard now - since < 0.2 else { return false }
        var waiting = blend
        waiting.waitingForBufferSince = since
        matchedDissolve = waiting
        renderer.stopRequestingMediaData()
        feedGeneration &+= 1
        let generation = feedGeneration
        queue.asyncAfter(deadline: .now() + min(step.seconds, 1.0 / 60)) { [weak self] in
            guard let self, isRunning, generation == feedGeneration, matchedDissolve != nil else { return }
            feedFromCurrentReader()
        }
        return true
    }

    private func enqueueMatchedSample(
        _ sample: CMSampleBuffer, blend: inout MatchedDissolve, playback: PairRendition.Playback, at pts: CMTime, fraction: Double,
    ) {
        if blend.submitted == 0 {
            currentReader?.cancelReading()
            discardNextReader()
            traceLog("[Appearance #\(debugID)] Started matched frames at \(pts.seconds)s")
        }
        blend.waitingForBufferSince = nil
        blend.submitted += 1
        blend.fraction = fraction
        matchedDissolve = blend
        renderer.enqueue(sample)
        lastEnqueuedEnd = pts + sample.duration
        recordMatchedSnapshotFrame(SnapshotMatchedFrame(
            start: pts, end: lastEnqueuedEnd, loopStart: ptsOffset, playback: playback,
            from: asset.url, to: blend.incoming, fraction: Float(fraction),
        ))
    }

    private func resumeCompressedFeed(
        _ handoff: MatchedFrameStream.Handoff, playback: PairRendition.Playback, at pts: CMTime,
    ) {
        currentReader?.cancelReading()
        discardNextReader()
        asset = handoff.asset
        currentReader = handoff.reader
        currentOutput = handoff.output
        videoTrack = handoff.output.track
        openedFile = playback.identity(for: asset.url)
        ptsOffset = handoff.loopOffset
        let first = handoff.first
        renderer.enqueue(first)
        lastEnqueuedEnd = pts + first.duration
        matchedDissolve = nil
        recordSnapshotSource(at: pts)
        traceLog("[Appearance #\(debugID)] Resumed compressed playback at \(pts.seconds)s")
        prepareNextReader()
        prepareAppearanceCut()
    }

    private func prepareMovingAppearance(playback: PairRendition.Playback, url: URL, at time: CMTime, origin: CMTime) {
        let generation = cutGeneration
        cutTask = Task { [weak self] in
            let prepared = await PreparedPausedAppearance.prepare(playback: playback, url: url, at: time, loopStart: origin)
            guard let self, !Task.isCancelled else {
                prepared?.reader.cancelReading()
                return
            }
            queue.async { [self] in
                guard cutGeneration == generation else {
                    prepared?.reader.cancelReading()
                    return
                }
                cutTask = nil
                guard let prepared, let spareLayer, activePair == playback, CMTimebaseGetRate(timebase) > 0 else {
                    prepared?.reader.cancelReading()
                    fallBackToKeyframe()
                    return
                }
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                spareLayer.zPosition = displayLayer.zPosition + 1
                spareLayer.preferredDynamicRange = displayLayer.preferredDynamicRange
                CATransaction.commit()
                CATransaction.flush()
                guard let leg = MovingAppearance(
                    queue: queue, timebase: timebase, layer: spareLayer, renderer: spareLayer.sampleBufferRenderer, prepared: prepared, playback: playback,
                ) else {
                    fallBackToKeyframe()
                    return
                }
                movingAppearance = leg
                leg.start { [weak self, weak leg] event in
                    guard let self, let leg, movingAppearance === leg else { return }
                    switch event {
                    case .ready:
                        fadeMovingAppearance(leg, towardIncoming: true)
                    case let .failed(reason):
                        extensionLog("[Appearance #\(debugID)] Live dissolve unavailable: \(reason)")
                        fallBackToKeyframe()
                    }
                }
            }
        }
    }

    private func fallBackToKeyframe() {
        cancelAppearanceCut()
        useKeyframeCut = true
        traceLog("[Appearance #\(debugID)] Using a synchronized keyframe cut")
        prepareAppearanceCut()
    }

    private func endMovingFade(at time: TimeInterval = CACurrentMediaTime()) {
        if currentFade != nil {
            snapshotDissolves[snapshotDissolves.count - 1].end = time
        }
    }

    func fadeMovingAppearance(_ leg: MovingAppearance, towardIncoming: Bool) {
        let start = CACurrentMediaTime()
        let from = currentFade?.opacity(at: start) ?? 0
        endMovingFade(at: start)
        let fade = AppearanceTransition.Fade(start: start, from: from, to: towardIncoming ? 1 : 0)
        // Keep recent segments for XPC requests that reach the render queue after a reversal or handoff.
        if snapshotDissolves.count == 16 {
            snapshotDissolves.removeFirst()
        }
        snapshotDissolves.append((fade, SnapshotVideoFile(url: asset.url, identity: openedFile), leg.file, .infinity))
        fade.apply(to: leg.layer)
        dissolveGeneration &+= 1
        let generation = dissolveGeneration
        queue.asyncAfter(deadline: .now() + fade.duration) { [weak self, weak leg] in
            guard let self, let leg, movingAppearance === leg, dissolveGeneration == generation else { return }
            guard towardIncoming else {
                cancelAppearanceCut()
                return
            }
            guard let spareLayer, let activePair, let handoff = leg.promote() else {
                fallBackToKeyframe()
                return
            }
            let now = CMTimebaseGetTime(timebase)
            let origin = visibleSources.last(where: { $0.start <= now })?.loopStart
            renderer.stopRequestingMediaData()
            currentReader?.cancelReading()
            discardNextReader()
            self.spareLayer = displayLayer
            displayLayer = spareLayer
            renderer = spareLayer.sampleBufferRenderer
            currentReader = handoff.reader
            currentOutput = handoff.output
            asset = handoff.asset
            videoTrack = handoff.output.track
            openedFile = activePair.identity(for: asset.url)
            ptsOffset = handoff.loopStart
            lastEnqueuedEnd = handoff.lastEnqueuedEnd
            movingAppearance = nil
            endMovingFade()
            visibleSources.removeAll { $0.start >= now }
            recordSnapshotSource(at: now, loopStart: origin)
            retireSpareLayer()
            prepareNextReader()
            feedFromCurrentReader()
        }
    }

    private func nextAppearancePlayback(for pair: PairRendition, retaining playback: PairRendition.Playback) -> PairRendition.Playback {
        currentPolicy == .paused ? playback : pair.playback(for: currentPolicy)
    }

    /// Rebuild decoder references from a sync frame at the visible phase, even when the readers are gone.
    private func prepareHeldAppearance(for pair: PairRendition?, switchingTo preferred: PairRendition.Playback? = nil) {
        let time = CMTimebaseGetTime(timebase)
        guard let selector = variantSelector else { return }
        let waking = pairReadersReleased && !isPaused
        guard let visible = visibleSources.last(where: { $0.start <= time }),
              let visiblePlayback = visible.playback, pair?.retains(visiblePlayback) != false else {
            if waking || needsMatchedRecovery {
                _ = open(pair?.url(dark: wantsDark) ?? selector.fallback, pair: pair?.originals, reason: .reload)
            }
            return
        }
        let playback: PairRendition.Playback = if let preferred {
            preferred
        } else if waking || needsMatchedRecovery, let pair {
            nextAppearancePlayback(for: pair, retaining: visiblePlayback)
        } else {
            visiblePlayback
        }
        let wanted = pair?.url(dark: wantsDark, in: playback) ?? selector.fallback
        let changesImage = visible.url != (pair?.url(dark: wantsDark) ?? wanted)
        guard waking || needsMatchedRecovery || changesImage || activePair.map({ asset.url != pair?.url(dark: wantsDark, in: $0) }) == true else { return }
        let restoredPair = pair == nil ? nil : playback
        let generation = cutGeneration
        cutTask = Task { [weak self] in
            let prepared = await PreparedPausedAppearance.prepare(playback: playback, url: wanted, at: time, loopStart: visible.loopStart)
            guard !Task.isCancelled, let self else {
                prepared?.reader.cancelReading()
                return
            }
            queue.async { [self] in
                var installed = false
                defer {
                    if !installed {
                        prepared?.reader.cancelReading()
                    }
                }
                guard cutGeneration == generation else { return }
                cutTask = nil
                guard isRunning, !renderingSuspended, !flushInFlight else { return }
                guard let prepared, playback.filesMatch else {
                    if waking || needsMatchedRecovery {
                        _ = open(pair?.url(dark: wantsDark) ?? selector.fallback, pair: pair?.originals, reason: .reload)
                    } else if preferred != nil {
                        failedSource = playback.identity(for: wanted)
                        prepareAppearanceCut()
                    }
                    return
                }
                // A policy update can supersede a running retier while its frame is loading.
                if let pair, preferred != nil, preferred != nextAppearancePlayback(for: pair, retaining: visiblePlayback) {
                    prepareAppearanceCut()
                    return
                }
                let now = CMTimebaseGetTime(timebase)
                let rate = CMTimebaseGetRate(timebase)
                if rate == 0, now != time {
                    prepareAppearanceCut()
                    return
                }
                appearanceTransition.cancel()
                let fadeHeldFrame = changesImage && rate == 0 && !waking
                if fadeHeldFrame {
                    appearanceTransition.begin(on: displayLayer, renderer: renderer)
                }
                installAppearanceFrame(prepared, playback: restoredPair, at: now, handoffRate: rate > 0 ? rate : nil)
                installed = true
                if fadeHeldFrame {
                    appearanceTransition.reveal()
                }
                if waking {
                    pairReadersReleased = false
                    pairFeedSuspended = false
                    CMTimebaseSetRate(timebase, rate: 1)
                }
                if pairReadersReleased {
                    releaseReaders()
                } else if CMTimebaseGetRate(timebase) > 0 {
                    prepareNextReader()
                    feedFromCurrentReader()
                }
            }
        }
    }

    func installAppearanceFrame(
        _ prepared: PreparedPausedAppearance, playback: PairRendition.Playback?, at time: CMTime, handoffRate: Double? = nil,
    ) {
        guard let source = prepared.reader.asset as? AVURLAsset else { return }
        needsMatchedRecovery = false
        renderer.stopRequestingMediaData()
        currentReader?.cancelReading()
        discardNextReader()
        renderer.flush()
        activePair = playback
        currentReader = prepared.reader
        currentOutput = prepared.output
        videoTrack = prepared.output.track
        asset = source
        openedFile = playback?.identity(for: source.url) ?? FileIdentity(of: source.url)
        ptsOffset = prepared.loopStart
        for sample in prepared.preroll {
            let adjusted = offsetTimingForLoop(sample)
            Self.setAttachment(kCMSampleAttachmentKey_DoNotDisplay, on: adjusted)
            renderer.enqueue(adjusted)
        }
        let frame = offsetTimingForLoop(prepared.frame)
        let frameEnd = frame.presentationTimeStamp + frame.duration
        if let handoffRate {
            let now = CMTimebaseGetTime(timebase)
            if frameEnd <= now {
                // Keep expired frames for decoder references during a coasting handoff.
                Self.setAttachment(kCMSampleAttachmentKey_DoNotDisplay, on: frame)
            } else if handoffRate == 0, frame.presentationTimeStamp <= now {
                Self.setAttachment(kCMSampleAttachmentKey_DisplayImmediately, on: frame)
            }
        } else if CMTimebaseGetRate(timebase) == 0 {
            Self.setAttachment(kCMSampleAttachmentKey_DisplayImmediately, on: frame)
        }
        renderer.enqueue(frame)
        lastEnqueuedEnd = frameEnd
        visibleSources.removeAll { $0.start >= time }
        recordSnapshotSource(at: time)
    }

    func appearanceSample(_ old: CMSampleBuffer) -> CMSampleBuffer {
        guard let cut = pendingCut, let activePair else { return old }
        let time = ptsOffset + old.presentationTimeStamp
        guard time >= cut.at else { return old }
        pendingCut = nil
        var installed = false
        defer {
            if !installed {
                cut.reader.cancelReading()
            }
        }
        if time > cut.at {
            prepareAppearanceCut()
            return old
        }
        guard let next = cut.reader.asset as? AVURLAsset, let identity = activePair.identity(for: next.url),
              activePair.filesMatch, openedFile == activePair.identity(for: asset.url),
              old.formatDescription == cut.first.formatDescription, old.duration == cut.first.duration,
              old.presentationTimeStamp == cut.first.presentationTimeStamp,
              old.decodeTimeStamp == cut.first.decodeTimeStamp || (!old.decodeTimeStamp.isValid && !cut.first.decodeTimeStamp.isValid)
        else {
            if let next = cut.reader.asset as? AVURLAsset {
                failedSource = activePair.identity(for: next.url)
            }
            return old
        }
        currentReader?.cancelReading()
        currentReader = cut.reader
        currentOutput = cut.output
        installed = true
        asset = next
        openedFile = identity
        videoTrack = cut.output.track
        recordSnapshotSource(at: time)
        prepareNextReader()
        traceLog("[Appearance] Switched to \(next.url.lastPathComponent) at \(time.seconds)")
        return cut.first
    }
}
