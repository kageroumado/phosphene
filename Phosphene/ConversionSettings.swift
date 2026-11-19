import AVFoundation

nonisolated enum ConversionMode {
    case single
    case pair
}

nonisolated enum ConversionRange: CaseIterable, Identifiable {
    case sdr
    case hlg
    case pq

    var id: Self {
        self
    }
    var title: String {
        switch self {
        case .sdr: "SDR · Rec. 709"
        case .hlg: "HDR · HLG"
        case .pq: "HDR · PQ"
        }
    }
}

nonisolated enum ConversionCodec: CaseIterable, Identifiable {
    case h264
    case hevc
    var id: Self {
        self
    }
    var title: String {
        self == .hevc ? "HEVC" : "H.264"
    }
}

nonisolated enum ConversionFraming: CaseIterable, Identifiable {
    case fit
    case fill
    var id: Self {
        self
    }
    var title: String {
        self == .fit ? String(localized: "Fit with Black Bars") : String(localized: "Fill and Crop")
    }
}

nonisolated struct ConversionSettings: Equatable, Sendable {
    var width = 1_920
    var height = 1_080
    var fps = 30.0
    var bitrateMbps = 6.0
    var duration = 0.0
    var range = ConversionRange.sdr
    var codec = ConversionCodec.h264
    var framing = ConversionFraming.fit

    var hasValidDimensions: Bool {
        (2 ... 16_384).contains(width) && (2 ... 16_384).contains(height) && width.isMultiple(of: 2) && height.isMultiple(of: 2)
    }

    var frameDuration: CMTime {
        guard fps.isFinite, (1 ... 1_000).contains(fps) else { return .invalid }
        // Preserve NTSC cadence when entered as the customary decimal frame rate.
        for rate: Int32 in [24_000, 30_000, 60_000, 120_000] where abs(fps - Double(rate) / 1_001) < 0.0006 {
            return CMTime(value: 1_001, timescale: rate)
        }
        return CMTime(value: 1_000, timescale: Int32((fps * 1_000).rounded()))
    }

    var frameCount: Int32 {
        let count = (duration / frameDuration.seconds).rounded()
        guard count.isFinite, count >= 1, count <= Double(Int32.max) else { return 0 }
        return Int32(count)
    }

    func validate(forPair: Bool) throws {
        guard hasValidDimensions else {
            throw ConversionIssue(String(localized: "Enter even dimensions between 2 and 16,384 pixels."))
        }
        guard frameDuration.isNumeric, !forPair || frameDuration <= CMTime(value: 1, timescale: 2) else {
            throw ConversionIssue(forPair ? String(localized: "Enter a frame rate from 2 to 1,000 fps for a pair.") : String(localized: "Enter a frame rate from 1 to 1,000 fps."))
        }
        guard bitrateMbps.isFinite, bitrateMbps * 1_000_000 >= 1, bitrateMbps * 1_000_000 <= Double(Int32.max) else {
            throw ConversionIssue(String(localized: "Enter a positive bitrate below 2,148 Mb/s."))
        }
        guard frameCount > 0 else { throw ConversionIssue(String(localized: "Choose a frame rate that fits the source duration.")) }
        guard range == .sdr || codec == .hevc else { throw ConversionIssue(String(localized: "HDR output requires 10-bit HEVC.")) }
    }
}

nonisolated struct ConversionIssue: LocalizedError {
    let errorDescription: String?
    init(_ message: String) {
        errorDescription = message
    }
}

nonisolated struct ConversionSource {
    let url: URL
    let name: String
    let identity: FileIdentity
    let range: ConversionRange?
    let width: Int
    let height: Int
    let fps: Double
    let duration: Double
    let bitrateMbps: Double?
    let bitDepth: Int?

    @concurrent
    static func inspect(url: URL, name: String) async throws -> Self {
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped {
                url.stopAccessingSecurityScopedResource()
            }
        }
        guard let identity = FileIdentity(of: url) else { throw CocoaError(.fileReadNoSuchFile) }
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let info = try await VideoOptimizationService.loadSource(in: asset, assumeSDR: true)
        let track = info.track
        let (size, transform, rate, time, bitrate, formats) = try await track.load(
            .naturalSize, .preferredTransform, .nominalFrameRate, .timeRange, .estimatedDataRate, .formatDescriptions,
        )
        let display = CGRect(origin: .zero, size: size).applying(transform).standardized.size
        guard rate.isFinite, rate > 0, time.duration.isNumeric, time.duration > .zero,
              display.width.isFinite, display.height.isFinite, display.width >= 1, display.height >= 1,
              display.width <= CGFloat(Int32.max), display.height <= CGFloat(Int32.max), let format = formats.first else {
            throw ConversionIssue(String(localized: "The source dimensions, frame rate, or duration could not be read."))
        }
        let sourceRange: ConversionRange? = if let profile = info.hdr {
            profile.colors[AVVideoTransferFunctionKey] == AVVideoTransferFunction_ITU_R_2100_HLG ? .hlg : .pq
        } else {
            info.assumesSDR ? nil : .sdr
        }
        var depth = (CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_BitsPerComponent) as? NSNumber)?.intValue
        if depth == nil {
            if VideoProbe.isHEVCMain10(format) {
                depth = 10
            } else if VideoProbe.isH264High8(format) {
                depth = 8
            }
        }
        guard FileIdentity(of: url) == identity else { throw PairIssue.changed }
        return Self(
            url: url,
            name: name,
            identity: identity,
            range: sourceRange,
            width: Int(display.width.rounded()),
            height: Int(display.height.rounded()),
            fps: Double(rate),
            duration: time.duration.seconds,
            bitrateMbps: bitrate.isFinite && bitrate > 0 ? Double(bitrate) / 1_000_000 : nil,
            bitDepth: depth,
        )
    }

    func upgrades(to target: ConversionSettings) -> [String] {
        var reasons = [String]()
        let horizontal = Double(target.width) / Double(width)
        let vertical = Double(target.height) / Double(height)
        let scale = target.framing == .fit ? min(horizontal, vertical) : max(horizontal, vertical)
        if scale > 1.000001 {
            let factor = scale.formatted(.number.precision(.fractionLength(0 ... 3)))
            reasons.append(String(localized: "Picture enlarged by \(factor)×."))
        } else if target.width > width || target.height > height {
            reasons.append(String(localized: "Larger output canvas: \(width) × \(height) → \(target.width) × \(target.height) pixels."))
        }
        let actualFPS = 1 / target.frameDuration.seconds
        if actualFPS - fps > max(0.00005, fps * 0.000001) {
            reasons.append(String(localized: "Frame rate \(Self.number(fps)) → \(Self.number(actualFPS)) fps. Extra frames repeat source images."))
        }
        if (range ?? .sdr) == .sdr, target.range != .sdr {
            reasons.append(String(localized: "SDR → \(target.range.title). Original highlights stay at SDR reference levels."))
        }
        let outputDepth = target.range == .sdr ? 8 : 10
        if let bitDepth, outputDepth > bitDepth {
            reasons.append(String(localized: "Bit depth \(bitDepth) → \(outputDepth) bits."))
        } else if bitDepth == nil, target.range != .sdr {
            reasons.append(String(localized: "Output is 10-bit. The source bit depth could not be confirmed."))
        }
        if let bitrateMbps, target.bitrateMbps > bitrateMbps + 0.000001 {
            reasons.append(String(localized: "Average bitrate \(Self.number(bitrateMbps)) → \(Self.number(target.bitrateMbps)) Mb/s."))
        }
        return reasons
    }

    private static func number(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0 ... 3)))
    }
}
