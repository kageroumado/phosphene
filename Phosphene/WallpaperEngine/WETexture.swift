import Compression
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A decoded Wallpaper Engine `.tex`, ready for upload.
///
/// Layout: `TEXV0005` and `TEXI0001` magics, then format, flags, texture and image
/// sizes (textures are often padded to a power of two; the image occupies the top-left
/// `imageWidth × imageHeight`), then a `TEXB000N` image block whose mips are raw
/// pixels, LZ4 blocks, a whole encoded image file, or an MP4. An optional `TEXS000N`
/// block lists sprite-sheet frames.
nonisolated struct WETexture {
    enum Pixels {
        /// Uncompressed mips in `layout`, mip 0 first.
        case raw(layout: Layout, mips: [Mip])
        /// S3TC blocks, uploaded as they are.
        case compressed(glFormat: UInt32, mips: [Mip])
        /// An MP4 the scene uses as an animated texture.
        case video(Data)
    }

    enum Layout {
        case rgba8
        case rg8
        case r8
    }

    struct Mip {
        let width: Int
        let height: Int
        let data: Data
    }

    struct SpriteFrame {
        let frameTime: Float
        let x: Float, y: Float
        let width: Float, widthY: Float, heightX: Float, height: Float
    }

    let textureWidth: Int
    let textureHeight: Int
    /// Wallpaper Engine's format code, which shaders switch on as `TEXnFORMAT`
    /// (0 RGBA8888, 4 DXT5, 6 DXT3, 7 DXT1, 8 RG88, 9 R8).
    let formatCode: Int
    let imageWidth: Int
    let imageHeight: Int
    let pixels: Pixels
    let clampUVs: Bool
    let nearest: Bool
    let spriteFrames: [SpriteFrame]

    /// Bytes the mips hold once decoded, for a cache budget.
    var byteCount: Int {
        switch pixels {
        case let .raw(_, mips), let .compressed(_, mips): mips.reduce(0) { $0 + $1.data.count }
        case let .video(data): data.count
        }
    }

    private enum Flag {
        static let noInterpolation: UInt32 = 1
        static let clampUVs: UInt32 = 2
        static let sprite: UInt32 = 4
    }

    /// Bounds on what a package may claim beyond ``WELimit``. The sizes in a header
    /// decide how many bytes OpenGL reads from a mip's buffer.
    private enum Limit {
        static let images = 64
        static let mips = 16
        static let frames = 4_096
        /// Bytes all of one texture's LZ4 blocks may expand to: a 16384² RGBA mip.
        static let decompressed = 16_384 * 16_384 * 4
    }

    // swiftlint:disable:next function_body_length cyclomatic_complexity
    init(data: Data) throws {
        var reader = ByteReader(data: data)
        guard try reader.magic().hasPrefix("TEXV"), try reader.magic().hasPrefix("TEXI") else {
            throw WEError.malformed("texture header")
        }
        let format = try Int(reader.int32())
        var formatCode = format
        let flags = try reader.uint32()
        var textureWidth = try Int(reader.int32())
        var textureHeight = try Int(reader.int32())
        imageWidth = try Int(reader.int32())
        imageHeight = try Int(reader.int32())
        _ = try reader.uint32()
        for size in [textureWidth, textureHeight, imageWidth, imageHeight] {
            try Self.checkDimension(size)
        }

        let containerMagic = try reader.magic()
        guard containerMagic.hasPrefix("TEXB") else { throw WEError.malformed("texture image block") }
        let containerVersion = Int(containerMagic.dropFirst(4)) ?? 1
        let imageCount = try Int(reader.int32())
        guard (1 ... Limit.images).contains(imageCount) else { throw WEError.malformed("texture image count") }
        var encodedFormat: Int32 = -1
        if containerVersion >= 3 {
            encodedFormat = try reader.int32()
        }
        if containerVersion >= 4 {
            _ = try reader.int32()
        }

        // Only image 0 is drawn; the others are read past. Every mip's claimed
        // expansion counts against one budget before any of it is allocated.
        var budget = Limit.decompressed
        var images: [[(width: Int, height: Int, data: Data)]] = []
        for imageIndex in 0 ..< imageCount {
            let mipCount = try Int(reader.int32())
            guard (1 ... Limit.mips).contains(mipCount) else { throw WEError.malformed("texture mip count") }
            var mips: [(width: Int, height: Int, data: Data)] = []
            for _ in 0 ..< mipCount {
                let width = try Int(reader.int32())
                let height = try Int(reader.int32())
                try Self.checkDimension(width)
                try Self.checkDimension(height)
                var lz4 = false
                var decompressedSize = 0
                if containerVersion >= 2 {
                    lz4 = try reader.int32() != 0
                    decompressedSize = try Int(reader.int32())
                }
                let byteCount = try Int(reader.int32())
                var bytes = try reader.bytes(byteCount)
                if lz4, imageIndex == 0 {
                    guard decompressedSize > 0, decompressedSize <= budget else {
                        throw WEError.malformed("texture compression size")
                    }
                    budget -= decompressedSize
                    bytes = try Self.decompressLZ4(bytes, size: decompressedSize)
                }
                mips.append((width, height, bytes))
            }
            images.append(mips)
        }
        guard let first = images.first, let mip0 = first.first else { throw WEError.malformed("texture has no image") }

        // What the texture is gets decided once, from image 0's first mip: an MP4, an
        // encoded image file, or raw pixels. Raw pixels must then fill every mip,
        // since OpenGL reads width × height worth of bytes from each; trailing bytes
        // are dropped because a compressed upload must state its exact size.
        let isVideo = Self.isMP4(mip0.data)
        var rawMips: [Mip] = []
        if !isVideo, encodedFormat < 0 {
            for mip in first {
                let expected = Self.expectedSize(format: format, width: mip.width, height: mip.height)
                guard mip.data.count >= expected else { throw WEError.malformed("texture mip smaller than its size") }
                rawMips.append(Mip(width: mip.width, height: mip.height, data: mip.data.prefix(expected)))
            }
        }

        var frames: [SpriteFrame] = []
        if flags & Flag.sprite != 0, reader.remaining > 8,
           case let magic = try reader.magic(), magic.hasPrefix("TEXS") {
            let version = Int(magic.dropFirst(4)) ?? 1
            let frameCount = try Int(reader.int32())
            guard (0 ... Limit.frames).contains(frameCount) else { throw WEError.malformed("sprite frame count") }
            if version >= 3 {
                _ = try reader.int32()
                _ = try reader.int32()
            }
            for _ in 0 ..< frameCount {
                _ = try reader.int32() // image index; frames on images past the first are not drawn
                let frameTime = try reader.float()
                let values: [Float] = try (0 ..< 6).map { _ in
                    version == 1 ? try Float(reader.int32()) : try reader.float()
                }
                guard frameTime.isFinite, values.allSatisfy(\.isFinite) else {
                    throw WEError.malformed("sprite frame")
                }
                frames.append(SpriteFrame(
                    frameTime: frameTime, x: values[0], y: values[1],
                    width: values[2], widthY: values[3], heightX: values[4], height: values[5],
                ))
            }
        }
        spriteFrames = frames
        clampUVs = flags & Flag.clampUVs != 0
        nearest = flags & Flag.noInterpolation != 0

        if isVideo {
            pixels = .video(mip0.data)
            formatCode = 0
        } else if encodedFormat >= 0 {
            // The encoded file is the image itself, never padded.
            let decoded = try Self.decodeImage(mip0.data)
            textureWidth = decoded.width
            textureHeight = decoded.height
            formatCode = 0
            pixels = .raw(layout: .rgba8, mips: [decoded])
        } else {
            switch format {
            case 4: pixels = .compressed(glFormat: GLConst.compressedDXT5, mips: rawMips)
            case 6: pixels = .compressed(glFormat: GLConst.compressedDXT3, mips: rawMips)
            case 7: pixels = .compressed(glFormat: GLConst.compressedDXT1, mips: rawMips)
            case 8: pixels = .raw(layout: .rg8, mips: rawMips)
            case 9: pixels = .raw(layout: .r8, mips: rawMips)
            default: pixels = .raw(layout: .rgba8, mips: rawMips)
            }
        }
        self.textureWidth = textureWidth
        self.textureHeight = textureHeight
        self.formatCode = formatCode
    }

    /// The layout of the `g_TextureNResolution` uniforms: padded size, then image size.
    var resolution: SIMD4<Float> {
        SIMD4(Float(textureWidth), Float(textureHeight), Float(imageWidth), Float(imageHeight))
    }

    private static func checkDimension(_ size: Int) throws {
        guard (1 ... WELimit.dimension).contains(size) else { throw WEError.malformed("texture size \(size)") }
    }

    /// Bytes a raw mip of `format` needs: 4×4 blocks of 8 (DXT1) or 16 (DXT3/5) bytes,
    /// else 1 (R8), 2 (RG88) or 4 bytes per pixel. Dimensions are already capped, so
    /// this cannot overflow.
    private static func expectedSize(format: Int, width: Int, height: Int) -> Int {
        let blocks = ((width + 3) / 4) * ((height + 3) / 4)
        switch format {
        case 7: return blocks * 8
        case 4, 6: return blocks * 16
        case 8: return width * height * 2
        case 9: return width * height
        default: return width * height * 4
        }
    }

    private static func isMP4(_ data: Data) -> Bool {
        data.count > 12 && data[data.startIndex + 4 ..< data.startIndex + 8] == Data("ftyp".utf8)
    }

    private static func decompressLZ4(_ data: Data, size: Int) throws -> Data {
        guard !data.isEmpty else { throw WEError.malformed("texture compression") }
        var output = Data(count: size)
        let written = unsafe output.withUnsafeMutableBytes { destination in
            unsafe data.withUnsafeBytes { source in
                unsafe compression_decode_buffer(
                    destination.bindMemory(to: UInt8.self).baseAddress!, size,
                    source.bindMemory(to: UInt8.self).baseAddress!, source.count,
                    nil, COMPRESSION_LZ4_RAW,
                )
            }
        }
        guard written == size else { throw WEError.malformed("texture compression") }
        return output
    }

    /// Decode an embedded PNG or JPEG into straight-alpha RGBA8, top row first.
    /// Wallpaper Engine embeds nothing else, so no other ImageIO codec gets to run.
    private static func decodeImage(_ data: Data) throws -> Mip {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source).map({ UTType($0 as String) }),
              type == .png || type == .jpeg,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let claimedWidth = properties[kCGImagePropertyPixelWidth] as? Int,
              let claimedHeight = properties[kCGImagePropertyPixelHeight] as? Int
        else { throw WEError.malformed("embedded image") }
        // Check the claimed size before decoding: a small PNG can expand to gigabytes.
        try checkDimension(claimedWidth)
        try checkDimension(claimedHeight)
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw WEError.malformed("embedded image")
        }
        try checkDimension(image.width)
        try checkDimension(image.height)
        let width = image.width
        let height = image.height
        var pixels = Data(count: width * height * 4)
        let drawn = unsafe pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = unsafe CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw WEError.malformed("embedded image") }
        // CoreGraphics only draws premultiplied; the shaders expect straight alpha.
        unsafe pixels.withUnsafeMutableBytes { buffer in
            let bytes = unsafe buffer.bindMemory(to: UInt8.self)
            var index = 0
            while index < bytes.count {
                let alpha = unsafe bytes[index + 3]
                if alpha != 0, alpha != 255 {
                    for channel in 0 ..< 3 {
                        let value = unsafe Int(bytes[index + channel]) * 255 / Int(alpha)
                        unsafe bytes[index + channel] = UInt8(min(255, value))
                    }
                }
                index += 4
            }
        }
        return Mip(width: width, height: height, data: pixels)
    }
}
