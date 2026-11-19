import AVFoundation
import CoreMedia
import CoreVideo
import os
import VideoToolbox

/// Video variant descriptor matching the extension's VideoVariant type.
nonisolated struct VideoVariant: Codable, Sendable {
    let filename: String
    let fps: Int
    let resolution: CGSize
    var isHDR: Bool? = nil
    var toneMappedToSDR: Bool? = nil
}

enum OptimizationPreset: String, CaseIterable, Identifiable {
    case batterySaver = "Battery Saver"
    case balanced = "Balanced"
    case quality = "Quality"

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .batterySaver: String(localized: "Battery Saver")
        case .balanced: String(localized: "Balanced")
        case .quality: String(localized: "Quality")
        }
    }

    func targetResolution(source: CGSize) -> CGSize {
        switch self {
        case .batterySaver:
            guard source.width > 1_920 else { return source }
            let scale = 1_920.0 / source.width
            return CGSize(width: 1_920, height: (source.height * scale).rounded())
        case .balanced, .quality:
            return source
        }
    }
}

enum VideoOptimizationService {
    nonisolated enum OptimizationError: LocalizedError {
        case unsupportedDynamicRange
        case missingResolution
        case noVideoTrack
        case encodingFailed(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedDynamicRange:
                String(localized: "Optimization requires a supported SDR, HLG, or PQ video.")
            case .missingResolution:
                String(localized: "Video resolution is unavailable.")
            case .noVideoTrack:
                "Source video contains no video track"
            case let .encodingFailed(reason):
                "Video encoding failed: \(reason)"
            }
        }
    }

    nonisolated static func eligibilityError(sourceIsHDR: Bool?, resolution: CGSize) -> OptimizationError? {
        guard sourceIsHDR != nil else { return .unsupportedDynamicRange }
        guard resolution.width.isFinite, resolution.width >= 1,
              resolution.height.isFinite, resolution.height >= 1,
              resolution.width <= CGFloat(Int32.max), resolution.height <= CGFloat(Int32.max) else { return .missingResolution }
        return nil
    }

    /// Computes FPS tiers by repeatedly halving the source rate, stopping before 8 fps.
    nonisolated static func computeFPSTiers(sourceRate: Float) -> [Int] {
        var rate = Int(sourceRate.rounded())
        var tiers: [Int] = [rate]
        while rate / 2 >= 8 {
            rate /= 2
            tiers.append(rate)
        }
        if tiers.count < 2, let first = tiers.first, first > 8 {
            tiers.append(max(first / 2, 8))
        }
        return tiers
    }

    /// Writes one video-only MP4 on the settings' frame clock.
    @concurrent
    static func convert(
        sourceURL: URL,
        to outputURL: URL,
        settings: ConversionSettings,
        forPair: Bool,
        assumeSDR: Bool = false,
        progress: @escaping @MainActor @Sendable (Double) -> Void,
    ) async throws {
        try settings.validate(forPair: forPair)
        let step = settings.frameDuration
        let count = settings.frameCount
        let duration = CMTimeMultiply(step, multiplier: count)
        let bitrate = Int((settings.bitrateMbps * 1_000_000).rounded())
        try Task.checkCancellation()

        let scoped = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if scoped {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }
        let asset = AVURLAsset(url: sourceURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let source = try await loadSource(in: asset, assumeSDR: assumeSDR)
        let timeRange = try await source.track.load(.timeRange)
        guard timeRange.start.isNumeric, timeRange.duration.isNumeric, timeRange.duration > .zero else {
            throw OptimizationError.encodingFailed("Invalid source video duration")
        }

        let range = settings.range
        let hdr = range == .sdr ? nil : VideoProbe.HDRFormat(colors: [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
            AVVideoTransferFunctionKey: range == .hlg
                ? AVVideoTransferFunction_ITU_R_2100_HLG : AVVideoTransferFunction_SMPTE_ST_2084_PQ,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020,
        ], fullRange: false, staticMetadata: [:])
        let codec: AVVideoCodecType = switch settings.codec {
        case .h264: .h264
        case .hevc: .hevc
        }

        let size = CGSize(width: settings.width, height: settings.height)
        let format = OutputFormat(codec: codec, hdr: hdr, explicitSDR: true)
        let (sourceTransform, naturalSize) = try await source.track.load(.preferredTransform, .naturalSize)
        let uprightSize = CGRect(origin: .zero, size: naturalSize).applying(sourceTransform).size
        guard uprightSize.width.isFinite, uprightSize.height.isFinite, uprightSize.width > 0, uprightSize.height > 0 else {
            throw OptimizationError.missingResolution
        }
        let renderer = ConversionFrameRenderer.Configuration(
            range: range, sourceIsHDR: source.hdr != nil, assumeSDR: source.assumesSDR,
            framing: settings.framing, sourceTransform: sourceTransform, naturalSize: naturalSize,
        )
        try await encodeTier(
            asset: asset, videoTrack: source.track,
            sourceRange: CMTimeRange(start: timeRange.start, duration: min(timeRange.duration, duration)),
            settings: EncodingSettings(
                size: size, step: step, frameCount: count, bitrate: bitrate, sourceHDR: source.hdr,
                format: format, renderer: renderer, forPair: forPair, transform: .identity,
            ),
            outputURL: outputURL, progress: progress,
        )
        _ = try await validateTier(outputURL, size: size, format: format, duration: duration, step: step, frameCount: count)
        try Task.checkCancellation()
        await progress(1)
    }

    nonisolated static func loadSource(
        in asset: AVURLAsset, assumeSDR: Bool = false,
    ) async throws -> (track: AVAssetTrack, hdr: VideoProbe.HDRFormat?, assumesSDR: Bool) {
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else { throw OptimizationError.noVideoTrack }
        let formats = try await track.load(.formatDescriptions)
        guard tracks.count == 1, !formats.isEmpty, !formats.contains(where: isDolbyVision) else {
            throw OptimizationError.unsupportedDynamicRange
        }
        switch await VideoProbe.classify(track) {
        case false?:
            return (track, nil, false)
        case true?:
            guard let format = formats.first, let hdr = VideoProbe.hdrFormat(format),
                  formats.allSatisfy({ VideoProbe.hdrFormat($0) == hdr }) else {
                throw OptimizationError.unsupportedDynamicRange
            }
            return (track, hdr, false)
        case nil:
            let characteristics = try await track.load(.mediaCharacteristics)
            guard assumeSDR, !characteristics.contains(.containsHDRVideo),
                  formats.allSatisfy(isUnspecifiedSDR) else {
                throw OptimizationError.unsupportedDynamicRange
            }
            return (track, nil, true)
        }
    }

    private nonisolated static func sampleDescriptionAtoms(_ format: CMFormatDescription) -> [String: Any] {
        CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Any] ?? [:]
    }

    private nonisolated static func isDolbyVision(_ format: CMFormatDescription) -> Bool {
        let atoms = sampleDescriptionAtoms(format)
        let codec = format.mediaSubType.rawValue
        return [0x6476_6831, 0x6476_6865, 0x6476_6131, 0x6476_6176, 0x6461_7631].contains(codec) // dvh1, dvhe, dva1, dvav, dav1
            || ["dvcC", "dvvC", "dvwC"].contains { atoms[$0] != nil }
    }

    private nonisolated static func isUnspecifiedSDR(_ format: CMFormatDescription) -> Bool {
        let atoms = sampleDescriptionAtoms(format)
        return CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_TransferFunction) == nil
            && CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_MasteringDisplayColorVolume) == nil
            && CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_ContentLightLevelInfo) == nil
            && atoms["mdcv"] == nil && atoms["clli"] == nil
    }

    /// Returns validated, video-only tiers in a temporary directory owned by the caller.
    /// For a pair, encode both members with the same options and validate each matching tier together.
    @concurrent
    static func createVariants(
        sourceURL: URL,
        targetResolution: CGSize,
        outputDirectory: URL,
        forPair: Bool = false,
        convertToSDR: Bool = false,
        progress: @escaping @MainActor @Sendable (Double) -> Void,
    ) async throws -> [(url: URL, variant: VideoVariant)] {
        let asset = AVURLAsset(url: sourceURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let source = try await loadSource(in: asset)
        let videoTrack = source.track
        let hdr = source.hdr
        let sourceIsHDR = hdr != nil
        if let error = eligibilityError(sourceIsHDR: sourceIsHDR, resolution: targetResolution) {
            throw error
        }
        let toneMap = sourceIsHDR && convertToSDR
        let outputHDR = toneMap ? nil : hdr
        let format = OutputFormat(codec: outputHDR == nil ? .h264 : .hevc, hdr: outputHDR, explicitSDR: toneMap || forPair)
        let renderer = toneMap ? ConversionFrameRenderer.Configuration(range: .sdr, sourceIsHDR: true) : nil
        let transform = sourceIsHDR || forPair ? try await videoTrack.load(.preferredTransform) : .identity
        let sourceRate = try await videoTrack.load(.nominalFrameRate)
        let sourceSize = try await videoTrack.load(.naturalSize)
        let timeRange = try await videoTrack.load(.timeRange)
        let duration = timeRange.duration
        guard sourceRate.isFinite, sourceRate >= 0.5, Double(sourceRate) <= Double(Int32.max),
              timeRange.start.isNumeric, duration.isNumeric, duration > .zero else {
            throw OptimizationError.encodingFailed("Invalid source frame rate or duration")
        }
        if forPair {
            let full = try await CMTimeRange(start: .zero, duration: asset.load(.duration))
            guard timeRange == full else { throw PairIssue.tracks }
        }

        let size = try alignedSize(targetResolution, chromaAligned: sourceIsHDR || forPair)

        var tiers = computeFPSTiers(sourceRate: sourceRate)
        if !toneMap, size.width >= sourceSize.width - 1, size.height >= sourceSize.height - 1 {
            tiers.removeFirst()
        }

        var results: [(url: URL, variant: VideoVariant)] = []
        let tierCount = Double(tiers.count)
        for (index, tierFPS) in tiers.enumerated() {
            try Task.checkCancellation()

            let rate = tierFPS == Int(sourceRate.rounded()) ? Double(sourceRate) : Double(tierFPS)
            let (step, count) = try variantFrameClock(duration: duration, rate: rate, forPair: forPair)

            let filename = "variant_\(tierFPS)fps.mp4"
            let outputURL = outputDirectory.appendingPathComponent(filename)
            try await encodeTier(
                asset: asset, videoTrack: videoTrack, sourceRange: timeRange,
                settings: EncodingSettings(
                    size: size, step: step, frameCount: count,
                    bitrate: Int(min(Double(Int32.max), size.width * size.height * 2 * Double(tierFPS) / 30)),
                    sourceHDR: hdr, format: format, renderer: renderer, forPair: forPair, transform: transform,
                ),
                outputURL: outputURL,
            ) { fraction in
                progress((Double(index) + fraction) / tierCount)
            }

            let fps = try await validateTier(
                outputURL, size: size, format: format,
                duration: duration, step: step, frameCount: count,
            )
            results.append((outputURL, VideoVariant(
                filename: filename, fps: fps, resolution: size,
                isHDR: outputHDR != nil, toneMappedToSDR: toneMap ? true : nil,
            )))
        }

        await progress(1.0)
        return results
    }

    private nonisolated static func alignedSize(_ resolution: CGSize, chromaAligned: Bool) throws -> CGSize {
        // Keep the HDR and pair pipelines aligned to whole 4:2:0 chroma samples.
        let alignment: CGFloat = chromaAligned ? 2 : 1
        let size = CGSize(
            width: (resolution.width / alignment).rounded(.down) * alignment,
            height: (resolution.height / alignment).rounded(.down) * alignment,
        )
        guard size.width > 0, size.height > 0 else { throw OptimizationError.missingResolution }
        return size
    }

    private nonisolated static func variantFrameClock(duration: CMTime, rate: Double, forPair: Bool) throws -> (CMTime, Int32) {
        let frames = max(1, (duration.seconds * rate).rounded())
        guard frames <= Double(Int32.max) else { throw OptimizationError.encodingFailed("Too many output frames") }
        let count = Int32(frames)
        let step = CMTimeMultiplyByRatio(duration, multiplier: 1, divisor: count)
        guard step.isNumeric, step > .zero, CMTimeMultiply(step, multiplier: count) == duration else {
            throw OptimizationError.encodingFailed("Cannot represent a constant frame rate for this duration")
        }
        if forPair, step > CMTime(value: 1, timescale: 2) {
            throw PairIssue.sync
        }
        return (step, count)
    }

    private nonisolated static let rec709 = [
        AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
    ]

    private nonisolated struct OutputFormat: Sendable {
        let codec: AVVideoCodecType
        let hdr: VideoProbe.HDRFormat?
        let explicitSDR: Bool

        var profile: String {
            if hdr != nil {
                return kVTProfileLevel_HEVC_Main10_AutoLevel as String
            }
            return codec == .hevc ? kVTProfileLevel_HEVC_Main_AutoLevel as String : AVVideoProfileLevelH264HighAutoLevel
        }

        var colors: [String: String]? {
            hdr?.colors ?? (explicitSDR ? VideoOptimizationService.rec709 : nil)
        }

        func matches(_ format: CMFormatDescription) -> Bool {
            if let hdr {
                return VideoProbe.isHEVCMain10(format) && VideoProbe.hdrFormat(format) == hdr
            }
            if explicitSDR, VideoProbe.colorProperties(format) != VideoOptimizationService.rec709 {
                return false
            }
            if codec == .h264 {
                return format.mediaSubType.rawValue == kCMVideoCodecType_H264
                    && (!explicitSDR || VideoProbe.isH264High8(format))
            }
            guard format.mediaSubType.rawValue == kCMVideoCodecType_HEVC,
                  let config = VideoOptimizationService.sampleDescriptionAtoms(format)["hvcC"] as? Data,
                  config.count >= 23 else { return false }
            return config[1] & 0x1F == 1 && config[17] & 7 == 0 && config[18] & 7 == 0
        }
    }

    private nonisolated static func validateTier(
        _ url: URL, size: CGSize, format: OutputFormat,
        duration: CMTime, step: CMTime, frameCount: Int32,
    ) async throws -> Int {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard tracks.count == 1, let track = tracks.first,
              try await track.load(.naturalSize) == size,
              try await asset.load(.duration) == duration,
              try await track.load(.timeRange) == CMTimeRange(start: .zero, duration: duration),
              let cursor = track.makeSampleCursorAtFirstSampleInDecodeOrder(),
              cursor.stepInDecodeOrder(byCount: Int64(frameCount)) == Int64(frameCount) - 1 else {
            throw OptimizationError.encodingFailed("Output dimensions, duration, or frame count differ from the requested tier")
        }
        let rate = try await Double(track.load(.nominalFrameRate))
        guard rate.isFinite, abs(rate * step.seconds - 1) < 0.001 else {
            throw OptimizationError.encodingFailed("Output frame rate differs from the requested tier")
        }
        let formats = try await track.load(.formatDescriptions)
        guard !formats.isEmpty, formats.allSatisfy(format.matches) else {
            throw OptimizationError.encodingFailed("Output did not preserve the requested video format or metadata")
        }
        return max(1, Int(rate.rounded()))
    }

    private nonisolated struct EncodingSettings: Sendable {
        let size: CGSize
        let step: CMTime
        let frameCount: Int32
        let bitrate: Int
        let sourceHDR: VideoProbe.HDRFormat?
        let format: OutputFormat
        let renderer: ConversionFrameRenderer.Configuration?
        let forPair: Bool
        let transform: CGAffineTransform

        var syncInterval: Int32 {
            guard forPair else { return 0 }
            let halfSecond = CMTimeConvertScale(CMTime(value: 1, timescale: 2), timescale: step.timescale, method: .roundTowardZero)
            return Int32(clamping: max(1, halfSecond.value / step.value))
        }
    }

    private nonisolated static func makeReader(
        asset: AVURLAsset, track: AVAssetTrack, range: CMTimeRange, settings: EncodingSettings,
    ) throws -> (AVAssetReader, AVAssetReaderTrackOutput) {
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = range
        let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: settings.sourceHDR.map {
                $0.fullRange ? kCVPixelFormatType_420YpCbCr10BiPlanarFullRange : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            } ?? (settings.renderer == nil ? kCVPixelFormatType_32BGRA : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
        ])
        readerOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(readerOutput) else { throw OptimizationError.encodingFailed("Cannot decode source video") }
        reader.add(readerOutput)
        return (reader, readerOutput)
    }

    private nonisolated static func makeWriter(at outputURL: URL, settings: EncodingSettings) throws -> (AVAssetWriter, AVAssetWriterInput) {
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let format = settings.format
        let fps = 1 / settings.step.seconds
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: settings.bitrate,
            AVVideoProfileLevelKey: format.profile,
            AVVideoExpectedSourceFrameRateKey: fps,
        ]
        if let hdr = format.hdr {
            compression[kVTCompressionPropertyKey_HDRMetadataInsertionMode as String] = hdr.staticMetadata.isEmpty
                ? kVTHDRMetadataInsertionMode_None : kVTHDRMetadataInsertionMode_Auto
            for (key, value) in hdr.staticMetadata {
                compression[key] = value
            }
        }
        if settings.forPair {
            compression[AVVideoAllowFrameReorderingKey] = false
            compression[kVTCompressionPropertyKey_AllowOpenGOP as String] = false
            compression[AVVideoMaxKeyFrameIntervalKey] = Int(settings.syncInterval)
        } else if format.hdr != nil {
            compression[AVVideoMaxKeyFrameIntervalKey] = max(1, Int(fps.rounded()))
        }
        var outputSettings: [String: Any] = [
            AVVideoCodecKey: format.codec,
            AVVideoWidthKey: Int(settings.size.width),
            AVVideoHeightKey: Int(settings.size.height),
            AVVideoCompressionPropertiesKey: compression,
        ]
        outputSettings[AVVideoColorPropertiesKey] = format.colors
        guard writer.canApply(outputSettings: outputSettings, forMediaType: .video) else {
            throw OptimizationError.encodingFailed("Encoder does not support the requested video format")
        }
        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
        writerInput.expectsMediaDataInRealTime = false
        writerInput.mediaTimeScale = settings.step.timescale
        writer.movieTimeScale = settings.step.timescale
        writerInput.transform = settings.transform
        guard writer.canAdd(writerInput) else { throw OptimizationError.encodingFailed("Cannot write the requested video format") }
        writer.add(writerInput)
        return (writer, writerInput)
    }

    /// Confine the pull-based reader and writer to one background queue.
    private nonisolated static func encodeTier(
        asset: AVURLAsset, videoTrack: AVAssetTrack, sourceRange: CMTimeRange,
        settings: EncodingSettings, outputURL: URL,
        progress: @escaping @MainActor @Sendable (Double) -> Void,
    ) async throws {
        let (reader, readerOutput) = try makeReader(asset: asset, track: videoTrack, range: sourceRange, settings: settings)
        let (writer, writerInput) = try makeWriter(at: outputURL, settings: settings)

        nonisolated(unsafe) let r = reader
        nonisolated(unsafe) let ro = readerOutput
        nonisolated(unsafe) let w = writer
        nonisolated(unsafe) let wi = writerInput

        let cancelled = OSAllocatedUnfairLock(initialState: false)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                DispatchQueue(label: "com.phosphene.encoding", qos: .userInitiated).async {
                    do {
                        let mapper = try settings.renderer.map { try ConversionFrameRenderer(size: settings.size, configuration: $0) }
                        guard unsafe r.startReading() else {
                            throw OptimizationError.encodingFailed(unsafe r.error?.localizedDescription ?? "Failed to start reading")
                        }
                        guard unsafe w.startWriting() else {
                            throw OptimizationError.encodingFailed(unsafe w.error?.localizedDescription ?? "Failed to start writing")
                        }
                        unsafe w.startSession(atSourceTime: .zero)

                        let source = unsafe SourceFrames(reader: r, output: ro, start: sourceRange.start)
                        let pts = try unsafe appendFrames(
                            source: source, destination: (w, wi), settings: settings,
                            mapper: mapper, cancelled: cancelled, progress: progress,
                        )

                        if unsafe r.status == .reading {
                            unsafe r.cancelReading()
                        }
                        unsafe w.endSession(atSourceTime: pts)
                        unsafe wi.markAsFinished()
                        unsafe w.finishWriting {
                            if unsafe w.status == .completed {
                                continuation.resume()
                            } else {
                                continuation.resume(throwing: OptimizationError.encodingFailed(
                                    unsafe w.error?.localizedDescription ?? "Unknown write error",
                                ))
                            }
                        }
                    } catch {
                        if unsafe r.status == .reading {
                            unsafe r.cancelReading()
                        }
                        if unsafe w.status == .writing {
                            unsafe w.cancelWriting()
                        }
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            cancelled.withLock { $0 = true }
        }
        try Task.checkCancellation()
    }

    private nonisolated struct SourceFrames {
        let reader: AVAssetReader
        let output: AVAssetReaderTrackOutput
        let start: CMTime
        var previous: CMSampleBuffer?
        var upcoming: CMSampleBuffer?

        /// Sample the source clock as-is and hold the last frame after EOF.
        mutating func frame(at time: CMTime, cancelled: OSAllocatedUnfairLock<Bool>) throws -> CMSampleBuffer {
            let pts = start + time
            while true {
                if let sample = upcoming {
                    if sample.presentationTimeStamp > pts {
                        break
                    }
                    previous = sample
                    upcoming = nil
                }
                guard reader.status == .reading else { break }
                if cancelled.withLock({ $0 }) {
                    throw CancellationError()
                }
                guard let sample = output.copyNextSampleBuffer() else { break }
                guard sample.presentationTimeStamp.isNumeric else {
                    throw OptimizationError.encodingFailed("Invalid source frame timestamp")
                }
                upcoming = sample
            }
            guard reader.status != .failed, let frame = previous ?? upcoming else {
                throw OptimizationError.encodingFailed(reader.error?.localizedDescription ?? "Missing source video frame")
            }
            return frame
        }
    }

    private nonisolated static func appendFrames(
        source: SourceFrames, destination: (writer: AVAssetWriter, input: AVAssetWriterInput),
        settings: EncodingSettings, mapper: ConversionFrameRenderer?, cancelled: OSAllocatedUnfairLock<Bool>,
        progress: @escaping @MainActor @Sendable (Double) -> Void,
    ) throws -> CMTime {
        var source = source
        var index: Int32 = 0
        var pts = CMTime.zero
        let syncInterval = settings.syncInterval
        while index < settings.frameCount {
            if cancelled.withLock({ $0 }) {
                throw CancellationError()
            }
            guard destination.writer.status == .writing else {
                throw OptimizationError.encodingFailed(destination.writer.error?.localizedDescription ?? "Writer stopped")
            }
            guard destination.input.isReadyForMoreMediaData else {
                Thread.sleep(forTimeInterval: 0.001)
                continue
            }
            let frame = try source.frame(at: pts, cancelled: cancelled)
            let retimed = try retime(frame, at: pts, step: settings.step, mapper: mapper)
            if syncInterval > 0, index % syncInterval == 0 {
                CMSetAttachment(
                    retimed, key: kCMSampleBufferAttachmentKey_ForceKeyFrame,
                    value: kCFBooleanTrue, attachmentMode: kCMAttachmentMode_ShouldNotPropagate,
                )
            }
            guard destination.input.append(retimed) else {
                throw OptimizationError.encodingFailed(destination.writer.error?.localizedDescription ?? "Cannot append video frame")
            }
            index += 1
            pts = CMTimeMultiply(settings.step, multiplier: index)
            if index % 30 == 0 {
                let fraction = Double(index) / Double(settings.frameCount)
                Task { @MainActor in progress(fraction) }
            }
        }
        return pts
    }

    private nonisolated static func retime(
        _ frame: CMSampleBuffer, at pts: CMTime, step: CMTime, mapper: ConversionFrameRenderer?,
    ) throws -> CMSampleBuffer {
        var timing = CMSampleTimingInfo(duration: step, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        if let mapper {
            return try autoreleasepool { try mapper.render(frame, timing: &timing) }
        }
        var output: CMSampleBuffer?
        guard unsafe CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault, sampleBuffer: frame,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &output,
        ) == noErr, let output else {
            throw OptimizationError.encodingFailed("Cannot retime source video frame")
        }
        return output
    }
}
