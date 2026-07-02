import AVFoundation
import CoreMedia

/// Video variant descriptor matching the extension's VideoVariant type.
struct VideoVariant: Codable {
    let filename: String
    let fps: Int
    let resolution: CGSize
}

enum OptimizationPreset: String, CaseIterable, Identifiable {
    case batterySaver = "Battery Saver"
    case balanced = "Balanced"
    case quality = "Quality"

    var id: String {
        rawValue
    }

    /// Short description shown in the inspector below the preset picker.
    var description: String {
        switch self {
        case .batterySaver:
            "Downscales to 1080p with reduced frame rate tiers. Best for laptops on battery."
        case .balanced:
            "Keeps original resolution, creates lower frame rate tiers for power-saving modes."
        case .quality:
            "Keeps original resolution, creates lower frame rate tiers for power-saving modes."
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
    enum OptimizationError: LocalizedError {
        case noVideoTrack
        case encodingFailed(String)

        var errorDescription: String? {
            switch self {
            case .noVideoTrack:
                "Source video contains no video track"
            case let .encodingFailed(reason):
                "Video encoding failed: \(reason)"
            }
        }
    }

    /// Computes FPS tiers by repeatedly halving the source rate, stopping before 8 fps.
    static func computeFPSTiers(sourceRate: Float) -> [Int] {
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

    /// Creates FPS-tiered variants of a source video using native AVFoundation encoding.
    ///
    /// Skips the full-FPS tier when the target resolution matches the source (no point
    /// re-encoding at the same framerate and resolution — the original file already serves).
    static func createVariants(
        sourceURL: URL,
        targetResolution: CGSize,
        progress: @escaping @MainActor @Sendable (Double) -> Void,
    ) async throws -> [(url: URL, variant: VideoVariant)] {
        let asset = AVURLAsset(url: sourceURL)

        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw OptimizationError.noVideoTrack
        }

        let sourceRate = try await videoTrack.load(.nominalFrameRate)
        let sourceSize = try await videoTrack.load(.naturalSize)
        let duration = try await asset.load(.duration)
        let totalSeconds = CMTimeGetSeconds(duration)

        var tiers = computeFPSTiers(sourceRate: sourceRate)

        // Skip the full-FPS tier if we're not downscaling — the original file is identical.
        let isDownscaling = targetResolution.width < sourceSize.width - 1
            || targetResolution.height < sourceSize.height - 1
        if !isDownscaling, let first = tiers.first, first == Int(sourceRate.rounded()) {
            tiers.removeFirst()
        }

        guard !tiers.isEmpty else {
            await MainActor.run { progress(1.0) }
            return []
        }

        var results: [(url: URL, variant: VideoVariant)] = []

        for (tierIndex, tierFPS) in tiers.enumerated() {
            try Task.checkCancellation()

            let tierProgress = Double(tierIndex) / Double(tiers.count)
            let tierWeight = 1.0 / Double(tiers.count)

            let filename = "variant_\(tierFPS)fps.mp4"
            let outputURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(filename)

            // Remove any existing file at the output path.
            try? FileManager.default.removeItem(at: outputURL)

            try await encodeTier(
                asset: asset,
                videoTrack: videoTrack,
                tierFPS: tierFPS,
                sourceRate: sourceRate,
                targetResolution: targetResolution,
                totalSeconds: totalSeconds,
                outputURL: outputURL,
                tierProgress: tierProgress,
                tierWeight: tierWeight,
                progress: progress,
            )

            let variant = VideoVariant(
                filename: filename,
                fps: tierFPS,
                resolution: targetResolution,
            )
            results.append((url: outputURL, variant: variant))
        }

        await MainActor.run { progress(1.0) }
        return results
    }

    // MARK: - Private

    private nonisolated static func computeBitrate(resolution: CGSize, fps: Int) -> Int {
        let pixels = Int(resolution.width) * Int(resolution.height)
        let baseBitrate = Double(pixels) * 2.0 // ~2 bits per pixel — H.264 High Profile
        let fpsScale = Double(fps) / 30.0
        return Int(baseBitrate * fpsScale)
    }

    /// Encode a single FPS tier using synchronous pull-based reading on a background queue.
    /// This avoids `requestMediaDataWhenReady` Sendability issues with non-Sendable AVFoundation types.
    private nonisolated static func encodeTier(
        asset: AVURLAsset,
        videoTrack: AVAssetTrack,
        tierFPS: Int,
        sourceRate _: Float,
        targetResolution: CGSize,
        totalSeconds: Double,
        outputURL: URL,
        tierProgress: Double,
        tierWeight: Double,
        progress: @escaping @MainActor @Sendable (Double) -> Void,
    ) async throws {
        // All AVFoundation work happens on a single dedicated queue.
        // We use nonisolated(unsafe) + withCheckedThrowingContinuation to bridge.
        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            ],
        )
        reader.add(readerOutput)

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let bitrate = computeBitrate(resolution: targetResolution, fps: tierFPS)
        let writerInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(targetResolution.width),
                AVVideoHeightKey: Int(targetResolution.height),
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: bitrate,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                    AVVideoExpectedSourceFrameRateKey: tierFPS,
                ],
            ],
        )
        writerInput.expectsMediaDataInRealTime = false
        writer.add(writerInput)

        guard reader.startReading() else {
            throw OptimizationError.encodingFailed(
                reader.error?.localizedDescription ?? "Failed to start reading",
            )
        }
        guard writer.startWriting() else {
            throw OptimizationError.encodingFailed(
                writer.error?.localizedDescription ?? "Failed to start writing",
            )
        }
        writer.startSession(atSourceTime: .zero)

        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(tierFPS))

        // AVAssetReader/Writer are not Sendable but are confined to a single dispatch queue.
        nonisolated(unsafe) let r = reader
        nonisolated(unsafe) let ro = readerOutput
        nonisolated(unsafe) let w = writer
        nonisolated(unsafe) let wi = writerInput

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            DispatchQueue(label: "com.phosphene.encoding", qos: .userInitiated).async {
                var nextKeepTime = CMTime.zero
                var frameCount = 0

                while unsafe r.status == .reading {
                    if Task.isCancelled {
                        unsafe r.cancelReading()
                        unsafe w.cancelWriting()
                        continuation.resume(throwing: CancellationError())
                        return
                    }

                    while unsafe !wi.isReadyForMoreMediaData {
                        Thread.sleep(forTimeInterval: 0.001)
                    }

                    guard let sampleBuffer = unsafe ro.copyNextSampleBuffer() else {
                        break
                    }

                    let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

                    guard pts >= nextKeepTime else { continue }
                    nextKeepTime = pts + frameDuration

                    unsafe wi.append(sampleBuffer)

                    frameCount += 1
                    if frameCount % 30 == 0 {
                        let currentSeconds = CMTimeGetSeconds(pts)
                        let localProgress = totalSeconds > 0 ? currentSeconds / totalSeconds : 0
                        let overallProgress = tierProgress + localProgress * tierWeight
                        let clamped = min(max(overallProgress, 0), 1)
                        Task { @MainActor in
                            progress(clamped)
                        }
                    }
                }

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
            }
        }

        if reader.status == .failed {
            throw OptimizationError.encodingFailed(
                reader.error?.localizedDescription ?? "Reader failed",
            )
        }
    }
}
