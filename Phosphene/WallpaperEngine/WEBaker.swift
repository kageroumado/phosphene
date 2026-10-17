import AVFoundation
import CoreVideo
import Foundation
import VideoToolbox

/// How a scene becomes a video file.
nonisolated struct WEBakeSettings: Codable, Equatable {
    enum Codec: String, Codable, CaseIterable {
        case hevc
        case h264
    }

    var width: Int
    var height: Int
    var fps: Int
    var codec: Codec
    /// `nil` finds the length automatically, up to ``maxAutomaticLength``.
    var loopLength: Double?

    static let maxAutomaticLength = 30.0
    static let minAutomaticLength = 6.0
    /// The crossfade that closes a loop the scene itself does not close.
    static let crossfade = 1.0

    static let standard = WEBakeSettings(width: 3_840, height: 2_160, fps: 30, codec: .hevc, loopLength: nil)

    /// These settings with each value inside what the encoder accepts, for values
    /// read back from a defaults file.
    var normalized: WEBakeSettings {
        var settings = self
        settings.width = min(max(width, 16), 8_192)
        settings.height = min(max(height, 16), 8_192)
        settings.fps = min(max(fps, 1), 120)
        settings.loopLength = loopLength.flatMap { $0.isFinite ? min(max($0, 1), 600) : nil }
        return settings
    }
}

nonisolated struct WEBakeResult: Codable {
    let url: URL
    let duration: Double
    /// The loop closes on its own; otherwise its last second crossfades into its first.
    let seamless: Bool
    /// What the video leaves out (sound, clock text, effects that did not compile).
    let omissions: [String]
}

/// Renders a Wallpaper Engine scene into a looping video, on the calling thread.
///
/// 1. A low-resolution probe finds the loop length whose end best matches its start.
/// 2. Full-size frames are rendered and encoded. A loop that does not close on its
///    own starts one crossfade-length in and ends by fading into its own opening,
///    so playback wraps without a cut; every frame is still rendered in time order,
///    which particle simulations need.
nonisolated enum WEBaker {
    typealias Progress = @Sendable (_ fraction: Double, _ phase: String) -> Void

    // swiftlint:disable:next function_body_length
    static func bake(
        folder: URL, assets: URL?, settings: WEBakeSettings, output: URL, progress: Progress,
        isCancelled: @Sendable () -> Bool,
    ) throws -> WEBakeResult {
        guard let gl = GL.shared else { throw GLError.unavailable }
        let context = try GL.Context(gl: gl)
        context.makeCurrent()
        // Nothing below names the context again, so the optimizer may otherwise
        // release it, and its deinit destroys the context, before the first frame.
        defer { withExtendedLifetime(context) {} }

        let project = WEProject(folder: folder)
        let files = try WEFileSystem(folder: folder, assets: assets)
        let scene = try WEScene(files: files, sceneFile: project.file, properties: project.propertyValues)
        if let blocker = scene.blockers.first {
            throw WEError.unsupported(blocker)
        }
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("phosphene-we-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        // 1. Loop length.
        progress(0, String(localized: "Finding a loop"))
        let frameDuration = 1.0 / Double(settings.fps)
        let loop: (length: Double, seamless: Bool)
        if let fixed = settings.loopLength {
            loop = (fixed, false)
        } else {
            let probe = try WERenderer(
                gl: gl, files: files, scene: scene, width: 192,
                height: max(2, 192 * settings.height / max(settings.width, 1)), scratch: scratch,
            )
            defer { probe.release() }
            loop = try WELoopFinder.find(renderer: probe, progress: { progress($0 * 0.15, String(localized: "Finding a loop")) }, isCancelled: isCancelled)
        }
        try checkCancelled(isCancelled)

        // 2. Frames.
        let renderer = try WERenderer(
            gl: gl, files: files, scene: scene, width: settings.width, height: settings.height, scratch: scratch,
        )
        defer { renderer.release() }
        renderer.frameDuration = frameDuration
        let frameCount = max(1, Int((loop.length / frameDuration).rounded()))
        let fadeFrames = loop.seamless ? 0 : min(frameCount / 2, Int((WEBakeSettings.crossfade / frameDuration).rounded()))
        // Both simulations start at 0 with the same seed, so the secondary at time t
        // is the state the main one passed through at t: the fade lands exactly on
        // the frame the video opens with.
        renderer.resetSimulation(to: 0)
        renderer.resetSecondarySimulation(to: 0)

        let encoder = try WEVideoEncoder(url: output, settings: settings)
        do {
            for index in 0 ..< frameCount {
                try checkCancelled(isCancelled)
                let frame = index + fadeFrames
                if frame < frameCount {
                    try renderer.render(time: Double(frame) * frameDuration)
                } else {
                    // The wrap: the loop's continuation fading into its own opening.
                    let early = frame - frameCount
                    try renderer.renderCrossfade(
                        late: Double(frame) * frameDuration, early: Double(early) * frameDuration,
                        weight: Float(early + 1) / Float(max(fadeFrames, 1)),
                    )
                }
                try encoder.append(renderer, frame: index)
                progress(0.15 + 0.85 * Double(index + 1) / Double(frameCount), String(localized: "Rendering"))
            }
            try encoder.finish()
        } catch {
            encoder.cancel()
            throw error
        }
        return WEBakeResult(
            url: output, duration: Double(frameCount) * frameDuration, seamless: loop.seamless,
            omissions: renderer.omissions,
        )
    }

    private static func checkCancelled(_ isCancelled: () -> Bool) throws {
        if isCancelled() {
            throw CancellationError()
        }
    }
}

/// `project.json`: the wallpaper's title, type, entry file and user properties.
/// The paths it names are kept only when they stay inside the wallpaper's folder.
nonisolated struct WEProject {
    /// Largest `project.json` worth reading; real ones are a few kilobytes.
    static let maxSize = 1 << 20

    let title: String
    let type: String
    /// The entry file as the project names it, relative to the folder.
    let file: String
    /// The entry file's location, when it lies inside the folder.
    let mainFile: URL?
    /// The preview picture, when it exists inside the folder.
    let preview: URL?
    let contentRating: String?
    /// Property name → its current value (`"1 0 0"` for a color, a number, a bool).
    let propertyValues: [String: Any]

    init(folder: URL) {
        let json = Self.read(folder.appendingPathComponent("project.json"))
        title = ((json["title"] as? String) ?? folder.lastPathComponent).trimmingCharacters(in: .whitespacesAndNewlines)
        type = ((json["type"] as? String) ?? "").lowercased()
        file = (json["file"] as? String) ?? "scene.json"
        mainFile = Self.contained(file, in: folder)
        preview = (json["preview"] as? String).flatMap { Self.contained($0, in: folder) }
            .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        contentRating = json["contentrating"] as? String
        var values: [String: Any] = [:]
        let properties = (json["general"] as? [String: Any])?["properties"] as? [String: Any] ?? [:]
        for (name, property) in properties {
            if let value = (property as? [String: Any])?["value"] {
                values[name] = value
            }
        }
        propertyValues = values
    }

    private static func read(_ url: URL) -> [String: Any] {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= maxSize,
              let data = try? Data(contentsOf: url)
        else { return [:] }
        return WEJSON.object(from: data) ?? [:]
    }

    /// `folder/path`, unless the path leads out of the folder.
    private static func contained(_ path: String, in folder: URL) -> URL? {
        let url = folder.appendingPathComponent(WEFileSystem.normalize(path))
        return PathSafety.contained(url, in: folder) ? url : nil
    }
}

/// Finds the loop length at which a scene comes back to how it started.
///
/// Renders small frames over ``WEBakeSettings/maxAutomaticLength`` and scores each
/// candidate length by how much the frames after it differ from the opening frames.
/// Wave effects are periodic, so some length usually matches closely; video textures
/// match at multiples of their own length; particle systems never repeat exactly and
/// get the crossfade.
nonisolated enum WELoopFinder {
    private static let probeRate = 10.0
    private static let window = 5
    /// Mean luma difference (0…1) below which the cut is invisible.
    private static let seamlessThreshold: Float = 0.004
    private static let staticThreshold: Float = 0.0015

    static func find(
        renderer: WERenderer, progress: (Double) -> Void, isCancelled: () -> Bool,
    ) throws -> (length: Double, seamless: Bool) {
        let step = 1 / probeRate
        renderer.frameDuration = step
        renderer.resetSimulation(to: 0)
        let total = Int(WEBakeSettings.maxAutomaticLength * probeRate) + window
        var frames: [[Float]] = []
        frames.reserveCapacity(total)
        for index in 0 ..< total {
            if isCancelled() {
                throw CancellationError()
            }
            try renderer.render(time: Double(index) * step)
            frames.append(luma(renderer.readBGRA()))
            progress(Double(index + 1) / Double(total))
        }

        // A still scene loops at any length: keep it short.
        let motion = frames.dropFirst().map { difference($0, frames[0]) }.max() ?? 0
        if motion < staticThreshold {
            return (WEBakeSettings.minAutomaticLength, true)
        }

        let minimum = Int(WEBakeSettings.minAutomaticLength * probeRate)
        var best = (length: total - window, error: Float.infinity)
        for length in minimum ... (total - window) {
            var error: Float = 0
            for offset in 0 ..< window {
                error += difference(frames[offset], frames[length + offset])
            }
            error /= Float(window)
            // Prefer the shorter of two near-equal matches: smaller file, same look.
            if error < best.error * 0.97 {
                best = (length, error)
            }
        }
        let seamless = best.error < seamlessThreshold && !renderer.hasParticles
        return (Double(best.length) * step, seamless)
    }

    private static func luma(_ bgra: [UInt8]) -> [Float] {
        stride(from: 0, to: bgra.count, by: 4).map { index in
            (0.114 * Float(bgra[index]) + 0.587 * Float(bgra[index + 1]) + 0.299 * Float(bgra[index + 2])) / 255
        }
    }

    private static func difference(_ a: [Float], _ b: [Float]) -> Float {
        var sum: Float = 0
        for index in a.indices {
            sum += abs(a[index] - b[index])
        }
        return sum / Float(max(a.count, 1))
    }
}

/// Writes rendered frames to an HEVC or H.264 movie with VideoToolbox.
final nonisolated class WEVideoEncoder {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let fps: Int32

    init(url: URL, settings: WEBakeSettings) throws {
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        // Constant quality rather than a bitrate: still scenes come out small, and the
        // loop's last predicted frame stays close to its opening keyframe, so the wrap
        // is no more visible than any keyframe boundary.
        let compression: [String: Any] = [
            AVVideoQualityKey: 0.8,
            AVVideoExpectedSourceFrameRateKey: settings.fps,
            AVVideoMaxKeyFrameIntervalKey: settings.fps * 2,
            AVVideoProfileLevelKey: settings.codec == .hevc
                ? kVTProfileLevel_HEVC_Main_AutoLevel as String : AVVideoProfileLevelH264HighAutoLevel,
        ]
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: settings.codec == .hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: settings.width,
            AVVideoHeightKey: settings.height,
            AVVideoCompressionPropertiesKey: compression,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ])
        input.expectsMediaDataInRealTime = false
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: settings.width,
            kCVPixelBufferHeightKey as String: settings.height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ])
        writer.add(input)
        fps = Int32(settings.fps)
        guard writer.startWriting() else {
            throw writer.error ?? WEError.malformed("the video file could not be created")
        }
        writer.startSession(atSourceTime: .zero)
    }

    func append(_ renderer: WERenderer, frame: Int) throws {
        while !input.isReadyForMoreMediaData {
            if writer.status == .failed {
                throw writer.error ?? WEError.malformed("video encoding")
            }
            usleep(2_000)
        }
        guard let pool = adaptor.pixelBufferPool else { throw WEError.malformed("video encoding") }
        var buffer: CVPixelBuffer?
        unsafe CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let buffer else { throw WEError.malformed("video encoding") }
        renderer.read(into: buffer)
        guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps)) else {
            throw writer.error ?? WEError.malformed("video encoding")
        }
    }

    func finish() throws {
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        if writer.status != .completed {
            throw writer.error ?? WEError.malformed("video encoding")
        }
    }

    func cancel() {
        writer.cancelWriting()
    }
}
