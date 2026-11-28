import Accelerate
import AVFoundation
import Foundation
import ImageIO
import os

private let pendingFrames = OSAllocatedUnfairLock(initialState: [String: (source: FileIdentity, ticket: UUID)]())

private struct SnapshotSource: Equatable {
    let url: URL
    let pairMember: String?

    init(_ url: URL, pair: PairRendition?) {
        self.url = url
        pairMember = pair.map { $0.originals.alternate == url ? $0.pair.counterpart : $0.pair.owner }
    }
}

func loadCachedSnapshotImage(
    forChoice choice: String?, source: FileIdentity?, videoURL: URL?, pair: PairRendition?, width: Int, height: Int,
) -> CGImage? {
    guard let choice, let source, let videoURL,
          let directory = SurfaceRegistry.shared.cacheDirectoryURL else { return nil }
    let scoped = directory.startAccessingSecurityScopedResource()
    defer {
        if scoped {
            directory.stopAccessingSecurityScopedResource()
        }
    }
    let member = SnapshotSource(videoURL, pair: pair).pairMember
    let legacy = member == nil ? VideoLibrary.shared.legacySnapshotOriginal(videoURL, for: choice) : nil
    guard let url = CachedFrame.lookup(
        choice: choice, source: source, width: width, height: height, directory: directory,
        pairMember: member, legacyOriginal: legacy,
    ) else { return nil }
    return decodeCachedSnapshot(url)
}

private func decodeCachedSnapshot(_ url: URL) -> CGImage? {
    guard let image = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(image, 0, nil)
}

func refreshBMPSnapshot(for key: SurfaceKey) {
    // An acquire or shuffle change posts its selection to the main queue first.
    DispatchQueue.main.async {
        Task { await writeBMPSnapshot(for: key) }
    }
}

@concurrent
private func writeBMPSnapshot(for key: SurfaceKey) async {
    guard let surface = SurfaceRegistry.shared.surface(for: key), let videoID = surface.videoID,
          let cacheDir = SurfaceRegistry.shared.cacheDirectoryURL else { return }
    let displayPixelWidth = Int(surface.destSize.width * surface.scaleFactor)
    let displayPixelHeight = Int(surface.destSize.height * surface.scaleFactor)
    guard let selection = selectedSnapshotSource(for: key, choice: videoID), let source = FileIdentity(of: selection.url) else { return }
    let (videoURL, member) = (selection.url, selection.pairMember)
    let scoped = cacheDir.startAccessingSecurityScopedResource()
    defer {
        if scoped {
            cacheDir.stopAccessingSecurityScopedResource()
        }
    }
    guard scoped else { return }

    let prefix = CachedFrame.prefix(videoID, displayPixelWidth, displayPixelHeight, pairMember: member)
    let ticket = UUID()
    let legacy = member == nil ? VideoLibrary.shared.legacySnapshotOriginal(videoURL, for: videoID) : nil
    let cache = SnapshotCacheWriter(choice: videoID, source: source, width: displayPixelWidth, height: displayPixelHeight, directory: cacheDir)

    do {
        let needed = try pendingFrames.withLock { pending in
            guard selectedSnapshotSource(for: key, choice: videoID) == selection, FileIdentity(of: videoURL) == source,
                  pending[prefix]?.source != source else { return false }
            if let cached = CachedFrame.lookup(
                choice: videoID, source: source, width: displayPixelWidth, height: displayPixelHeight, directory: cacheDir,
                pairMember: member, legacyOriginal: legacy,
            ), let image = CGImageSourceCreateWithURL(cached as CFURL, nil), CGImageSourceGetCount(image) > 0 {
                pending[prefix] = nil
                try cache.refreshAgentFallback(from: cached, for: key, selection: selection)
                return false
            }
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

        try pendingFrames.withLock { pending in
            // Another surface can still need this member after the initiating surface switches.
            guard pending[prefix]?.ticket == ticket, FileIdentity(of: videoURL) == source,
                  member != nil || selectedSnapshotSource(for: key, choice: videoID) == selection else { return }
            let cached = try cache.publish(prefix) { url in
                try bmp.write(to: url, options: .atomic)
            }
            try cache.refreshAgentFallback(from: cached, for: key, selection: selection)
        }
    } catch {
        traceLog("  [BMPCache] Publish failed: \(error)")
    }
}

private struct SnapshotCacheWriter {
    let choice: String
    let source: FileIdentity
    let width: Int
    let height: Int
    let directory: URL

    func publish(_ prefix: String, writeBMP: (URL) throws -> Void) throws -> URL {
        let timestamp = String(format: "%016llx", Date.timeIntervalSinceReferenceDate.bitPattern)
        let filename = prefix + timestamp + ".bmp"
        let url = directory.appendingPathComponent(filename)
        let record = CachedFrame(choice: choice, source: source, width: width, height: height, filename: filename)
        try FileManager.default.createDirectory(at: URL.cachesDirectory, withIntermediateDirectories: true)
        // Publish the identity first so an interrupted write cannot leave an untracked BMP.
        try JSONEncoder().encode(record).write(to: CachedFrame.recordURL(prefix), options: .atomic)
        try writeBMP(url)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        for old in files where old.lastPathComponent.hasPrefix(prefix) && old.pathExtension == "bmp" && old.lastPathComponent != filename {
            try? FileManager.default.removeItem(at: old)
        }
        try Data(#"{"version":2}"#.utf8).write(to: directory.appendingPathComponent("cacheVersion.db"), options: .atomic)
        return url
    }

    func refreshAgentFallback(from cached: URL, for key: SurfaceKey, selection: SnapshotSource) throws {
        guard selection.pairMember != nil,
              CachedFrame.lookup(choice: choice, source: source, width: width, height: height, directory: directory) == nil,
              selectedSnapshotSource(for: key, choice: choice) == selection, FileIdentity(of: selection.url) == source else { return }

        // Link the complete BMP into the Agent's slot without rewriting the pixels.
        _ = try publish(CachedFrame.prefix(choice, width, height)) { destination in
            do {
                try FileManager.default.linkItem(at: cached, to: destination)
            } catch {
                try Data(contentsOf: cached, options: .mappedIfSafe).write(to: destination, options: .atomic)
            }
        }
    }
}

private func selectedSnapshotSource(for key: SurfaceKey, choice videoID: String) -> SnapshotSource? {
    let state = PlaybackStore.snapshot
    guard let surface = state.surfaces[key], surface.choice == videoID,
          let id = PlaybackReducer.resolve(videoID, in: state) else { return nil }
    let library = VideoLibrary.shared
    let pair = library.pairRendition(for: id)
    let dark = surface.appearance.usesDark(systemDark: state.systemDark)
    let url = pair?.url(dark: dark) ?? library.videoURL(for: id)
    return url.map { SnapshotSource($0, pair: pair) }
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

    // Build BMP: 14-byte file header + 40-byte BITMAPINFOHEADER + pixel data
    let fileHeaderSize = 14
    let dibHeaderSize = 40
    let headerSize = fileHeaderSize + dibHeaderSize
    let fileSize = headerSize + pixelDataSize

    var bmp = Data(count: fileSize)

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

    let result = bgraData.withUnsafeMutableBytes { (bgra: UnsafeMutableRawBufferPointer) in
        bmp.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
            var source = vImage_Buffer(data: bgra.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: bgraRowBytes)
            var destination = vImage_Buffer(data: bytes.baseAddress!.advanced(by: headerSize), height: source.height, width: source.width, rowBytes: paddedRowBytes)
            // Dropping the fourth channel also maps BGRA to BGR without reordering colors.
            return vImageConvert_RGBA8888toRGB888(&source, &destination, vImage_Flags(kvImageNoFlags))
        }
    }
    return result == kvImageNoError ? bmp : nil
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
