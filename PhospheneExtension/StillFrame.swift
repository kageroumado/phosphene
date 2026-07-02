import CoreMedia
import CoreVideo
import Foundation

/// Wrap `image` in an IOSurface-backed `CMSampleBuffer` at PTS zero, sized to the
/// image. Returns nil if any Core Video/Media step fails.
func makeStillSampleBuffer(from image: CGImage) -> CMSampleBuffer? {
    let width = image.width
    let height = image.height
    guard width > 0, height > 0 else { return nil }

    let pixelBufferAttributes: [CFString: Any] = [
        kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        kCVPixelBufferCGImageCompatibilityKey: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey: true,
    ]

    var pixelBufferOut: CVPixelBuffer?
    guard CVPixelBufferCreate(
        kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
        pixelBufferAttributes as CFDictionary, &pixelBufferOut,
    ) == kCVReturnSuccess, let pixelBuffer = pixelBufferOut else { return nil }

    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

    guard let context = CGContext(
        data: CVPixelBufferGetBaseAddress(pixelBuffer),
        width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue,
    ) else { return nil }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

    var formatDescription: CMVideoFormatDescription?
    guard CMVideoFormatDescriptionCreateForImageBuffer(
        allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
        formatDescriptionOut: &formatDescription,
    ) == noErr, let format = formatDescription else { return nil }

    var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
    var sampleBuffer: CMSampleBuffer?
    guard CMSampleBufferCreateReadyWithImageBuffer(
        allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
        formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sampleBuffer,
    ) == noErr else { return nil }

    return sampleBuffer
}
