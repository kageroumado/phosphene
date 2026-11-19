import AVFoundation
import CoreVideo
import VideoToolbox

nonisolated struct VideoProbe {
    var fps: Double?
    var resolution: CGSize?
    var duration: Double?
    var isHDR: Bool?

    @concurrent
    static func inspect(_ url: URL) async -> Self {
        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.loadTracks(withMediaType: .video),
              let track = tracks.first else { return Self() }
        return await Self(
            fps: (try? track.load(.nominalFrameRate)).map(Double.init),
            resolution: try? track.load(.naturalSize),
            duration: (try? asset.load(.duration))?.seconds,
            isHDR: tracks.count == 1 ? classify(track) : nil,
        )
    }

    static func classify(_ track: AVAssetTrack) async -> Bool? {
        guard let formats = try? await track.load(.formatDescriptions), !formats.isEmpty,
              let characteristics = try? await track.load(.mediaCharacteristics) else { return nil }
        let markedHDR = characteristics.contains(.containsHDRVideo)
        var classifications = Set<Bool>()
        for format in formats {
            let transfer = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String
            if [kCVImageBufferTransferFunction_ITU_R_2100_HLG as String, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String].contains(transfer) {
                classifications.insert(true)
            } else if [
                kCVImageBufferTransferFunction_ITU_R_709_2 as String,
                kCVImageBufferTransferFunction_sRGB as String,
                kCVImageBufferTransferFunction_SMPTE_240M_1995 as String,
                kCVImageBufferTransferFunction_ITU_R_2020 as String,
            ].contains(transfer) {
                guard !markedHDR else { return nil }
                classifications.insert(false)
            } else if transfer == nil, markedHDR {
                classifications.insert(true)
            } else {
                return nil
            }
        }
        return classifications.count == 1 ? classifications.first : nil
    }

    struct HDRFormat: Equatable, Sendable {
        let colors: [String: String]
        let fullRange: Bool
        let staticMetadata: [String: Data]
    }

    static func colorProperties(_ format: CMFormatDescription) -> [String: String] {
        [
            AVVideoColorPrimariesKey: CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_ColorPrimaries) as? String,
            AVVideoTransferFunctionKey: CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String,
            AVVideoYCbCrMatrixKey: CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_YCbCrMatrix) as? String,
        ].compactMapValues { $0 }
    }

    private static func sampleDescriptionAtoms(_ format: CMFormatDescription) -> [String: Any] {
        CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Any] ?? [:]
    }

    static func isHEVCMain10(_ format: CMFormatDescription) -> Bool {
        guard format.mediaSubType.rawValue == kCMVideoCodecType_HEVC,
              let config = sampleDescriptionAtoms(format)["hvcC"] as? Data, config.count >= 23 else { return false }
        // HEVCDecoderConfigurationRecord: profile IDC and luma/chroma bit_depth_minus8.
        return config[1] & 0x1F == 2 && config[17] & 7 == 2 && config[18] & 7 == 2
    }

    static func isH264High8(_ format: CMFormatDescription) -> Bool {
        guard let config = sampleDescriptionAtoms(format)["avcC"] as? Data, config.count >= 4 else { return false }
        return config[1] == 100 // AVC High profile (8-bit)
    }

    static func hdrFormat(_ format: CMFormatDescription) -> HDRFormat? {
        switch format.mediaSubType.rawValue {
        case kCMVideoCodecType_HEVC, 0x6865_7631, // hev1
             kCMVideoCodecType_AppleProRes422, kCMVideoCodecType_AppleProRes422HQ,
             kCMVideoCodecType_AppleProRes422LT, kCMVideoCodecType_AppleProRes422Proxy,
             kCMVideoCodecType_AppleProRes4444, kCMVideoCodecType_AppleProRes4444XQ:
            break
        default:
            return nil
        }

        let colors = colorProperties(format)
        let transfer = colors[AVVideoTransferFunctionKey]
        let atoms = sampleDescriptionAtoms(format)
        guard colors.count == 3,
              transfer == AVVideoTransferFunction_ITU_R_2100_HLG || transfer == AVVideoTransferFunction_SMPTE_ST_2084_PQ,
              ["dvcC", "dvvC", "dvwC"].allSatisfy({ atoms[$0] == nil }) else { return nil }

        var metadata: [String: Data] = [:]
        for (extensionKey, atom, property, length) in [
            (kCMFormatDescriptionExtension_MasteringDisplayColorVolume, "mdcv", kVTCompressionPropertyKey_MasteringDisplayColorVolume, 24),
            (kCMFormatDescriptionExtension_ContentLightLevelInfo, "clli", kVTCompressionPropertyKey_ContentLightLevelInfo, 4),
        ] {
            let native = CMFormatDescriptionGetExtension(format, extensionKey: extensionKey)
            if let value = native ?? atoms[atom] {
                guard let data = value as? Data, data.count == length else { return nil }
                metadata[property as String] = data
            }
        }

        return HDRFormat(
            colors: colors,
            fullRange: CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_FullRangeVideo) as? Bool ?? false,
            staticMetadata: metadata,
        )
    }
}
