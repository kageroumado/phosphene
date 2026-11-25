import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo

/// Renders canonical, color-managed pixels before handing a timed sample to the encoder.
final nonisolated class ConversionFrameRenderer {
    struct Configuration: Sendable {
        let range: ConversionRange
        let sourceIsHDR: Bool
        var assumeSDR = false
        var framing: ConversionFraming?
        var sourceTransform: CGAffineTransform = .identity
        var naturalSize: CGSize?
    }

    private let configuration: Configuration
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let pool: CVPixelBufferPool
    private let outputSpace: CGColorSpace
    private let outputIsHDR: Bool
    private let outputTransfer: CFString
    private let bounds: CGRect
    private var lastSource: CMSampleBuffer?
    private var lastImage: CVPixelBuffer?
    private var lastFormat: CMVideoFormatDescription?

    init(size: CGSize, configuration: Configuration) throws {
        self.configuration = configuration
        bounds = CGRect(origin: .zero, size: size)
        let colorName: CFString
        switch configuration.range {
        case .sdr:
            colorName = CGColorSpace.itur_709
            outputTransfer = kCVImageBufferTransferFunction_ITU_R_709_2
            outputIsHDR = false
        case .hlg:
            colorName = CGColorSpace.itur_2100_HLG
            outputTransfer = kCVImageBufferTransferFunction_ITU_R_2100_HLG
            outputIsHDR = true
        case .pq:
            colorName = CGColorSpace.itur_2100_PQ
            outputTransfer = kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
            outputIsHDR = true
        }
        var pool: CVPixelBufferPool?
        let attributes = [
            kCVPixelBufferPixelFormatTypeKey: outputIsHDR
                ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: Int(size.width),
            kCVPixelBufferHeightKey: Int(size.height),
            kCVPixelBufferIOSurfacePropertiesKey: [:],
        ] as CFDictionary
        guard unsafe CVPixelBufferPoolCreate(nil, nil, attributes, &pool) == kCVReturnSuccess,
              let pool, let outputSpace = CGColorSpace(name: colorName) else {
            throw VideoOptimizationService.OptimizationError.encodingFailed("Cannot prepare color conversion")
        }
        self.pool = pool
        self.outputSpace = outputSpace
    }

    func render(_ sample: CMSampleBuffer, timing: inout CMSampleTimingInfo) throws -> CMSampleBuffer {
        if lastSource !== sample {
            let image = try renderImage(sample)
            var format: CMVideoFormatDescription?
            guard unsafe CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: nil, imageBuffer: image, formatDescriptionOut: &format,
            ) == noErr, let format else {
                throw VideoOptimizationService.OptimizationError.encodingFailed("Cannot describe the converted frame")
            }
            lastSource = sample
            lastImage = image
            lastFormat = format
        }
        var output: CMSampleBuffer?
        guard let lastImage, let lastFormat, unsafe CMSampleBufferCreateReadyWithImageBuffer(
            allocator: nil, imageBuffer: lastImage, formatDescription: lastFormat, sampleTiming: &timing, sampleBufferOut: &output,
        ) == noErr, let output else {
            throw VideoOptimizationService.OptimizationError.encodingFailed("Cannot create a converted video sample")
        }
        return output
    }

    private func renderImage(_ sample: CMSampleBuffer) throws -> CVPixelBuffer {
        guard let source = sample.imageBuffer else {
            throw VideoOptimizationService.OptimizationError.encodingFailed("Missing decoded source frame")
        }
        let decodedSpace = unsafe CVImageBufferGetColorSpace(source)?.takeUnretainedValue()
        let sourceSpace: CGColorSpace?
        if configuration.assumeSDR, decodedSpace?.isHDR() != true {
            CVBufferSetAttachment(source, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
            sourceSpace = CGColorSpace(name: CGColorSpace.itur_709)
        } else {
            sourceSpace = decodedSpace
        }
        guard let sourceSpace, sourceSpace.isHDR() == configuration.sourceIsHDR else {
            throw VideoOptimizationService.OptimizationError.encodingFailed("Decoded frame has an unsupported color space")
        }

        let image = CIImage(cvPixelBuffer: source, options: [
            .colorSpace: sourceSpace,
            .toneMapHDRtoSDR: configuration.sourceIsHDR && !outputIsHDR,
            .applyCleanAperture: configuration.framing != nil,
        ])
        var buffer: CVPixelBuffer?
        guard unsafe CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else {
            throw VideoOptimizationService.OptimizationError.encodingFailed("Cannot allocate a converted frame")
        }
        let primaries = outputIsHDR ? kCVImageBufferColorPrimaries_ITU_R_2020 : kCVImageBufferColorPrimaries_ITU_R_709_2
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, primaries, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, outputTransfer, .shouldPropagate)
        if outputIsHDR {
            CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
        }
        context.render(framed(image), to: buffer, bounds: bounds, colorSpace: outputSpace)
        return buffer
    }

    private func framed(_ image: CIImage) -> CIImage {
        let extent = image.extent
        guard let framing = configuration.framing else {
            return image.transformed(by: CGAffineTransform(scaleX: bounds.width / extent.width, y: bounds.height / extent.height))
        }
        let normalized = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        let natural = configuration.naturalSize ?? extent.size
        let sized = normalized.transformed(by: CGAffineTransform(scaleX: natural.width / extent.width, y: natural.height / extent.height))
        // Track transforms use top-left coordinates. Core Image uses bottom-left coordinates.
        let flip = CGAffineTransform(scaleX: 1, y: -1)
        let upright = sized.transformed(by: flip.concatenating(configuration.sourceTransform).concatenating(flip))
        let x = bounds.width / upright.extent.width
        let y = bounds.height / upright.extent.height
        let scale: CGFloat = switch framing {
        case .fit: min(x, y)
        case .fill: max(x, y)
        }
        let scaled = upright.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let centered = scaled.transformed(by: CGAffineTransform(
            translationX: bounds.midX - scaled.extent.midX,
            y: bounds.midY - scaled.extent.midY,
        ))
        return centered.composited(over: CIImage(color: .black).cropped(to: bounds)).cropped(to: bounds)
    }
}
