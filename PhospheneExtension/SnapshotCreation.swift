import AVFoundation
import CoreMedia
@preconcurrency import IOSurface

/// Create a WallpaperSnapshotXPC containing an IOSurface with a video frame.
func createSnapshotViaRuntime(videoURL: URL) async -> AnyObject? {
    let asset = AVURLAsset(url: videoURL)
    let generator = AVAssetImageGenerator(asset: asset)
    generator.dynamicRangePolicy = .forceSDR
    generator.appliesPreferredTrackTransform = true

    let image: CGImage
    do {
        let result = try await generator.image(at: .zero)
        image = result.image
    } catch {
        extensionLog("  [Snapshot] Failed to get video frame: \(error)")
        return nil
    }

    guard let snapshotXPC = renderSnapshotToIOSurface(image: image) else {
        return nil
    }

    traceLog("  [Snapshot] Created WallpaperSnapshotXPC \(image.width)x\(image.height)")
    return snapshotXPC
}

/// Render a CGImage to an IOSurface and wrap it in a WallpaperSnapshotXPC.
/// Synchronous to avoid async Sendable constraints on IOSurface's `[Key: Any]` dictionary.
private func renderSnapshotToIOSurface(image: CGImage) -> AnyObject? {
    let width = image.width
    let height = image.height

    let surfaceProps: [IOSurfacePropertyKey: any Sendable] = [
        .width: width,
        .height: height,
        .bytesPerElement: 4,
        .pixelFormat: 0x4247_5241, // 'BGRA'
    ]
    guard let surface = IOSurface(properties: surfaceProps) else {
        extensionLog("  [Snapshot] Failed to create IOSurface")
        return nil
    }

    surface.lock(options: [], seed: nil)
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    if let profile = colorSpace.copyICCData() {
        IOSurfaceSetValue(surface, kIOSurfaceICCProfile, profile)
    }
    if let ctx = CGContext(
        data: surface.baseAddress,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: surface.bytesPerRow,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue,
    ) {
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    } else {
        extensionLog("  [Snapshot] Failed to create CGContext for IOSurface")
        surface.unlock(options: [], seed: nil)
        return nil
    }
    surface.unlock(options: [], seed: nil)

    return createSnapshotXPC(surface: surface)
}
