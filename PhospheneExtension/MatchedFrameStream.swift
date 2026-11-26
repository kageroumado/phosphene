import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

/// Preparation owns the readers until delivery. After that, use the stream exclusively on the render queue or in a catch-up task.
final class MatchedFrameStream: @unchecked Sendable {
    enum Endpoint {
        case from
        case to

        fileprivate var fraction: Float {
            self == .from ? 0 : 1
        }
    }

    enum Output {
        case sample(CMSampleBuffer)
        case handoff(Handoff)
    }

    struct Handoff {
        let asset: AVURLAsset
        let track: AVAssetTrack
        let reader: AVAssetReader
        let output: AVAssetReaderTrackOutput
        /// In global time. Samples subsequently read from `output` still need `loopOffset`.
        let first: CMSampleBuffer
        let at: CMTime
        let loopOffset: CMTime
    }

    private static let catchUpLimit = CMTime(value: 2, timescale: 5)

    private let timeline: Timeline
    private let syncFrames: Set<Int64>
    private var frame: Int64
    private var from: DecodedTrack?
    private var to: DecodedTrack?
    private var blender: MatchedFrameBlender?
    private var terminal: (endpoint: Endpoint, since: Int64)?
    private(set) var frontier: CMTime
    private(set) var poolIsBusy = false

    private init(timeline: Timeline, frame: Int64, frontier: CMTime, from: DecodedTrack, to: DecodedTrack, blender: MatchedFrameBlender) {
        self.timeline = timeline
        syncFrames = Set(timeline.validation.commonSyncFrames.map(Int64.init))
        self.frame = frame
        self.frontier = frontier
        self.from = from
        self.to = to
        self.blender = blender
    }

    @concurrent
    static func prepare(playback: PairRendition.Playback, from: URL, to: URL, at global: CMTime, origin: CMTime) async -> MatchedFrameStream? {
        let timeline = Timeline(validation: playback.validation, origin: origin)
        guard !Task.isCancelled, from != to, let fromIdentity = playback.identity(for: from),
              let toIdentity = playback.identity(for: to), playback.filesMatch,
              let frame = timeline.frame(at: global, roundingUp: true),
              let frontier = timeline.globalTime(frame) else { return nil }

        let local = timeline.localTime(frame)
        let duration = timeline.duration
        let loopDuration = timeline.loopDuration
        async let first = DecodedTrack.open(url: from, identity: fromIdentity, local: local, duration: duration, loopDuration: loopDuration)
        async let second = DecodedTrack.open(url: to, identity: toIdentity, local: local, duration: duration, loopDuration: loopDuration)
        guard case let (outgoing?, incoming?) = await (first, second),
              outgoing.format == incoming.format, let blender = MatchedFrameBlender(),
              !Task.isCancelled, playback.filesMatch else { return nil }
        return MatchedFrameStream(timeline: timeline, frame: frame, frontier: frontier, from: outgoing, to: incoming, blender: blender)
    }

    /// Discards synchronized pairs. Success leaves the next frame at `global`.
    func advance(to global: CMTime) -> Bool {
        guard let from, let to, let target = timeline.frame(at: global), target >= frame,
              global - frontier <= Self.catchUpLimit, resumeBlend() else { return false }
        let deadline = ContinuousClock.now + .milliseconds(400)
        while frame < target {
            let local = timeline.localTime(frame)
            guard !Task.isCancelled, ContinuousClock.now < deadline,
                  let end = timeline.globalTime(frame + 1),
                  from.sample(at: local, duration: timeline.duration) != nil,
                  to.sample(at: local, duration: timeline.duration) != nil else { return false }
            consumeFrame(endingAt: end)
        }
        let local = timeline.localTime(frame)
        return !Task.isCancelled && ContinuousClock.now < deadline && frontier == global &&
            from.sample(at: local, duration: timeline.duration) != nil && to.sample(at: local, duration: timeline.duration) != nil
    }

    /// Keep render-queue access suspended until this returns.
    @concurrent
    func catchUp(to global: CMTime) async -> Bool {
        advance(to: global)
    }

    /// Feed only the requested endpoint while waiting for a common sync. A reversal
    /// resumes the parked reader at the same frontier, before choosing a handoff.
    /// Nil leaves the frontier at the failed frame so the caller can rejoin compressed playback.
    func next(at global: CMTime, fraction: Float, finishing: Endpoint?) -> Output? {
        poolIsBusy = false
        guard global.isNumeric, global.epoch == 0, global == frontier, (0 ... 1).contains(fraction),
              frame < Int64.max, let end = timeline.globalTime(frame + 1),
              global + timeline.duration == end,
              let offset = timeline.globalTime(frame - frame % timeline.frameCount) else { return nil }
        let local = timeline.localTime(frame)
        let duration = timeline.duration
        let endpoint = finishing.flatMap { fraction == $0.fraction ? $0 : nil }
        if let endpoint, syncFrames.contains(frame % timeline.frameCount) {
            guard let selected = endpoint == .from ? from : to,
                  let handoff = selected.handoff(local: local, global: global, duration: duration, offset: offset) else { return nil }
            cancel()
            frontier = end
            return .handoff(handoff)
        }

        if terminal?.endpoint != endpoint {
            guard resumeBlend() else { return nil }
            terminal = endpoint.map { ($0, frame) }
        }

        let sample: CMSampleBuffer?
        if let endpoint {
            let selected = endpoint == .from ? from : to
            sample = selected?.sample(at: local, duration: duration).flatMap { offsetSampleTiming($0, by: offset) }
        } else {
            guard let first = from?.sample(at: local, duration: duration),
                  let second = to?.sample(at: local, duration: duration) else { return nil }
            if fraction == 0 || fraction == 1 {
                sample = offsetSampleTiming(fraction == 0 ? first : second, by: offset)
            } else {
                sample = blender?.blend(first: first, second: second, fraction: fraction, at: global)
                poolIsBusy = blender?.poolIsBusy == true
            }
        }
        guard let sample, Self.matches(sample, at: global, duration: duration) else { return nil }
        consumeFrame(endingAt: end)
        return .sample(sample)
    }

    func cancel() {
        from = nil
        to = nil
        blender = nil
    }

    private func resumeBlend() -> Bool {
        guard let terminal else { return true }
        guard let parked = terminal.endpoint == .from ? to : from else { return false }
        for index in terminal.since ..< frame {
            guard parked.sample(at: timeline.localTime(index), duration: timeline.duration) != nil else { return false }
            parked.consume(looping: (index + 1) % timeline.frameCount == 0)
        }
        self.terminal = nil
        return true
    }

    private func consumeFrame(endingAt end: CMTime) {
        frame += 1
        frontier = end
        let looping = frame % timeline.frameCount == 0
        if terminal?.endpoint != .to {
            from?.consume(looping: looping)
        }
        if terminal?.endpoint != .from {
            to?.consume(looping: looping)
        }
    }

    private static func matches(_ sample: CMSampleBuffer, at time: CMTime, duration: CMTime) -> Bool {
        sample.numSamples == 1 && sample.presentationTimeStamp == time && sample.duration == duration &&
            (sample.decodeTimeStamp.isNumeric || !sample.decodeTimeStamp.isValid)
    }

    private struct Timeline {
        let validation: AppearancePair.Validation
        let origin: CMTime

        var duration: CMTime {
            CMTime(value: validation.frameTicks, timescale: validation.timescale)
        }
        var frameCount: Int64 {
            Int64(validation.frameCount)
        }
        var loopDuration: CMTime {
            CMTime(value: frameCount * validation.frameTicks, timescale: validation.timescale)
        }

        func frame(at global: CMTime, roundingUp: Bool = false) -> Int64? {
            guard global.isNumeric, origin.isNumeric, global.epoch == 0, origin.epoch == 0,
                  global.timescale > 0, origin.timescale > 0, origin.value >= 0, global >= origin else { return nil }
            // Use the exact difference between the clocks before converting to frames.
            let numerator = elapsedNumerator(global) * Int128(validation.timescale)
            let denominator = Int128(global.timescale) * Int128(origin.timescale) * Int128(validation.frameTicks)
            let (quotient, remainder) = numerator.quotientAndRemainder(dividingBy: denominator)
            guard roundingUp || remainder == 0 else { return nil }
            return Int64(exactly: quotient + (remainder == 0 ? 0 : 1))
        }

        func globalTime(_ frame: Int64) -> CMTime? {
            let (ticks, overflow) = frame.multipliedReportingOverflow(by: validation.frameTicks)
            guard !overflow else { return nil }
            let time = origin + CMTime(value: ticks, timescale: validation.timescale)
            guard time.isNumeric, !time.hasBeenRounded ||
                elapsedNumerator(time) * Int128(validation.timescale) == Int128(ticks) * Int128(time.timescale) * Int128(origin.timescale)
            else { return nil }
            return time
        }

        func localTime(_ frame: Int64) -> CMTime {
            CMTime(value: (frame % frameCount) * validation.frameTicks, timescale: validation.timescale)
        }

        private func elapsedNumerator(_ global: CMTime) -> Int128 {
            Int128(global.value) * Int128(origin.timescale) - Int128(origin.value) * Int128(global.timescale)
        }
    }

    /// Each preparation child owns its reader until the stream takes exclusive ownership.
    private final class DecodedTrack: @unchecked Sendable {
        let format: CMFormatDescription
        private let asset: AVURLAsset
        private let track: AVAssetTrack
        private let identity: FileIdentity
        private let pixelFormat: OSType
        private let loopDuration: CMTime
        private let reader: AVAssetReader
        private let output: AVAssetReaderTrackOutput
        private var pending: CMSampleBuffer?
        private var needsReset = false

        private init(
            asset: AVURLAsset,
            track: AVAssetTrack,
            identity: FileIdentity,
            format: CMFormatDescription,
            pixelFormat: OSType,
            loopDuration: CMTime,
            reader: AVAssetReader,
            output: AVAssetReaderTrackOutput,
        ) {
            self.asset = asset
            self.track = track
            self.identity = identity
            self.format = format
            self.pixelFormat = pixelFormat
            self.loopDuration = loopDuration
            self.reader = reader
            self.output = output
        }

        deinit { reader.cancelReading() }

        static func open(url: URL, identity: FileIdentity, local: CMTime, duration: CMTime, loopDuration: CMTime) async -> DecodedTrack? {
            let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            guard let track = try? await asset.loadTracks(withMediaType: .video).first,
                  let formats = try? await track.load(.formatDescriptions), formats.count == 1, let format = formats.first,
                  let pixelFormat = decodePixelFormat(format), !Task.isCancelled else { return nil }
            let settings: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ]
            let range = CMTimeRange(start: local, end: loopDuration)
            guard let (reader, output) = startReader(asset: asset, track: track, range: range, settings: settings) else { return nil }
            let decoded = DecodedTrack(
                asset: asset,
                track: track,
                identity: identity,
                format: format,
                pixelFormat: pixelFormat,
                loopDuration: loopDuration,
                reader: reader,
                output: output,
            )
            decoded.pending = readSample(output, startingAt: local, decoded: true)
            guard !Task.isCancelled, decoded.pending != nil,
                  decoded.sample(at: local, duration: duration) != nil else { return nil }
            return decoded
        }

        func sample(at local: CMTime, duration: CMTime) -> CMSampleBuffer? {
            if needsReset {
                // AVAssetReader can emit a decoded image at the exclusive range end before EOF.
                while let tail = Self.readSample(output, decoded: true) {
                    guard tail.presentationTimeStamp == loopDuration else { return nil }
                }
                guard reader.status == .reading else { return nil }
                let range = CMTimeRange(start: .zero, duration: loopDuration)
                output.reset(forReadingTimeRanges: [NSValue(timeRange: range)])
                needsReset = false
            }
            if pending == nil {
                pending = Self.readSample(output, decoded: true)
            }
            guard let raw = pending, raw.numSamples == 1, raw.presentationTimeStamp == local,
                  raw.decodeTimeStamp.isNumeric || !raw.decodeTimeStamp.isValid,
                  CMSampleBufferDataIsReady(raw), let image = raw.imageBuffer,
                  CVPixelBufferGetPixelFormatType(image) == pixelFormat, unsafe CVPixelBufferGetIOSurface(image) != nil else { return nil }
            if !raw.duration.isValid || raw.duration.isIndefinite {
                // Decoded buffers can omit duration even when the compressed track is CFR.
                let timing = CMSampleTimingInfo(
                    duration: duration,
                    presentationTimeStamp: raw.presentationTimeStamp,
                    decodeTimeStamp: raw.decodeTimeStamp,
                )
                guard let timed = try? CMSampleBuffer(copying: raw, withNewTiming: [timing]) else { return nil }
                pending = timed
                return timed
            }
            return raw.duration == duration ? raw : nil
        }

        func consume(looping: Bool) {
            if looping, pending?.duration == loopDuration {
                return
            }
            pending = nil
            needsReset = looping
        }

        func handoff(local: CMTime, global: CMTime, duration: CMTime, offset: CMTime) -> Handoff? {
            let range = CMTimeRange(start: local, duration: .positiveInfinity)
            guard FileIdentity(of: asset.url) == identity,
                  let (reader, output) = Self.startReader(asset: asset, track: track, range: range, settings: nil) else { return nil }
            guard let sample = Self.readSample(output, startingAt: local),
                  MatchedFrameStream.matches(sample, at: local, duration: duration), sample.formatDescription == format,
                  CMSampleBufferDataIsReady(sample),
                  let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) as? [[CFString: Any]],
                  let first = attachments.first, first[kCMSampleAttachmentKey_NotSync] as? Bool != true,
                  first[kCMSampleAttachmentKey_PartialSync] as? Bool != true,
                  first[kCMSampleAttachmentKey_DoNotDisplay] as? Bool != true,
                  let adjusted = offsetSampleTiming(sample, by: offset), MatchedFrameStream.matches(adjusted, at: global, duration: duration),
                  sample.decodeTimeStamp.isValid == adjusted.decodeTimeStamp.isValid,
                  FileIdentity(of: asset.url) == identity else {
                reader.cancelReading()
                return nil
            }
            return Handoff(asset: asset, track: track, reader: reader, output: output, first: adjusted, at: global, loopOffset: offset)
        }

        private static func startReader(
            asset: AVURLAsset,
            track: AVAssetTrack,
            range: CMTimeRange,
            settings: [String: Any]?,
        ) -> (AVAssetReader, AVAssetReaderTrackOutput)? {
            guard let reader = try? AVAssetReader(asset: asset) else { return nil }
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
            output.alwaysCopiesSampleData = false
            if settings != nil {
                output.supportsRandomAccess = true
            }
            reader.timeRange = range
            guard reader.canAdd(output) else { return nil }
            reader.add(output)
            return reader.startReading() ? (reader, output) : nil
        }

        private static func readSample(
            _ output: AVAssetReaderTrackOutput,
            startingAt local: CMTime? = nil,
            decoded: Bool = false,
        ) -> CMSampleBuffer? {
            while let sample = output.copyNextSampleBuffer() {
                // A decoded output can end with a timing marker that has no image.
                if sample.numSamples == 0 || (decoded && sample.imageBuffer == nil) {
                    continue
                }
                if let local, sample.presentationTimeStamp.isNumeric, sample.presentationTimeStamp < local {
                    continue
                }
                return sample
            }
            return nil
        }

        private static func decodePixelFormat(_ format: CMFormatDescription) -> OSType? {
            let full = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_FullRangeVideo) as? Bool ?? false
            let declaredDepth = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_BitsPerComponent) as? Int
            let atoms = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Any]
            let transfer = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String
            let hdr = transfer == kCVImageBufferTransferFunction_ITU_R_2100_HLG as String ||
                transfer == kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String
            let depth: Int
            let chroma: UInt8
            if let config = atoms?["hvcC"] as? Data, config.count >= 23 {
                // HEVCDecoderConfigurationRecord stores the chroma and both component depths.
                let start = config.startIndex
                chroma = config[start + 16] & 3
                depth = max(declaredDepth ?? 0, 8 + Int(max(config[start + 17] & 7, config[start + 18] & 7)))
            } else if let config = atoms?["avcC"] as? Data, config.count >= 4,
                      [66, 77, 88, 100].contains(config[config.startIndex + 1]) {
                chroma = 1
                depth = declaredDepth ?? 8
            } else if let declaredDepth {
                chroma = 1
                depth = declaredDepth
            } else {
                return nil
            }
            guard (8 ... 10).contains(depth) else { return nil }
            return pixelFormat(chroma: chroma, tenBit: hdr || depth > 8, fullRange: full)
        }

        private static func pixelFormat(chroma: UInt8, tenBit: Bool, fullRange: Bool) -> OSType? {
            switch (chroma, tenBit, fullRange) {
            case (1, false, false): kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            case (1, false, true): kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            case (1, true, false): kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            case (1, true, true): kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
            case (2, false, false): kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange
            case (2, false, true): kCVPixelFormatType_422YpCbCr8BiPlanarFullRange
            case (2, true, false): kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange
            case (2, true, true): kCVPixelFormatType_422YpCbCr10BiPlanarFullRange
            case (3, false, false): kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange
            case (3, false, true): kCVPixelFormatType_444YpCbCr8BiPlanarFullRange
            case (3, true, false): kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange
            case (3, true, true): kCVPixelFormatType_444YpCbCr10BiPlanarFullRange
            default: nil
            }
        }
    }
}
