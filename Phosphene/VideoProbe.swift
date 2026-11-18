import AVFoundation
import CoreVideo

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
}
