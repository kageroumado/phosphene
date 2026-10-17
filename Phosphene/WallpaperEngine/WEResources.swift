import AVFoundation
import CoreVideo
import Foundation
import os

/// A texture the renderer can bind, with the size the shaders are told about.
final nonisolated class WEGLTexture {
    let name: UInt32
    /// `g_TextureNResolution`: padded width/height, then image width/height.
    let resolution: SIMD4<Float>
    let spriteFrames: [WETexture.SpriteFrame]
    /// ``WETexture/formatCode``; render targets are 0.
    let formatCode: Int
    /// Set for an MP4 texture; its frames are uploaded as the scene time advances.
    let video: WEVideoTexture?

    init(
        name: UInt32, resolution: SIMD4<Float>, spriteFrames: [WETexture.SpriteFrame] = [], formatCode: Int = 0,
        video: WEVideoTexture? = nil,
    ) {
        self.name = name
        self.resolution = resolution
        self.spriteFrames = spriteFrames
        self.formatCode = formatCode
        self.video = video
    }

    /// Fraction of the padded texture the image covers.
    var imageExtent: SIMD2<Float> {
        guard resolution.x > 0, resolution.y > 0 else { return SIMD2(1, 1) }
        return SIMD2(resolution.z / resolution.x, resolution.w / resolution.y)
    }
}

/// An offscreen color buffer: a texture with a framebuffer around it, at most
/// ``WELimit/dimension`` a side.
final nonisolated class WERenderTarget {
    let texture: UInt32
    let framebuffer: UInt32
    let width: Int
    let height: Int

    init(gl: GL, width: Int, height: Int) throws {
        self.width = min(WELimit.dimension, max(1, width))
        self.height = min(WELimit.dimension, max(1, height))
        texture = gl.genTexture()
        gl.bindTexture(texture)
        unsafe gl.texImage2D(
            level: 0, internalFormat: GLConst.rgba8, width: self.width, height: self.height,
            format: GLConst.rgba, type: GLConst.unsignedByte, data: nil,
        )
        gl.texParameter(GLConst.textureMinFilter, GLConst.linear)
        gl.texParameter(GLConst.textureMagFilter, GLConst.linear)
        gl.texParameter(GLConst.textureWrapS, GLConst.clampToEdge)
        gl.texParameter(GLConst.textureWrapT, GLConst.clampToEdge)
        framebuffer = gl.genFramebuffer()
        gl.bindFramebuffer(framebuffer)
        let status = gl.attachTexture(texture)
        guard status == GLConst.framebufferComplete else { throw GLError.framebuffer(status) }
    }

    var resolution: SIMD4<Float> {
        SIMD4(Float(width), Float(height), Float(width), Float(height))
    }

    var byteCount: Int {
        width * height * 4
    }

    func bind(_ gl: GL) {
        gl.bindFramebuffer(framebuffer)
        gl.viewport(0, 0, width, height)
    }

    func delete(_ gl: GL) {
        gl.deleteFramebuffer(framebuffer)
        gl.deleteTexture(texture)
    }
}

/// Loads `materials/<name>.tex` once per render session, within a memory budget.
final nonisolated class WETextureCache {
    /// Decoded bytes one scene may hold in textures.
    static let byteBudget = 2 << 30

    private let gl: GL
    private let files: WEFileSystem
    private let scratch: URL
    private var textures: [String: WEGLTexture] = [:]
    private var bytesLoaded = 0
    private lazy var black: WEGLTexture = solid([0, 0, 0, 255])

    init(gl: GL, files: WEFileSystem, scratch: URL) {
        self.gl = gl
        self.files = files
        self.scratch = scratch
    }

    /// The texture for a material texture name, or a 1×1 black stand-in when the
    /// file is missing (Wallpaper Engine draws a missing texture the same way).
    func texture(_ name: String) -> WEGLTexture {
        let path = WEFileSystem.normalize(name.hasSuffix(".tex") ? name : "materials/\(name).tex")
        if let cached = textures[path] {
            return cached
        }
        let texture: WEGLTexture
        do {
            texture = try load(path)
        } catch {
            weLog.warning("Texture \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            texture = black
        }
        textures[path] = texture
        return texture
    }

    var fallback: WEGLTexture {
        black
    }

    var videos: [WEVideoTexture] {
        textures.values.compactMap(\.video)
    }

    private func load(_ path: String) throws -> WEGLTexture {
        guard let data = files.read(path) else { throw WEError.missing(path) }
        let decoded = try WETexture(data: data)
        guard bytesLoaded + decoded.byteCount <= Self.byteBudget else {
            throw WEError.unsupported("more than \(Self.byteBudget >> 20) MB of textures")
        }
        bytesLoaded += decoded.byteCount
        // Everything that can fail comes before the GL name is taken.
        var video: WEVideoTexture?
        if case let .video(mp4) = decoded.pixels {
            let url = scratch.appendingPathComponent("\(UUID().uuidString).mp4")
            try mp4.write(to: url)
            video = try WEVideoTexture(url: url)
        }

        let handle = gl.genTexture()
        gl.bindTexture(handle)
        gl.pixelStore(GLConst.unpackAlignment, 1)
        var mipCount = 1
        switch decoded.pixels {
        case let .raw(layout, mips):
            let (internalFormat, format): (UInt32, UInt32) = switch layout {
            case .rgba8: (GLConst.rgba8, GLConst.rgba)
            case .rg8: (GLConst.rg8, GLConst.rg)
            case .r8: (GLConst.r8, GLConst.red)
            }
            for (level, mip) in mips.enumerated() {
                unsafe mip.data.withUnsafeBytes { bytes in
                    unsafe gl.texImage2D(
                        level: level, internalFormat: internalFormat, width: mip.width, height: mip.height,
                        format: format, type: GLConst.unsignedByte, data: bytes.baseAddress,
                    )
                }
            }
            mipCount = mips.count
        case let .compressed(glFormat, mips):
            for (level, mip) in mips.enumerated() {
                unsafe mip.data.withUnsafeBytes { bytes in
                    unsafe gl.compressedTexImage2D(
                        level: level, format: glFormat, width: mip.width, height: mip.height, data: bytes,
                    )
                }
            }
            mipCount = mips.count
        case .video:
            break
        }
        let filter = decoded.nearest ? GLConst.nearest : GLConst.linear
        gl.texParameter(GLConst.textureMinFilter, mipCount > 1 ? GLConst.linearMipmapLinear : filter)
        gl.texParameter(GLConst.textureMagFilter, filter)
        gl.texParameter(GLConst.textureMaxLevel, Int32(mipCount - 1))
        let wrap = decoded.clampUVs ? GLConst.clampToEdge : GLConst.repeatWrap
        gl.texParameter(GLConst.textureWrapS, wrap)
        gl.texParameter(GLConst.textureWrapT, wrap)
        let resolution = video.map { SIMD4(Float($0.width), Float($0.height), Float($0.width), Float($0.height)) }
            ?? decoded.resolution
        return WEGLTexture(
            name: handle, resolution: resolution, spriteFrames: decoded.spriteFrames, formatCode: decoded.formatCode,
            video: video,
        )
    }

    private func solid(_ rgba: [UInt8]) -> WEGLTexture {
        let handle = gl.genTexture()
        gl.bindTexture(handle)
        rgba.withUnsafeBytes { bytes in
            unsafe gl.texImage2D(
                level: 0, internalFormat: GLConst.rgba8, width: 1, height: 1, format: GLConst.rgba,
                type: GLConst.unsignedByte, data: bytes.baseAddress,
            )
        }
        gl.texParameter(GLConst.textureMinFilter, GLConst.nearest)
        gl.texParameter(GLConst.textureMagFilter, GLConst.nearest)
        return WEGLTexture(name: handle, resolution: SIMD4(1, 1, 1, 1))
    }

    /// Upload each video texture's frame for scene time `time`, read from `stream`.
    func advanceVideos(to time: Double, stream: Int = 0) {
        for texture in textures.values {
            guard let video = texture.video, let frame = video.frame(at: time, stream: stream) else { continue }
            gl.bindTexture(texture.name)
            CVPixelBufferLockBaseAddress(frame, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(frame, .readOnly) }
            let width = CVPixelBufferGetWidth(frame)
            let height = CVPixelBufferGetHeight(frame)
            gl.pixelStore(GLConst.unpackRowLength, CVPixelBufferGetBytesPerRow(frame) / 4)
            unsafe gl.texImage2D(
                level: 0, internalFormat: GLConst.rgba8, width: width, height: height, format: GLConst.bgra,
                type: GLConst.unsignedInt8888Rev, data: CVPixelBufferGetBaseAddress(frame),
            )
            gl.pixelStore(GLConst.unpackRowLength, 0)
        }
    }

    func deleteAll() {
        for texture in textures.values {
            gl.deleteTexture(texture.name)
            if let video = texture.video {
                try? FileManager.default.removeItem(at: video.url)
            }
        }
        textures.removeAll()
        bytesLoaded = 0
    }
}

/// Sequential frame access to an MP4 texture, looping over its duration.
///
/// Scene time only moves forward while a wallpaper renders, so frames are read in
/// order with one `AVAssetReader` per stream; a jump backwards restarts that stream.
/// A crossfade renders two times at once, so it reads from two streams.
final nonisolated class WEVideoTexture {
    let url: URL
    let duration: Double
    let width: Int
    let height: Int
    private let track: AVAssetTrack
    private let asset: AVURLAsset
    private var streams: [Int: Stream] = [:]

    private final class Stream {
        var reader: AVAssetReader?
        var output: AVAssetReaderTrackOutput?
        var current: (time: Double, buffer: CVPixelBuffer)?
        var pending: (time: Double, buffer: CVPixelBuffer)?
    }

    init(url: URL) throws {
        self.url = url
        let asset = AVURLAsset(url: url)
        let loaded = try blockingAwait {
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard let track = tracks.first else { throw WEError.malformed("video texture has no picture") }
            let size = try await track.load(.naturalSize)
            let duration = try await asset.load(.duration)
            return (track, size, duration.seconds)
        }
        self.asset = asset
        track = loaded.0
        width = Int(clamping: loaded.1.width, to: 1 ... WELimit.dimension)
        height = Int(clamping: loaded.1.height, to: 1 ... WELimit.dimension)
        // An indefinite duration reads as NaN; one frame's worth keeps the loop math finite.
        duration = loaded.2.isFinite && loaded.2 > 0 ? loaded.2 : 0.04
    }

    func frame(at time: Double, stream index: Int = 0) -> CVPixelBuffer? {
        let stream = streams[index] ?? Stream()
        streams[index] = stream
        let local = time.truncatingRemainder(dividingBy: duration)
        if let current = stream.current, local < current.time - 1e-3 {
            restart(stream)
        }
        if stream.reader == nil {
            restart(stream)
        }
        while true {
            if stream.pending == nil {
                stream.pending = next(stream)
            }
            guard let pending = stream.pending else { break }
            if pending.time <= local + 1e-4 || stream.current == nil {
                stream.current = pending
                stream.pending = nil
            } else {
                break
            }
        }
        return stream.current?.buffer
    }

    private func restart(_ stream: Stream) {
        stream.reader?.cancelReading()
        stream.current = nil
        stream.pending = nil
        guard let reader = try? AVAssetReader(asset: asset) else { return }
        let output = AVAssetReaderTrackOutput(
            track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA],
        )
        output.alwaysCopiesSampleData = false
        reader.add(output)
        reader.startReading()
        stream.reader = reader
        stream.output = output
    }

    private func next(_ stream: Stream) -> (Double, CVPixelBuffer)? {
        guard let sample = stream.output?.copyNextSampleBuffer(), let buffer = sample.imageBuffer else { return nil }
        return (sample.presentationTimeStamp.seconds, buffer)
    }
}

/// Run async work from a dedicated (non-cooperative) thread and wait for it.
nonisolated func blockingAwait<T>(_ operation: @escaping @Sendable () async throws -> T) throws -> T {
    let box = ResultBox<T>()
    let semaphore = DispatchSemaphore(value: 0)
    Task.detached {
        do {
            box.result = try await .success(operation())
        } catch {
            box.result = .failure(error)
        }
        semaphore.signal()
    }
    semaphore.wait()
    return try box.result!.get()
}

/// Hands a result from the detached task in ``blockingAwait(_:)`` to the waiting thread;
/// the semaphore orders the write before the read.
final nonisolated class ResultBox<T>: @unchecked Sendable {
    var result: Result<T, any Error>?
}
