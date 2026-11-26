import AVFoundation
import CoreMedia
import Dispatch

/// A single-use incoming feed. Call on the same serial queue as the primary feed.
/// The caller owns the layer's visibility and flushes it before reuse.
final class MovingAppearance: @unchecked Sendable {
    enum Event {
        case ready
        case failed(Failure)
    }

    enum Failure: Error {
        case stalePreparation
        case timedOut
        case missedPhase
        case reader
        case renderer
        case invalidTimeline
    }

    struct Handoff {
        let asset: AVURLAsset
        let reader: AVAssetReader
        let output: AVAssetReaderTrackOutput
        let loopStart: CMTime
        let lastEnqueuedEnd: CMTime
    }

    let layer: AVSampleBufferDisplayLayer

    private enum State { case idle, warming, ready, finished }

    private struct Reader: @unchecked Sendable {
        let reader: AVAssetReader
        let output: AVAssetReaderTrackOutput
    }

    private let queue: DispatchQueue
    private let timebase: CMTimebase
    private let renderer: AVSampleBufferVideoRenderer
    private let asset: AVURLAsset
    private let track: AVAssetTrack
    private let identity: FileIdentity
    private let frameDuration: CMTime
    private let loopDuration: CMTime
    private let preparedFrameEnd: CMTime

    private var state: State = .idle
    private var source: Reader?
    private var preparedSamples: ArraySlice<CMSampleBuffer>
    private var loopStart: CMTime
    private var lastEnqueuedEnd: CMTime
    private var presentableFrom: CMTime?
    private var requesting = false
    private var timer: (any DispatchSourceTimer)?
    private var readinessObserver: (any NSObjectProtocol)?
    private var displayReady = false
    private var deadline = DispatchTime.distantFuture
    private var onEvent: ((Event) -> Void)?

    private static let refillLead = CMTime(value: 1, timescale: 4)
    private static let maximumLead = CMTime(value: 1, timescale: 2)

    var file: SnapshotVideoFile {
        SnapshotVideoFile(url: asset.url, identity: identity)
    }

    private var loopEnd: CMTime {
        loopStart + loopDuration
    }
    private var rendererFailed: Bool {
        renderer.status == .failed || renderer.requiresFlushToResumeDecoding
    }

    /// Consumes the prepared reader, including when initialization fails.
    init?(
        queue: DispatchQueue,
        timebase: CMTimebase,
        layer: AVSampleBufferDisplayLayer,
        renderer: AVSampleBufferVideoRenderer,
        prepared: PreparedPausedAppearance,
        playback: PairRendition.Playback,
    ) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let asset = prepared.reader.asset as? AVURLAsset,
              let identity = playback.identity(for: asset.url), FileIdentity(of: asset.url) == identity else {
            prepared.reader.cancelReading()
            return nil
        }
        let validation = playback.validation
        self.queue = queue
        self.timebase = timebase
        self.layer = layer
        self.renderer = renderer
        self.asset = asset
        track = prepared.output.track
        self.identity = identity
        frameDuration = CMTime(value: validation.frameTicks, timescale: validation.timescale)
        loopDuration = CMTime(value: Int64(validation.frameCount) * validation.frameTicks, timescale: validation.timescale)
        preparedFrameEnd = prepared.loopStart + prepared.frame.presentationTimeStamp + prepared.frame.duration
        source = Reader(reader: prepared.reader, output: prepared.output)
        preparedSamples = (prepared.preroll + [prepared.frame])[...]
        loopStart = prepared.loopStart
        lastEnqueuedEnd = prepared.loopStart + (prepared.preroll.first ?? prepared.frame).presentationTimeStamp
    }

    deinit {
        if let readinessObserver {
            NotificationCenter.default.removeObserver(readinessObserver)
        }
        timer?.cancel()
        if let source {
            nonisolated(unsafe) let renderer = renderer
            queue.async { [source, requesting] in
                if requesting {
                    renderer.stopRequestingMediaData()
                }
                source.reader.cancelReading()
            }
        }
    }

    /// Keep the attached layer transparent until .ready. Events run on the render queue.
    /// A setup failure may be delivered inside start; .failed can also follow .ready.
    func start(_ onEvent: @escaping (Event) -> Void) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard state == .idle else { return }
        state = .warming
        self.onEvent = onEvent

        let now = CMTimebaseGetTime(timebase)
        // A fresh preparation can jump directly to the live loop's most recent common IDR.
        guard now.isNumeric, now >= lastEnqueuedEnd,
              now <= preparedFrameEnd + CMTime(value: 1, timescale: 4) else {
            fail(.stalePreparation)
            return
        }
        readinessObserver = NotificationCenter.default.addObserver(
            forName: .AVSampleBufferDisplayLayerReadyForDisplayDidChange, object: layer, queue: nil,
        ) { [weak self] _ in self?.refreshDisplayReadiness() }
        refreshDisplayReadiness()
        deadline = .now() + .seconds(1)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.setEventHandler { [weak self] in self?.checkReadiness() }
        timer.schedule(deadline: .now(), repeating: .milliseconds(16), leeway: .milliseconds(2))
        self.timer = timer
        timer.resume()

        requestFeed()
    }

    /// Stops the private media request synchronously, leaving queued frames and the clock intact.
    /// Register the primary request on this queue after a successful handoff.
    func promote() -> Handoff? {
        dispatchPrecondition(condition: .onQueue(queue))
        let now = CMTimebaseGetTime(timebase)
        guard state == .ready, let source, !rendererFailed, displayReady, let presentableFrom,
              now.isNumeric, presentableFrom <= now, now < lastEnqueuedEnd,
              FileIdentity(of: asset.url) == identity else { return nil }
        let status = source.reader.status
        let atEndOfStream = lastEnqueuedEnd == loopEnd
        guard status == .reading || (status == .completed && atEndOfStream) else { return nil }
        let handoff = Handoff(
            asset: asset, reader: source.reader, output: source.output,
            loopStart: loopStart, lastEnqueuedEnd: lastEnqueuedEnd,
        )
        finish()
        return handoff
    }

    /// Cancels this leg without emitting an event. Call before reusing an unpromoted layer.
    func cancel() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard state != .finished else { return }
        let reader = source?.reader
        finish()
        reader?.cancelReading()
    }

    private func finish() {
        // A previously dispatched callback may still run after the primary installs its request.
        state = .finished
        if let readinessObserver {
            NotificationCenter.default.removeObserver(readinessObserver)
            self.readinessObserver = nil
        }
        stopFeed()
        timer?.cancel()
        timer = nil
        source = nil
        preparedSamples = []
        onEvent = nil
    }

    private func fail(_ failure: Failure) {
        let callback = onEvent
        cancel()
        callback?(.failed(failure))
    }

    private func refreshDisplayReadiness() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let ready = layer.isReadyForDisplay
            queue.async { [weak self] in
                self?.displayReady = ready
                self?.checkReadiness()
            }
        }
    }

    private func checkReadiness() {
        guard state == .warming || state == .ready else { return }
        if rendererFailed {
            fail(.renderer)
            return
        }
        let now = CMTimebaseGetTime(timebase)
        if state == .ready {
            if !displayReady || !now.isNumeric || now < (presentableFrom ?? .zero) || now >= lastEnqueuedEnd + frameDuration {
                fail(.missedPhase)
                return
            }
        } else if DispatchTime.now() >= deadline {
            fail(.timedOut)
            return
        }
        if now.isNumeric, lastEnqueuedEnd < now + Self.refillLead {
            requestFeed()
        }
        if state == .warming, preparedSamples.isEmpty, let presentableFrom, now.isNumeric,
           presentableFrom <= now, now < lastEnqueuedEnd, displayReady {
            state = .ready
            onEvent?(.ready)
        }
    }

    private func requestFeed() {
        guard !requesting else { return }
        requesting = true
        renderer.requestMediaDataWhenReady(on: queue) { [weak self] in self?.feed() }
    }

    private func stopFeed() {
        guard requesting else { return }
        requesting = false
        renderer.stopRequestingMediaData()
    }

    private func feed() {
        guard requesting, state == .warming || state == .ready else { return }
        // Bound each callback so the shared queue can service the primary, even for tiny loops.
        for _ in 0 ..< 32 {
            guard !rendererFailed else {
                fail(.renderer)
                return
            }
            guard renderer.isReadyForMoreMediaData, let source else { return }
            // A renderer without a compositing target may continue accepting far-future frames.
            let now = CMTimebaseGetTime(timebase)
            if !now.isNumeric || lastEnqueuedEnd >= now + Self.maximumLead {
                stopFeed()
                return
            }
            if let sample = preparedSamples.popFirst() {
                guard enqueue(sample) else { return }
                if preparedSamples.isEmpty {
                    preparedSamples = []
                }
            } else if let sample = source.output.copyNextSampleBuffer() {
                if sample.numSamples != 0, !enqueue(sample) {
                    return
                }
            } else {
                guard source.reader.status == .completed else {
                    fail(.reader)
                    return
                }
                guard lastEnqueuedEnd == loopEnd else {
                    fail(.invalidTimeline)
                    return
                }
                guard reopen() else {
                    fail(.reader)
                    return
                }
            }
        }
    }

    private func reopen() -> Bool {
        guard FileIdentity(of: asset.url) == identity, let reader = try? AVAssetReader(asset: asset) else { return false }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return false }
        reader.add(output)
        guard reader.startReading() else { return false }
        source = Reader(reader: reader, output: output)
        loopStart = lastEnqueuedEnd
        return true
    }

    private func enqueue(_ sample: CMSampleBuffer) -> Bool {
        guard sample.numSamples == 1, let adjusted = offsetSampleTiming(sample, by: loopStart),
              adjusted.decodeTimeStamp.isNumeric || !sample.decodeTimeStamp.isValid, adjusted.duration == frameDuration,
              adjusted.presentationTimeStamp == lastEnqueuedEnd else {
            fail(.invalidTimeline)
            return false
        }
        let end = adjusted.presentationTimeStamp + adjusted.duration
        guard end.isNumeric, end <= loopEnd else {
            fail(.invalidTimeline)
            return false
        }
        if state == .warming {
            if end <= CMTimebaseGetTime(timebase) {
                // Preserve decoder references without displaying a frame whose slot has passed.
                guard let attachments = CMSampleBufferGetSampleAttachmentsArray(adjusted, createIfNecessary: true),
                      CFArrayGetCount(attachments) == 1 else {
                    fail(.invalidTimeline)
                    return false
                }
                let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
                CFDictionarySetValue(
                    dictionary,
                    Unmanaged.passUnretained(kCMSampleAttachmentKey_DoNotDisplay).toOpaque(),
                    Unmanaged.passUnretained(kCFBooleanTrue).toOpaque(),
                )
                presentableFrom = nil
            } else if presentableFrom == nil {
                presentableFrom = adjusted.presentationTimeStamp
            }
        }
        renderer.enqueue(adjusted)
        lastEnqueuedEnd = end
        return true
    }
}

/// Offsets loop timestamps, preserving sample durations, data and attachments.
func offsetSampleTiming(_ sample: CMSampleBuffer, by offset: CMTime) -> CMSampleBuffer? {
    guard offset.isNumeric else { return nil }
    guard offset > .zero else { return sample }
    func shift(_ time: CMTime) -> CMTime {
        time.isValid ? time + offset : time
    }

    if sample.numSamples > 1 {
        guard var timings = try? sample.sampleTimingInfos() else { return nil }
        for index in timings.indices {
            timings[index].presentationTimeStamp = shift(timings[index].presentationTimeStamp)
            timings[index].decodeTimeStamp = shift(timings[index].decodeTimeStamp)
        }
        return try? CMSampleBuffer(copying: sample, withNewTiming: timings)
    }

    var timing = CMSampleTimingInfo(
        duration: sample.duration,
        presentationTimeStamp: shift(sample.presentationTimeStamp),
        decodeTimeStamp: shift(sample.decodeTimeStamp),
    )
    var adjusted: CMSampleBuffer?
    let status = CMSampleBufferCreateCopyWithNewTiming(
        allocator: nil, sampleBuffer: sample, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &adjusted,
    )
    return status == noErr ? adjusted : nil
}
