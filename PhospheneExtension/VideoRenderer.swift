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

    let seededStill: Bool
    var displayLayer: AVSampleBufferDisplayLayer
    let timebase: CMTimebase
    var renderer: AVSampleBufferVideoRenderer
    var spareLayer: AVSampleBufferDisplayLayer
    var spareRenderer: AVSampleBufferVideoRenderer
    var spareFlushInFlight = false
    let queue = DispatchQueue(label: "video-renderer", qos: .userInitiated)

    // Pipeline state shared by the renderer extensions is confined to `queue` after initialization.
    var asset: AVURLAsset
    var videoTrack: AVAssetTrack
    var isRunning = true
    /// `start()` has built the pipeline. Before that a target only sets the logical
    /// state, which `start()` then honors.
    var hasStarted = false
    /// The logical pause state. The timebase rate follows it, through a ramp or a cut.
    var isPaused = false
    var currentPolicy: PlaybackPolicy = .full
    var rampTimer: (any DispatchSourceTimer)?
    var rampDownPhase: RampPhase?
    var deepPauseTimer: (any DispatchSourceTimer)?
    /// Picks the file for the next loop from the current policy (full-rate original or
    /// a reduced-frame-rate variant).
    var variantSelector: VideoSourceSelection?
    var activePair: PairRendition.Playback?
    var wantsDark = false
    var renderingSuspended = false
    var settlesAfterSelection = false
    var pairFeedSuspended = false
    var cutTask: Task<Void, Never>?
    var cutGeneration = 0
    var pendingCut: PreparedAppearanceCut?
    let appearanceTransition = AppearanceTransition()
    var movingAppearance: MovingAppearance?
    var frameMatchedTransitions = false
    var matchedDissolve: MatchedDissolve?
    var needsMatchedRecovery = false
    private var decoderObservers: [any NSObjectProtocol] = []
    var nextDecoderRetry = DispatchTime.now()

    /// Tracks the opacity of samples submitted to the single visible layer.
    struct MatchedDissolve {
        let stream: MatchedFrameStream
        let incoming: URL
        var startHostTime: Double?
        var initial: Double = 0
        var target: Double = 1
        var fraction: Double = 0
        var submitted = 0
        var blended = 0
        var skipped = 0
        var waitingForBufferSince: TimeInterval?
        var finishing = false
    }
    typealias SnapshotDissolve = (fade: AppearanceTransition.Fade, outgoing: SnapshotVideoFile, incoming: SnapshotVideoFile, end: TimeInterval)
    var snapshotDissolves: [SnapshotDissolve] = []
    var currentFade: AppearanceTransition.Fade? {
        guard let last = snapshotDissolves.last, last.end == .infinity else { return nil }
        return last.fade
    }
    var dissolveGeneration = 0
    var useKeyframeCut = false
    var failedSource: FileIdentity?
    typealias VisibleSource = (
        start: CMTime, url: URL, identity: FileIdentity?, playback: PairRendition.Playback?, loopStart: CMTime,
        file: SnapshotVideoFile, fileLoopStart: CMTime,
    )
    var visibleSources: [VisibleSource] = []
    private var snapshotMatchedFrames: [SnapshotMatchedFrame] = []

    /// The task feeding this renderer its surface's targets (`PlaybackStore.follow`).
    private let followTask = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)

    /// The file as it was when the asset was opened. A video made again under the
    /// same name is a new file the open readers never see.
    var openedFile: FileIdentity?
    var currentReader: AVAssetReader?
    var currentOutput: AVAssetReaderTrackOutput?
    var nextReader: AVAssetReader?
    var nextOutput: AVAssetReaderTrackOutput?
    var nextFile: FileIdentity?

    /// A renderer `flush` (decoder reset) is the one async hop in the pipeline, and
    /// TWO overlapping flushes corrupt the renderer (rapid-switch breakage). These two
    /// flags — touched ONLY on `queue` — serialize it: at most one flush is ever in
    /// flight, and a switch arriving during a flush is coalesced, so when the flush
    /// completes we restart once to whatever the latest selected asset is.
    var flushInFlight = false
    enum SourceChange { case selection, reload }
    var pendingRestart: SourceChange?

    /// Diagnostic: number of remaining feed-loop ticks to log after a restart.
    var feedLogBudget = 0
    var feedGeneration = 0
    var pairRefill: (any DispatchSourceTimer)?

    // Gapless looping state.
    // ptsOffset accumulates across loops so both DTS and PTS are monotonically increasing.
    // lastEnqueuedEnd tracks the highest sample end time (max, not last — handles B-frames).
    var ptsOffset: CMTime = .zero
    var lastEnqueuedEnd: CMTime = .zero

    private struct InitialMedia {
        let asset: AVURLAsset
        let track: AVAssetTrack
        let identity: FileIdentity?
        let stillBuffer: SendableBox<CMSampleBuffer>?
        let stillSize: (width: Int, height: Int)?
    }

    static func create(
        rootLayer: CALayer,
        videoURL: URL,
        stillImage: CGImage?,
        seedSource: FileIdentity?,
    ) async throws -> VideoRenderer {
        try await create(
            root: SendableBox(value: rootLayer),
            videoURL: videoURL,
            still: SendableBox(value: stillImage),
            seedSource: seedSource,
        )
    }

    @concurrent
    private static func create(
        root: SendableBox<CALayer>,
        videoURL: URL,
        still: SendableBox<CGImage?>,
        seedSource: FileIdentity?,
    ) async throws -> VideoRenderer {
        let asset = AVURLAsset(url: videoURL)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [
                NSLocalizedDescriptionKey: "No video track found in \(videoURL.lastPathComponent)",
            ])
        }

        let image = seedSource != nil && seedSource == FileIdentity(of: videoURL) ? still.value : nil
        let stillBuffer = image.flatMap(makeStillSampleBuffer(from:))
        let media = InitialMedia(
            asset: asset,
            track: track,
            identity: FileIdentity(of: videoURL),
            stillBuffer: stillBuffer.map { SendableBox(value: $0) },
            stillSize: image.map { ($0.width, $0.height) },
        )
        return await VideoRenderer(root: root, media: media)
    }

    @MainActor
    private static func makeVideoLayer(in root: CALayer) -> AVSampleBufferDisplayLayer {
        let layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspectFill
        layer.frame = root.bounds
        layer.contentsScale = root.contentsScale
        layer.isOpaque = true
        setDisallowsVideoLayerDisplayCompositing(layer, true)
        return layer
    }

    @MainActor
    private init(root: SendableBox<CALayer>, media: sending InitialMedia) {
        let rootLayer = root.value
        seededStill = media.stillBuffer != nil
        displayLayer = Self.makeVideoLayer(in: rootLayer)
        spareLayer = Self.makeVideoLayer(in: rootLayer)
        renderer = displayLayer.sampleBufferRenderer
        spareRenderer = spareLayer.sampleBufferRenderer
        asset = media.asset
        videoTrack = media.track
        let identity = media.identity
        openedFile = identity
        visibleSources = [(.zero, asset.url, identity, nil, .zero, SnapshotVideoFile(url: asset.url, identity: identity), .zero)]

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
        // Install both slots before WallpaperAgent starts hosting the context. The spare has no feed.
        spareLayer.controlTimebase = timebase
        spareLayer.opacity = 0
        rootLayer.addSublayer(spareLayer)
        rootLayer.addSublayer(displayLayer)
        traceLog(
            "  [Renderer #\(debugID)] CREATED for \(asset.url.lastPathComponent), " +
                "displayLayer=\(ObjectIdentifier(displayLayer)), rootLayer sublayers=\(rootLayer.sublayers?.count ?? 0)",
        )
        if let size = media.stillSize, let stillBuffer = media.stillBuffer?.value {
            // Tag DisplayImmediately so the still is shown the instant it's enqueued,
            // rather than waiting on the control timebase (which is frozen at rate 0 here).
            // Without this the frame can sit undisplayed → the layer reads empty → black.
            Self.setAttachment(kCMSampleAttachmentKey_DisplayImmediately, on: stillBuffer)
            renderer.enqueue(stillBuffer)
            traceLog("  [Renderer #\(debugID)] Seeded still into display layer (\(size.width)x\(size.height))")
        } else {
            traceLog("  [Renderer #\(debugID)] No still to seed (stillImage present: \(media.stillSize != nil))")
        }
        CATransaction.commit()
        // flush() (not just commit()) is what pushes the layer tree to the render
        // server for a REMOTE context — without it the still never reaches the
        // WindowServer and the desktop stays black until a later flush.
        CATransaction.flush()
        let notifications = [
            AVSampleBufferVideoRenderer.didFailToDecodeNotification,
            AVSampleBufferVideoRenderer.requiresFlushToResumeDecodingDidChangeNotification,
        ]
        for slot in [renderer, spareRenderer] {
            let id = ObjectIdentifier(slot)
            for name in notifications {
                let observer = NotificationCenter.default.addObserver(forName: name, object: slot, queue: nil) { [weak self] _ in
                    self?.queue.async { [weak self] in
                        guard let self, ObjectIdentifier(renderer) == id,
                              renderer.status == .failed || renderer.requiresFlushToResumeDecoding else { return }
                        requestPairedDecoderRecovery()
                    }
                }
                decoderObservers.append(observer)
            }
        }
    }

    deinit {
        for observer in decoderObservers {
            NotificationCenter.default.removeObserver(observer)
        }
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
    func start(handoff: StartHandoff? = nil) async {
        if let handoff {
            for _ in 0 ..< 2 {
                guard let prepared = await Self.prepareStartHandoff(handoff) else { break }
                let result = await withCheckedContinuation { reply in
                    queue.async { [self] in
                        reply.resume(returning: beginHandoff(prepared))
                    }
                }
                if result == .installed {
                    return
                }
                if result != .retryFrozen {
                    break
                }
            }
        }
        await withCheckedContinuation { (firstFrame: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                beginPlayback { firstFrame.resume() }
            }
        }
    }

    struct StartHandoff: Sendable {
        let predecessor: VideoRenderer
        let pair: PairRendition
        let wantsDark: Bool
        let isCurrent: @Sendable () -> Bool
    }

    private struct StartPhase: Sendable {
        let playback: PairRendition.Playback
        let url: URL
        let loopStart: CMTime
        let time: CMTime
        let rate: Double
        let ramp: RampPhase?
    }

    struct RampPhase: Sendable {
        let startRate: Double
        let totalSteps: Int
        let firstTick: DispatchTime
        var index = 0
    }

    private struct PreparedStartHandoff: Sendable {
        let source: StartHandoff
        let phase: StartPhase
        let frame: PreparedPausedAppearance

        var frameRange: CMTimeRange {
            CMTimeRange(start: frame.loopStart + frame.frame.presentationTimeStamp, duration: frame.frame.duration)
        }
    }

    private enum HandoffResult: Sendable { case installed, retryFrozen, unavailable }

    private func startPhase(for request: StartHandoff) async -> StartPhase? {
        await withCheckedContinuation { reply in
            queue.async { [self] in
                var time = CMTime.invalid
                var rate = 0.0
                guard isRunning, hasStarted, isPaused, currentPolicy == .paused, !renderingSuspended, !flushInFlight,
                      let pair = variantSelector?.pair, pair.pair.membershipID == request.pair.pair.membershipID,
                      CMTimebaseGetTimeAndRate(timebase, timeOut: &time, rateOut: &rate) == 0, time.isNumeric,
                      rate == 0 || (rate > 0 && rate <= 1 && rampDownPhase != nil && !pairFeedSuspended),
                      let visible = visibleSources.last(where: { $0.start <= time }),
                      let playback = visible.playback, request.pair.retains(playback),
                      let identity = pair.originals.identity(for: visible.url), visible.identity == identity else {
                    reply.resume(returning: nil)
                    return
                }
                let url = visible.url == pair.originals.alternate ? playback.alternate : playback.original
                guard url != request.pair.url(dark: request.wantsDark, in: playback) else {
                    reply.resume(returning: nil)
                    return
                }
                reply.resume(returning: StartPhase(
                    playback: playback, url: url, loopStart: visible.loopStart, time: time, rate: rate, ramp: rampDownPhase,
                ))
            }
        }
    }

    private static func prepareStartHandoff(_ source: StartHandoff) async -> PreparedStartHandoff? {
        // A moving reader can catch up from earlier samples; a frozen frame must match exactly.
        for _ in 0 ..< 2 {
            guard !Task.isCancelled, source.isCurrent(), let phase = await source.predecessor.startPhase(for: source),
                  let frame = await PreparedPausedAppearance.prepare(
                      playback: phase.playback, url: phase.url, at: phase.time, loopStart: phase.loopStart,
                  ) else { return nil }
            if let latest = await source.predecessor.startPhase(for: source),
               latest.playback == phase.playback, latest.url == phase.url,
               latest.time >= phase.time, latest.rate <= phase.rate {
                let handoff = PreparedStartHandoff(source: source, phase: latest, frame: frame)
                if latest.rate > 0 || handoff.frameRange.containsTime(latest.time) {
                    return handoff
                }
            }
            frame.reader.cancelReading()
        }
        return nil
    }

    private func beginHandoff(_ handoff: PreparedStartHandoff) -> HandoffResult {
        let phase = handoff.phase
        guard isRunning, !hasStarted, isPaused, currentPolicy == .paused, !renderingSuspended, handoff.source.isCurrent(),
              let pair = variantSelector?.pair, pair.pair.membershipID == handoff.source.pair.pair.membershipID,
              pair.retains(phase.playback), phase.url != pair.url(dark: wantsDark, in: phase.playback) else {
            handoff.frame.reader.cancelReading()
            return .unavailable
        }
        let hostTime = CMClockGetTime(CMClockGetHostTimeClock())
        var time = CMTime.invalid
        var rate = 0.0
        guard CMTimebaseGetTimeAndRate(handoff.source.predecessor.timebase, timeOut: &time, rateOut: &rate) == 0,
              time.isNumeric, time >= phase.time, rate >= 0, rate <= phase.rate else {
            handoff.frame.reader.cancelReading()
            return .unavailable
        }
        if rate == 0, !handoff.frameRange.containsTime(time) {
            handoff.frame.reader.cancelReading()
            return .retryFrozen
        }
        guard CMTimebaseSetRateAndAnchorTime(timebase, rate: rate, anchorTime: time, immediateSourceTime: hostTime) == noErr else {
            handoff.frame.reader.cancelReading()
            return .unavailable
        }
        cancelRamp()
        hasStarted = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        installAppearanceFrame(handoff.frame, playback: phase.playback, at: time, handoffRate: rate)
        CATransaction.commit()
        CATransaction.flush()
        traceLog("  [start #\(debugID)] inherited pair frame at \(time.seconds), rate=\(rate)")
        if rate > 0, let rampPhase = phase.ramp {
            pairFeedSuspended = false
            ramp(to: 0, over: Self.rampDownDuration, continuing: rampPhase) { [self] in
                suspendPairFeed()
                scheduleDeepPause()
                prepareAppearanceCut()
            }
        } else {
            suspendPairFeed()
            scheduleDeepPause()
        }
        prepareNextReader()
        prepareAppearanceCut()
        feedFromCurrentReader()
        return .installed
    }

    /// Runs on `queue`. Calls `firstFrameShown` exactly once.
    private func beginPlayback(firstFrameShown: () -> Void) {
        traceLog("  [start #\(debugID)] asset=\(asset.url.lastPathComponent) paused=\(isPaused)")
        guard isRunning else {
            traceLog("  [start #\(debugID)] aborted — already stopped")
            firstFrameShown()
            return
        }
        loadInitialSource()
        guard let (reader, output) = startSelectedReader() else {
            firstFrameShown()
            return
        }
        hasStarted = true

        let shouldSettle = isPaused && settlesAfterSelection && !renderingSuspended
        let holdFirstFrame = renderingSuspended || (isPaused && !shouldSettle)
        if holdFirstFrame {
            cancelRamp()
            CMTimebaseSetRate(timebase, rate: 0)
        }
        // Reset the timebase before the first enqueue so the frame isn't seen as late.
        CMTimebaseSetTime(timebase, time: .zero)

        // Enqueue the first frame and flush it to the render server inside an
        // action-free transaction, so the context is displaying video before the
        // acquire reply is released.
        let first = firstFrame(from: output)
        if let firstSample = first {
            if holdFirstFrame {
                Self.setAttachment(kCMSampleAttachmentKey_DisplayImmediately, on: firstSample)
            }
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
        recordSnapshotSource(at: .zero)
        if variantSelector?.pair != nil, let first, first.numSamples == 1, first.duration.isNumeric {
            lastEnqueuedEnd = first.presentationTimeStamp + first.duration
        }

        if shouldSettle {
            settleSelection()
        } else if holdFirstFrame {
            suspendPairFeed()
            scheduleDeepPause()
        } else {
            CMTimebaseSetRate(timebase, rate: 1)
        }
        firstFrameShown()

        prepareNextReader()
        prepareAppearanceCut()
        feedFromCurrentReader()
    }

    private func loadInitialSource() {
        if let selector = variantSelector {
            if let pair = selector.pair {
                let playback = pair.playback(for: currentPolicy)
                if !loadSource(pair.url(dark: wantsDark, in: playback), pair: playback) {
                    _ = loadSource(pair.url(dark: wantsDark), pair: pair.originals)
                }
            } else {
                _ = loadSource(selector.variant(for: currentPolicy), pair: nil)
            }
        }
    }

    /// Re-frame the video layer to a new destination geometry (points) and backing
    /// scale, used when a display reconnects at, or switches to, a different
    /// resolution. The layer fills the root with `resizeAspectFill`, so re-framing it
    /// to the full bounds is all that's needed. Synchronous, inside an action-free
    /// flushed transaction, like the acquire path's own layer mutations.
    func resize(to destSize: CGSize, scale: CGFloat) {
        queue.sync {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for layer in [displayLayer, spareLayer] {
                layer.frame = CGRect(origin: .zero, size: destSize)
                layer.contentsScale = scale
            }
            CATransaction.commit()
            CATransaction.flush()
        }
        traceLog("  [resize #\(debugID)] → \(destSize) @\(scale)x")
    }

    func snapshotSelection(requestedAt hostTime: CMTime) async -> WallpaperSnapshotSelection? {
        await withCheckedContinuation { reply in
            queue.async { [self] in
                reply.resume(returning: snapshotSelectionOnQueue(requestedAt: hostTime))
            }
        }
    }

    private func dissolveFile(at requested: TimeInterval, for file: SnapshotVideoFile?) -> SnapshotVideoFile? {
        guard let segment = snapshotDissolves.last(where: { $0.fade.start <= requested && requested < $0.end }),
              file == segment.outgoing || file == segment.incoming else { return nil }
        return segment.fade.opacity(at: requested) >= 0.5 ? segment.incoming : segment.outgoing
    }

    private func snapshotSelectionOnQueue(requestedAt hostTime: CMTime) -> WallpaperSnapshotSelection? {
        guard isRunning else { return nil }
        let clock = CMClockGetHostTimeClock()
        var time = CMTime.invalid
        var rate = 0.0
        guard CMTimebaseGetTimeAndRate(timebase, timeOut: &time, rateOut: &rate) == noErr, time.isNumeric else { return nil }
        var anchor = CMTime.invalid
        if rate > 0, CMSyncGetRelativeRateAndAnchorTime(
               timebase,
               relativeTo: clock,
               relativeRateOut: nil,
               anchorTimeOut: nil,
               relativeToAnchorTimeOut: &anchor,
           ) == noErr,
           anchor.isNumeric, hostTime >= anchor {
            let requestTime = CMSyncConvertTime(hostTime, from: clock, to: timebase)
            if requestTime.isNumeric {
                time = CMTimeMinimum(time, requestTime)
            }
        }

        let visible = visibleSources.last { $0.start <= time }
        var file = visible?.file
        let preserveHDR = displayLayer.preferredDynamicRange != .standard
        var local = CMTime.zero
        if let visible {
            let end = lastEnqueuedEnd
            let phase = end > visible.fileLoopStart && time >= end ? end - CMTime(value: 1, timescale: 1_000_000_000) : time
            local = CMTimeMaximum(.zero, phase - visible.fileLoopStart)
        }

        var display: AVSampleBufferVideoRenderer? = renderer
        if let predominant = dissolveFile(at: hostTime.seconds, for: file) {
            file = predominant
            if predominant.url != asset.url {
                display = movingAppearance?.file == predominant ? spareRenderer : nil
            }
        }

        let frame: WallpaperSnapshotSelection.Frame
        let route: String
        if rate == 0, let pixels = display?.displayedPixelBuffer() {
            frame = .displayed(SendableBox(value: pixels))
            route = "displayed"
        } else if !flushInFlight, let visible,
                  let matched = snapshotMatchedFrames.last(where: { $0.start >= visible.start && $0.covers(time) }) {
            frame = .matched(matched)
            let fallback = matched.fraction < 0.5 ? matched.from : matched.to
            file = SnapshotVideoFile(url: fallback, identity: matched.playback.identity(for: fallback))
            local = matched.localPTS
            route = "matched pts=\(matched.start.seconds) fraction=\(matched.fraction) from=\(matched.from.lastPathComponent) to=\(matched.to.lastPathComponent)"
        } else if !flushInFlight, file != nil {
            frame = .file
            route = display === renderer ? "timeline" : "dissolve-dominant"
        } else {
            return nil
        }
        traceLog(
            "[Snapshot host=\(hostTime.seconds)] renderer=#\(debugID) route=\(route) clock=\(time.seconds) rate=\(rate) " +
                "loop=\(visible?.fileLoopStart.seconds ?? 0) frontier=\(lastEnqueuedEnd.seconds) " +
                "file=\(file?.url.lastPathComponent ?? "nil") local=\(local.seconds)",
        )
        return WallpaperSnapshotSelection(frame: frame, file: flushInFlight ? nil : file, localTime: local, preserveHDR: preserveHDR)
    }

    /// Keep timing and fraction only so snapshot requests cannot pin the playback pool.
    func recordMatchedSnapshotFrame(_ frame: SnapshotMatchedFrame) {
        if snapshotMatchedFrames.count == 16 {
            snapshotMatchedFrames.removeFirst()
        }
        snapshotMatchedFrames.append(frame)
    }

    func recordSnapshotSource(at time: CMTime, loopStart: CMTime? = nil) {
        snapshotMatchedFrames.removeAll { $0.end > time }
        if time == .zero {
            visibleSources.removeAll()
        } else {
            visibleSources.removeAll { $0.start >= time }
            let now = CMTimebaseGetTime(timebase)
            if let index = visibleSources.lastIndex(where: { $0.start <= now }), index > 1 {
                // A request already in flight may predate the latest source boundary.
                visibleSources.removeFirst(index - 1)
            }
        }

        let source: (url: URL, identity: FileIdentity?) = if let activePair, let originals = variantSelector?.pair?.originals {
            asset.url == activePair.alternate
                ? (originals.alternate, originals.validation.alternate)
                : (originals.original, originals.validation.original)
        } else if let selector = variantSelector, asset.url != selector.fallback {
            (selector.fallback, selector.fallbackIdentity)
        } else {
            (asset.url, openedFile)
        }
        let file = SnapshotVideoFile(url: asset.url, identity: openedFile)
        if let last = visibleSources.last, last.url == source.url, last.identity == source.identity, last.playback == activePair,
           last.file == file, last.fileLoopStart == ptsOffset {
            return
        }
        visibleSources.append((time, source.url, source.identity, activePair, loopStart ?? ptsOffset, file, ptsOffset))
    }

    /// Replace the loop-boundary variant selector.
    func setVariantSelector(_ selector: VideoSourceSelection) {
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
    /// state carries over to the new source.
    func switchVideo(to url: URL, selector: VideoSourceSelection) {
        changeSource(to: url, selector: selector, reason: .selection)
    }

    func reload(to url: URL, selector: VideoSourceSelection) {
        changeSource(to: url, selector: selector, reason: .reload)
    }

    private func changeSource(to url: URL, selector: VideoSourceSelection, reason: SourceChange) {
        queue.async { [self] in
            guard isRunning else { return }
            cancelAppearanceCut()
            failedSource = nil
            let previous = variantSelector
            variantSelector = selector
            discardNextReader()
            let sameChoice = previous?.choice == selector.choice && previous?.fallback == selector.fallback
            let currentFileMatches = openedFile != nil && openedFile == FileIdentity(of: asset.url)

            if let pair = selector.pair {
                if sameChoice, let activePair, pair.retains(activePair), currentReader != nil,
                   currentFileMatches, !flushInFlight {
                    prepareNextReader()
                    if CMTimebaseGetRate(timebase) == 0 {
                        suspendPairFeed()
                    }
                    prepareAppearanceCut()
                    return
                }
                let playback = pair.playback(for: currentPolicy)
                if !open(pair.url(dark: wantsDark, in: playback), pair: playback, reason: reason), playback != pair.originals {
                    _ = open(pair.url(dark: wantsDark), pair: pair.originals, reason: reason)
                }
                return
            }

            if !needsMatchedRecovery, reason == .reload, sameChoice, previous?.pair == nil, currentFileMatches,
               previous?.fallbackIdentity == selector.fallbackIdentity,
               let choice = selector.choice, VideoLibrary.shared.hasPlayableVariant(asset.url, for: choice) {
                prepareNextReader()
                return
            }
            if asset.url == url, currentFileMatches, !flushInFlight {
                activePair = nil
                if isPaused {
                    scheduleDeepPause()
                }
                if !renderingSuspended, !isPaused {
                    resumePairFeed()
                }
                if needsMatchedRecovery {
                    prepareAppearanceCut()
                    return
                }
                prepareNextReader()
                return
            }
            if reason == .selection {
                let variant = selector.variant(for: currentPolicy)
                if variant != url, open(variant, pair: nil, reason: reason) {
                    return
                }
            }
            _ = open(url, pair: nil, reason: reason)
        }
    }

    func open(_ url: URL, pair: PairRendition.Playback?, reason: SourceChange) -> Bool {
        guard loadSource(url, pair: pair) else { return false }
        pairFeedSuspended = false
        if hasStarted {
            restartWithCurrentAsset(reason)
        }
        return true
    }

    func startSelectedReader() -> (AVAssetReader, AVAssetReaderTrackOutput)? {
        func startReader() -> (AVAssetReader, AVAssetReaderTrackOutput)? {
            guard openedFile == FileIdentity(of: asset.url), activePair?.filesMatch != false,
                  let reader = try? AVAssetReader(asset: asset) else { return nil }
            let output = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { return nil }
            reader.add(output)
            guard reader.startReading() else { return nil }
            return (reader, output)
        }
        if let result = startReader() {
            return result
        }
        guard let selector = variantSelector else { return nil }
        let original = selector.pair?.url(dark: wantsDark) ?? selector.fallback
        guard original != asset.url, loadSource(original, pair: selector.pair?.originals) else { return nil }
        return startReader()
    }

    private func loadSource(_ url: URL, pair: PairRendition.Playback?) -> Bool {
        guard let identity = FileIdentity(of: url),
              pair.map({ $0.identity(for: url) == identity && $0.filesMatch }) ?? true else { return false }
        if url != asset.url || identity != openedFile {
            let newAsset = AVURLAsset(url: url)
            guard let track = Self.loadFirstVideoTrackBlocking(newAsset), FileIdentity(of: url) == identity,
                  pair?.filesMatch != false else { return false }
            asset = newAsset
            videoTrack = track
            openedFile = identity
        }
        activePair = pair
        return true
    }

    static func setAttachment(_ key: CFString, on sample: CMSampleBuffer) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) else { return }
        let count = CFArrayGetCount(attachments)
        for i in 0 ..< count {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, i), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dict,
                Unmanaged.passUnretained(key).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque(),
            )
        }
    }

    /// Load the first video track synchronously. Call ONLY from the renderer's serial
    /// `queue` — it blocks that (real, owned) thread on a semaphore while AVFoundation
    /// loads the track on its own internal queue, so there's no cooperative-executor
    /// starvation and no out-of-order Task completion. Local files load in a few ms.
    static func loadFirstVideoTrackBlocking(_ asset: AVURLAsset) -> AVAssetTrack? {
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
            cancelPairRefill()
            cancelAppearanceCut()
            appearanceTransition.cancel()
            cancelRamp()
            cancelDeepPauseTimer()
            renderer.stopRequestingMediaData()
            currentReader?.cancelReading()
            nextReader?.cancelReading()
        }
        displayLayer.removeFromSuperlayer()
        spareLayer.removeFromSuperlayer()
    }

    /// Adopt the task that feeds this renderer its targets; `stop()` cancels it.
    func setFollowTask(_ task: Task<Void, Never>) {
        followTask.withLock { $0?.cancel(); $0 = task }
    }
}
