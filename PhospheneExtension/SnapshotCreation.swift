import AVFoundation
import CoreMedia
@preconcurrency import IOSurface

/// Create a WallpaperSnapshotXPC containing an IOSurface with a video frame.
///
/// - Parameter currentTime: If provided, captures the frame at this time (e.g. from an
///   active renderer's timebase). Falls back to a random time within the video duration,
///   avoiding always returning frame 0.
func createSnapshotViaRuntime(currentTime: CMTime? = nil) async -> AnyObject? {
    guard let videoURL = findVideoURL() else {
        extensionLog("  [Snapshot] No video file found")
        return nil
    }

    let asset = AVURLAsset(url: videoURL)
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true

    let requestTime: CMTime
    if let currentTime, currentTime.isValid, currentTime.seconds > 0 {
        requestTime = currentTime
    } else {
        do {
            let duration = try await asset.load(.duration)
            if duration.isValid, duration.seconds > 0 {
                let randomOffset = Double.random(in: 0 ..< duration.seconds)
                requestTime = CMTime(seconds: randomOffset, preferredTimescale: duration.timescale)
            } else {
                requestTime = .zero
            }
        } catch {
            requestTime = .zero
        }
    }

    let image: CGImage
    do {
        let result = try await generator.image(at: requestTime)
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
    let colorSpace = CGColorSpaceCreateDeviceRGB()
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
