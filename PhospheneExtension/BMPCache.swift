import AVFoundation
import CryptoKit
import Foundation
import ImageIO

/// Load the most recent cached BMP from the Agent's cache directory as a CGImage.
/// Used to set rootLayer.contents as immediate visual content during transitions,
/// matching Apple's "Using existing snapshot as initial wallpaper contents" pattern.
///
/// - Parameter videoID: per-context choice identifier. Each display's acquire
///   passes its own choice so the right cached frame is shown during transitions.
///   Reading the process-wide "current" selection here would race across displays.
func loadCachedSnapshotImage(forChoice videoID: String?) -> CGImage? {
    guard let cacheDir = WallpaperState.shared.cacheDirectoryURL else { return nil }

    let gained = cacheDir.startAccessingSecurityScopedResource()
    defer { if gained { cacheDir.stopAccessingSecurityScopedResource() } }

    guard let contents = try? FileManager.default.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil) else {
        return nil
    }

    let bmpFiles = contents.filter { $0.pathExtension == "bmp" }

    let bmpURL: URL?
    if let videoID {
        let hash = videoHash(for: videoID)
        bmpURL = bmpFiles.first { $0.lastPathComponent.hasPrefix(hash) } ?? bmpFiles.first
    } else {
        bmpURL = bmpFiles.first
    }

    guard let url = bmpURL else { return nil }

    guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
          let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
        traceLog("  [InitContent] Failed to decode cached BMP: \(url.lastPathComponent)")
        return nil
    }

    traceLog("  [InitContent] Loaded cached snapshot: \(url.lastPathComponent) (\(cgImage.width)x\(cgImage.height))")
    return cgImage
}

/// Write a BMP snapshot of the video's first frame to the Agent's cache directory.
/// Each video gets its own BMP file (keyed by video ID hash) so the Agent shows
/// the correct cached frame during transitions between videos.
func writeBMPSnapshot(videoURL: URL, videoID: String? = nil, displayPixelWidth: Int, displayPixelHeight: Int) async {
    guard let cacheDir = WallpaperState.shared.cacheDirectoryURL else {
        traceLog("  [BMPCache] No cacheDirectoryURL, skipping")
        return
    }

    let gained = cacheDir.startAccessingSecurityScopedResource()
    defer { if gained { cacheDir.stopAccessingSecurityScopedResource() } }

    guard gained else {
        traceLog("  [BMPCache] Failed to acquire security-scoped access")
        return
    }

    let hashHex = videoHash(for: videoID ?? videoURL.lastPathComponent)

    // Check if existing BMP for this video already matches requested dimensions
    if let existing = try? FileManager.default.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil) {
        for bmp in existing where bmp.pathExtension == "bmp" && bmp.lastPathComponent.hasPrefix(hashHex) {
            let components = bmp.deletingPathExtension().lastPathComponent.components(separatedBy: "-")
            // Filename format: <64-char-hash>-<width>-<height>-0-<timestamp>
            if components.count == 5,
               let existingW = Int(components[1]),
               let existingH = Int(components[2]),
               existingW == displayPixelWidth,
               existingH == displayPixelHeight {
                traceLog("  [BMPCache] Existing BMP matches \(displayPixelWidth)x\(displayPixelHeight) for \(videoID ?? "?"), skipping")
                return
            }
        }
    }

    let asset = AVURLAsset(url: videoURL)
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true

    let cgImage: CGImage
    do {
        cgImage = try await generator.image(at: .zero).image
    } catch {
        traceLog("  [BMPCache] Failed to get video frame: \(error)")
        return
    }

    let width = cgImage.width
    let height = cgImage.height
    let bytesPerPixel = 3 // 24bpp BGR
    let rawRowBytes = width * bytesPerPixel
    let paddedRowBytes = (rawRowBytes + 3) & ~3
    let pixelDataSize = paddedRowBytes * height

    traceLog("  [BMPCache] Rendering \(width)x\(height) BGR24 (\(pixelDataSize) bytes, row=\(paddedRowBytes))")

    let bgraRowBytes = width * 4
    var bgraData = Data(count: bgraRowBytes * height)
    let colorSpace = CGColorSpaceCreateDeviceRGB()

    let rendered = bgraData.withUnsafeMutableBytes { rawBuf -> Bool in
        guard let ctx = CGContext(
            data: rawBuf.baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bgraRowBytes,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue,
        ) else { return false }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }

    guard rendered else {
        traceLog("  [BMPCache] CGContext render failed")
        return
    }

    // Convert BGRA → BGR24 with row padding
    var pixelData = Data(count: pixelDataSize)
    bgraData.withUnsafeBytes { bgra in
        pixelData.withUnsafeMutableBytes { bgr in
            let src = bgra.baseAddress!.assumingMemoryBound(to: UInt8.self)
            let dst = bgr.baseAddress!.assumingMemoryBound(to: UInt8.self)
            for y in 0 ..< height {
                for x in 0 ..< width {
                    let si = y * bgraRowBytes + x * 4
                    let di = y * paddedRowBytes + x * 3
                    dst[di] = src[si] // B
                    dst[di + 1] = src[si + 1] // G
                    dst[di + 2] = src[si + 2] // R
                }
            }
        }
    }

    // Build BMP: 14-byte file header + 40-byte BITMAPINFOHEADER + pixel data
    let fileHeaderSize = 14
    let dibHeaderSize = 40
    let headerSize = fileHeaderSize + dibHeaderSize
    let fileSize = headerSize + pixelDataSize

    var bmp = Data(count: headerSize)

    bmp[0] = 0x42; bmp[1] = 0x4D // "BM"
    bmpWriteLE32(&bmp, offset: 2, value: UInt32(fileSize))
    bmpWriteLE32(&bmp, offset: 10, value: UInt32(headerSize))

    let d = fileHeaderSize
    bmpWriteLE32(&bmp, offset: d, value: UInt32(dibHeaderSize))
    bmpWriteLE32(&bmp, offset: d + 4, value: UInt32(bitPattern: Int32(width)))
    bmpWriteLE32(&bmp, offset: d + 8, value: UInt32(bitPattern: Int32(-height))) // top-down
    bmpWriteLE16(&bmp, offset: d + 12, value: 1) // planes
    bmpWriteLE16(&bmp, offset: d + 14, value: 24) // bits per pixel
    bmpWriteLE32(&bmp, offset: d + 16, value: 0) // BI_RGB
    bmpWriteLE32(&bmp, offset: d + 20, value: UInt32(pixelDataSize))

    bmp.append(pixelData)

    let timestamp = Date().timeIntervalSinceReferenceDate
    let timestampHex = String(format: "%016llx", timestamp.bitPattern)
    let filename = "\(hashHex)-\(displayPixelWidth)-\(displayPixelHeight)-0-\(timestampHex).bmp"

    // Remove old BMP files for this video from cache
    if let contents = try? FileManager.default.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil) {
        for file in contents where file.pathExtension == "bmp" && file.lastPathComponent.hasPrefix(hashHex) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    let bmpURL = cacheDir.appendingPathComponent(filename)
    do {
        try bmp.write(to: bmpURL, options: .atomic)
        traceLog("  [BMPCache] Wrote \(bmp.count) bytes → \(filename)")
    } catch {
        traceLog("  [BMPCache] Write failed: \(error)")
    }

    // Write cacheVersion.db
    let versionURL = cacheDir.appendingPathComponent("cacheVersion.db")
    do {
        try Data("{\"version\":2}".utf8).write(to: versionURL, options: .atomic)
    } catch {
        traceLog("  [BMPCache] cacheVersion.db failed: \(error)")
    }
}

/// Generate a consistent hash prefix for a video identifier.
private func videoHash(for identifier: String) -> String {
    let hash = SHA256.hash(data: Data(identifier.utf8))
    return hash.map { String(format: "%02x", $0) }.joined()
}

private func bmpWriteLE32(_ data: inout Data, offset: Int, value: UInt32) {
    data[offset] = UInt8(value & 0xFF)
    data[offset + 1] = UInt8((value >> 8) & 0xFF)
    data[offset + 2] = UInt8((value >> 16) & 0xFF)
    data[offset + 3] = UInt8((value >> 24) & 0xFF)
}

private func bmpWriteLE16(_ data: inout Data, offset: Int, value: UInt16) {
    data[offset] = UInt8(value & 0xFF)
    data[offset + 1] = UInt8((value >> 8) & 0xFF)
}
