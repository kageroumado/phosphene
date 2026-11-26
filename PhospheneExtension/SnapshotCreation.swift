import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreMedia
import CoreVideo
@preconcurrency import IOSurface

struct SnapshotVideoFile: Sendable, Equatable {
    let url: URL
    let identity: FileIdentity?

    var existsUnchanged: Bool {
        identity != nil && identity == FileIdentity(of: url)
    }
}

struct SnapshotMatchedFrame: Sendable {
    let start: CMTime
    let end: CMTime
    let loopStart: CMTime
    let playback: PairRendition.Playback
    let from: URL
    let to: URL
    let fraction: Float

    func covers(_ time: CMTime) -> Bool {
        start <= time && time < end
    }

    var localPTS: CMTime {
        let v = playback.validation
        let ticks = CMTimeConvertScale(start - loopStart, timescale: v.timescale, method: .roundTowardZero).value
        return CMTime(value: ticks % (Int64(v.frameCount) * v.frameTicks), timescale: v.timescale)
    }

    func decode() async -> CVPixelBuffer? {
        guard let stream = await MatchedFrameStream.prepare(
            playback: playback, from: from, to: to, at: start, origin: loopStart,
        ) else { return nil }
        defer { stream.cancel() }
        guard case let .sample(sample) = stream.next(at: start, fraction: fraction, finishing: nil),
              playback.filesMatch else { return nil }
        return sample.imageBuffer
    }
}

struct WallpaperSnapshotSelection: Sendable {
    enum Frame: Sendable {
        case displayed(SendableBox<CVPixelBuffer>)
        case matched(SnapshotMatchedFrame)
        case file
    }

    let frame: Frame
    let file: SnapshotVideoFile?
    let localTime: CMTime
    let preserveHDR: Bool
}

private let snapshotContext = CIContext(options: [.cacheIntermediates: false])

func createSnapshotViaRuntime(_ selection: WallpaperSnapshotSelection, requestedAt: CMTime) async -> (payload: AnyObject, route: String, format: OSType)? {
    let route: String
    let pixels: CVPixelBuffer?
    switch selection.frame {
    case let .displayed(buffer):
        pixels = buffer.value
        route = "displayed"
    case let .matched(frame):
        pixels = await frame.decode()
        route = "matched"
    case .file:
        pixels = nil
        route = "file"
    }
    if let pixels {
        let image = CIImage(cvPixelBuffer: pixels, options: [.applyCleanAperture: true])
        if let surface = renderWallpaperSnapshot(image, preserveHDR: selection.preserveHDR),
           let reply = createSnapshotXPC(surface: surface) {
            return (reply, route, surface.pixelFormat)
        }
    }
    guard let file = selection.file, file.existsUnchanged,
          let image = await snapshotFileFrame(file, at: selection.localTime, preserveHDR: selection.preserveHDR, requestedAt: requestedAt),
          let surface = renderWallpaperSnapshot(CIImage(cgImage: image), preserveHDR: selection.preserveHDR),
          let reply = createSnapshotXPC(surface: surface) else { return nil }
    return (reply, route == "file" ? "file" : "\(route)-fallback", surface.pixelFormat)
}

func snapshotFileFrame(_ file: SnapshotVideoFile, at time: CMTime, preserveHDR: Bool, requestedAt: CMTime) async -> CGImage? {
    guard time.isNumeric, time >= .zero, file.existsUnchanged else { return nil }
    let asset = AVURLAsset(url: file.url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
    let generator = AVAssetImageGenerator(asset: asset)
    generator.dynamicRangePolicy = preserveHDR ? .matchSource : .forceSDR
    generator.appliesPreferredTrackTransform = true
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero

    do {
        let result = try await generator.image(at: time)
        guard file.existsUnchanged else { return nil }
        traceLog("[Snapshot host=\(requestedAt.seconds)] file=\(file.url.lastPathComponent) local=\(time.seconds) frame=\(result.actualTime.seconds)")
        return result.image
    } catch {
        traceLog("[Snapshot host=\(requestedAt.seconds)] decode failed file=\(file.url.lastPathComponent) local=\(time.seconds) code=\((error as NSError).code)")
        return nil
    }
}

func renderWallpaperSnapshot(_ image: CIImage, preserveHDR: Bool) -> IOSurface? {
    let hdr = image.colorSpace?.isHDR() == true || image.contentHeadroom > 1
    if preserveHDR, hdr, let surface = renderSnapshotSurface(image, hdr: true) {
        return surface
    }

    let sdr: CIImage
    if hdr {
        let toneMap = CIFilter.toneMapHeadroom()
        toneMap.inputImage = image
        toneMap.targetHeadroom = 1
        guard let mapped = toneMap.outputImage else { return nil }
        sdr = mapped
    } else {
        sdr = image
    }
    return renderSnapshotSurface(sdr, hdr: false)
}

private func renderSnapshotSurface(_ image: CIImage, hdr: Bool) -> IOSurface? {
    let bounds = image.extent.integral
    guard !bounds.isInfinite, !bounds.isEmpty,
          let width = Int(exactly: bounds.width), let height = Int(exactly: bounds.height),
          let space = CGColorSpace(name: hdr ? CGColorSpace.extendedLinearITUR_2020 : CGColorSpace.sRGB),
          let spacePropertyList = space.copyPropertyList() else { return nil }

    let props: [IOSurfacePropertyKey: any Sendable] = [
        .width: width,
        .height: height,
        .bytesPerElement: hdr ? 8 : 4,
        .pixelFormat: hdr ? kCVPixelFormatType_64RGBAHalf : kCVPixelFormatType_32BGRA,
    ]
    guard let surface = IOSurface(properties: props) else { return nil }

    let destination = CIRenderDestination(ioSurface: surface)
    destination.colorSpace = space
    destination.isFlipped = true
    do {
        let render = try snapshotContext.startTask(toRender: image, from: bounds, to: destination, at: .zero)
        _ = try render.waitUntilCompleted()
    } catch {
        traceLog("[Snapshot] IOSurface render failed hdr=\(hdr): \(error)")
        return nil
    }
    IOSurfaceSetValue(surface, kIOSurfaceColorSpace, spacePropertyList)
    if let profile = space.copyICCData() {
        IOSurfaceSetValue(surface, kIOSurfaceICCProfile, profile)
    }
    if hdr, image.contentHeadroom.isFinite, image.contentHeadroom > 1 {
        IOSurfaceSetValue(surface, kIOSurfaceContentHeadroom, NSNumber(value: image.contentHeadroom))
    }
    return surface
}
