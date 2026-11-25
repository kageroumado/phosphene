import CoreMedia
import CoreVideo
import Foundation
import IOSurface
import Metal

/// Blends decoded Y′CbCr frames in their encoded transfer function. Use one instance per transition on a serial worker queue.
final nonisolated class MatchedFrameBlender {
    private typealias Layout = (width: Int, height: Int, format: OSType)
    private typealias GPU = (queue: any MTLCommandQueue, pipeline: any MTLComputePipelineState)

    private let gpu: GPU
    private let allocationLimit = [kCVPixelBufferPoolAllocationThresholdKey: 8] as CFDictionary
    private let displayKeys: [CFString]
    private var outputPool: (layout: Layout, buffers: CVPixelBufferPool)?

    /// Whether the most recent blend hit the pool's allocation threshold.
    private(set) var poolIsBusy = false

    init?() {
        guard let gpu = Self.sharedGPU,
              let commonKeys = CMVideoFormatDescriptionGetExtensionKeysCommonWithImageBuffers() as? [CFString] else { return nil }
        self.gpu = gpu
        displayKeys = commonKeys + [kCVImageBufferCGColorSpaceKey, kCVImageBufferAmbientViewingEnvironmentKey]
    }

    private static let sharedGPU: GPU? = {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: MatchedFrameBlender.shader, options: nil),
              let function = library.makeFunction(name: "blendPlane"),
              let pipeline = try? device.makeComputePipelineState(function: function) else { return nil }
        return (queue, pipeline)
    }()

    /// Requires equal local PTS, positive duration and matching display metadata. Returns a GPU-complete sample at `at`.
    func blend(first: CMSampleBuffer, second: CMSampleBuffer, fraction: Float, at: CMTime) -> CMSampleBuffer? {
        poolIsBusy = false
        let pts = first.presentationTimeStamp
        let duration = first.duration
        guard (0 ... 1).contains(fraction), at.isNumeric, pts.isNumeric, pts == second.presentationTimeStamp,
              duration.isNumeric, duration > .zero, duration == second.duration,
              first.numSamples == 1, second.numSamples == 1,
              CMSampleBufferDataIsReady(first), CMSampleBufferDataIsReady(second),
              let a = first.imageBuffer, let b = second.imageBuffer,
              CVPixelBufferGetPlaneCount(a) == 2, CVPixelBufferGetPlaneCount(b) == 2,
              unsafe CVPixelBufferGetIOSurface(a) != nil, unsafe CVPixelBufferGetIOSurface(b) != nil else { return nil }

        let layout: Layout = (CVPixelBufferGetWidth(a), CVPixelBufferGetHeight(a), CVPixelBufferGetPixelFormatType(a))
        guard layout == (CVPixelBufferGetWidth(b), CVPixelBufferGetHeight(b), CVPixelBufferGetPixelFormatType(b)) else { return nil }
        let isTenBit: Bool
        switch layout.format {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
             kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_422YpCbCr8BiPlanarFullRange,
             kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_444YpCbCr8BiPlanarFullRange:
            isTenBit = false
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
             kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_422YpCbCr10BiPlanarFullRange,
             kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_444YpCbCr10BiPlanarFullRange:
            isTenBit = true
        default:
            return nil
        }

        guard let output = makeOutput(for: layout),
              let sample = makeSample(output, matching: first, and: second, at: at),
              let command = gpu.queue.makeCommandBuffer(),
              let targets = encodeBlend(command, first: a, second: b, output: output, fraction: fraction, isTenBit: isTenBit) else { return nil }
        #if arch(x86_64)
            guard let blit = command.makeBlitCommandEncoder() else { return nil }
            for target in targets {
                blit.synchronize(resource: target)
            }
            blit.endEncoding()
        #endif
        command.commit()
        // Keep the decoder's buffers checked out while the GPU is reading their surfaces.
        withExtendedLifetime((a, b)) { command.waitUntilCompleted() }
        return command.status == .completed ? sample : nil
    }

    private func encodeBlend(
        _ command: any MTLCommandBuffer, first: CVPixelBuffer, second: CVPixelBuffer, output: CVPixelBuffer,
        fraction: Float, isTenBit: Bool,
    ) -> [any MTLTexture]? {
        guard let encoder = command.makeComputeCommandEncoder() else { return nil }
        defer { encoder.endEncoding() }
        let pipeline = gpu.pipeline
        encoder.setComputePipelineState(pipeline)

        // Recover code values from UNORM and round before putting 10-bit values back in the high bits.
        var parameters = SIMD2<Float>(fraction, isTenBit ? 65_535.0 / 64.0 : 255.0)
        unsafe encoder.setBytes(&parameters, length: MemoryLayout.size(ofValue: parameters), index: 0)
        let formats: [MTLPixelFormat] = isTenBit ? [.r16Unorm, .rg16Unorm] : [.r8Unorm, .rg8Unorm]
        let threads = MTLSize(width: pipeline.threadExecutionWidth, height: 4, depth: 1)
        var targets: [any MTLTexture] = []
        for (plane, format) in formats.enumerated() {
            guard let sourceA = texture(first, plane: plane, format: format, usage: .shaderRead),
                  let sourceB = texture(second, plane: plane, format: format, usage: .shaderRead),
                  let target = texture(output, plane: plane, format: format, usage: .shaderWrite),
                  sourceA.width == target.width, sourceA.height == target.height,
                  sourceB.width == target.width, sourceB.height == target.height else { return nil }
            encoder.setTexture(sourceA, index: 0)
            encoder.setTexture(sourceB, index: 1)
            encoder.setTexture(target, index: 2)
            let groups = MTLSize(
                width: (target.width + threads.width - 1) / threads.width,
                height: (target.height + threads.height - 1) / threads.height, depth: 1,
            )
            encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: threads)
            targets.append(target)
        }
        return targets
    }

    private func makeOutput(for layout: Layout) -> CVPixelBuffer? {
        let pool: CVPixelBufferPool
        if let outputPool, outputPool.layout == layout {
            pool = outputPool.buffers
        } else {
            let attributes = [
                kCVPixelBufferWidthKey: layout.width,
                kCVPixelBufferHeightKey: layout.height,
                kCVPixelBufferPixelFormatTypeKey: layout.format,
                kCVPixelBufferIOSurfacePropertiesKey: [:],
                kCVPixelBufferMetalCompatibilityKey: true,
            ] as CFDictionary
            var created: CVPixelBufferPool?
            guard unsafe CVPixelBufferPoolCreate(nil, nil, attributes, &created) == kCVReturnSuccess,
                  let created else { return nil }
            outputPool = (layout, created)
            pool = created
        }
        var output: CVPixelBuffer?
        let status = unsafe CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, allocationLimit, &output)
        poolIsBusy = status == kCVReturnWouldExceedAllocationThreshold
        return status == kCVReturnSuccess ? output : nil
    }

    private func texture(_ buffer: CVPixelBuffer, plane: Int, format: MTLPixelFormat, usage: MTLTextureUsage) -> (any MTLTexture)? {
        guard let surface = unsafe CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue() else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format, width: CVPixelBufferGetWidthOfPlane(buffer, plane),
            height: CVPixelBufferGetHeightOfPlane(buffer, plane), mipmapped: false,
        )
        #if arch(x86_64)
            descriptor.storageMode = .managed
        #else
            descriptor.storageMode = .shared
        #endif
        descriptor.usage = usage
        return gpu.queue.device.makeTexture(descriptor: descriptor, iosurface: surface, plane: plane)
    }

    private func makeSample(_ output: CVPixelBuffer, matching first: CMSampleBuffer, and second: CMSampleBuffer, at: CMTime) -> CMSampleBuffer? {
        guard let a = first.imageBuffer, let b = second.imageBuffer,
              let formatA = first.formatDescription, let formatB = second.formatDescription else { return nil }
        CVBufferRemoveAllAttachments(output)
        for key in displayKeys {
            let valueA = CVBufferCopyAttachment(a, key, nil) ?? CMFormatDescriptionGetExtension(formatA, extensionKey: key)
            let valueB = CVBufferCopyAttachment(b, key, nil) ?? CMFormatDescriptionGetExtension(formatB, extensionKey: key)
            if let valueA, let valueB, CFEqual(valueA, valueB) {
                CVBufferSetAttachment(output, key, valueA, .shouldPropagate)
            } else if valueA != nil || valueB != nil {
                return nil
            }
        }
        guard let format = try? CMVideoFormatDescription(imageBuffer: output) else { return nil }
        return try? CMSampleBuffer(
            imageBuffer: output, formatDescription: format,
            sampleTiming: CMSampleTimingInfo(duration: first.duration, presentationTimeStamp: at, decodeTimeStamp: .invalid),
        )
    }

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    kernel void blendPlane(texture2d<float, access::read> first [[texture(0)]],
                           texture2d<float, access::read> second [[texture(1)]],
                           texture2d<float, access::write> output [[texture(2)]],
                           constant float2 &parameters [[buffer(0)]],
                           uint2 position [[thread_position_in_grid]]) {
        if (position.x >= output.get_width() || position.y >= output.get_height()) return;
        const float scale = parameters.y;
        const float2 a = round(first.read(position).rg * scale);
        const float2 b = round(second.read(position).rg * scale);
        const float2 blended = floor(mix(a, b, parameters.x) + 0.5f) / scale;
        output.write(float4(blended, 0.0f, 1.0f), position);
    }
    """
}
