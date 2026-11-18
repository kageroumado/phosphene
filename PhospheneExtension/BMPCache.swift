import AVFoundation
import Foundation
import ImageIO
import os

private let pendingFrames = OSAllocatedUnfairLock(initialState: [String: (source: FileIdentity, ticket: UUID)]())

func loadCachedSnapshotImage(forChoice choice: String?, source: URL?, width: Int, height: Int) -> CGImage? {
    guard let choice, let source, let identity = FileIdentity(of: source),
          let directory = SurfaceRegistry.shared.cacheDirectoryURL else { return nil }
    let scoped = directory.startAccessingSecurityScopedResource()
    defer {
        if scoped {
            directory.stopAccessingSecurityScopedResource()
        }
    }
    guard let url = CachedFrame.lookup(choice: choice, source: identity, width: width, height: height, directory: directory),
          let image = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(image, 0, nil)
}

func writeBMPSnapshot(videoURL: URL, videoID: String?, displayPixelWidth: Int, displayPixelHeight: Int) async {
    guard let videoID, let source = FileIdentity(of: videoURL),
          let cacheDir = SurfaceRegistry.shared.cacheDirectoryURL else { return }
    let scoped = cacheDir.startAccessingSecurityScopedResource()
    defer {
        if scoped {
            cacheDir.stopAccessingSecurityScopedResource()
        }
    }
    guard scoped else { return }

    let prefix = CachedFrame.prefix(videoID, displayPixelWidth, displayPixelHeight)
    let ticket = UUID()
    let needed = pendingFrames.withLock { pending in
        guard let currentID = ShuffleController.shared.resolveChoice(videoID),
              VideoLibrary.shared.videoURL(for: currentID) == videoURL, FileIdentity(of: videoURL) == source,
              pending[prefix]?.source != source,
              CachedFrame.lookup(choice: videoID, source: source, width: displayPixelWidth, height: displayPixelHeight, directory: cacheDir) == nil else { return false }
        pending[prefix] = (source, ticket)
        return true
    }
    guard needed else { return }
    defer { pendingFrames.withLock {
        if $0[prefix]?.ticket == ticket {
            $0[prefix] = nil
        }
    } }

    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: videoURL))
    generator.dynamicRangePolicy = .forceSDR
    generator.appliesPreferredTrackTransform = true
    guard let cgImage = try? await generator.image(at: .zero).image,
          let bmp = makeBMP(from: cgImage) else { return }

    let timestamp = String(format: "%016llx", Date.timeIntervalSinceReferenceDate.bitPattern)
    let filename = prefix + timestamp + ".bmp"
    let record = CachedFrame(choice: videoID, source: source, width: displayPixelWidth, height: displayPixelHeight, filename: filename)
    do {
        try pendingFrames.withLock { pending in
            guard pending[prefix]?.ticket == ticket, FileIdentity(of: videoURL) == source,
                  let currentID = ShuffleController.shared.resolveChoice(videoID),
                  VideoLibrary.shared.videoURL(for: currentID) == videoURL else { return }
            try FileManager.default.createDirectory(at: URL.cachesDirectory, withIntermediateDirectories: true)
            let url = cacheDir.appendingPathComponent(filename)
            try bmp.write(to: url, options: .atomic)
            do {
                try JSONEncoder().encode(record).write(to: CachedFrame.recordURL(prefix), options: .atomic)
            } catch {
                try? FileManager.default.removeItem(at: url)
                throw error
            }
            let files = try FileManager.default.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil)
            for old in files where old.lastPathComponent.hasPrefix(prefix) && old.pathExtension == "bmp" && old.lastPathComponent != filename {
                try? FileManager.default.removeItem(at: old)
            }
            try Data(#"{"version":2}"#.utf8).write(to: cacheDir.appendingPathComponent("cacheVersion.db"), options: .atomic)
        }
    } catch {
        traceLog("  [BMPCache] Publish failed: \(error)")
    }
}

private func makeBMP(from cgImage: CGImage) -> Data? {
    let width = cgImage.width
    let height = cgImage.height
    let bytesPerPixel = 3 // 24bpp BGR
    let paddedRowBytes = (width * bytesPerPixel + 3) & ~3
    let pixelDataSize = paddedRowBytes * height

    traceLog("  [BMPCache] Rendering \(width)x\(height) BGR24 (\(pixelDataSize) bytes, row=\(paddedRowBytes))")

    let bgraRowBytes = width * 4
    var bgraData = Data(count: bgraRowBytes * height)
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

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
        return nil
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

    return bmp
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
