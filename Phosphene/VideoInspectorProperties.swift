import AVFoundation
import SwiftUI

struct VideoInspectorProperties: View {
    let entry: VideoDeploymentService.EntryInfo
    let file: FileIdentity?
    var pair: VideoPairSelection?
    var alternateFile: FileIdentity?
    @State private var format: CMFormatDescription?
    @State private var videoExpanded = true

    var body: some View {
        let url = VideoDeploymentService.videoURL(for: entry)
        let validation = currentValidation
        let showDetails = pair == nil || validation != nil
        let fps = validation.map { Double($0.timescale) / Double($0.frameTicks) } ?? entry.fps
        let duration = validation.map { Double($0.frameCount) / fps } ?? entry.duration
        Section("Video Details", isExpanded: $videoExpanded) {
            if showDetails {
                if let resolution {
                    property("Resolution", resolution)
                }
                if duration.isFinite, duration > 0 {
                    property("Duration", Duration.seconds(duration).formatted(.time(pattern: .minuteSecond)))
                }
                if let format {
                    property("Format", codecName(format))
                }
                if fps.isFinite, fps > 0 {
                    let fps = fps.formatted(.number.precision(.fractionLength(0 ... 3)))
                    property("Frame Rate", String(localized: "\(fps) fps"))
                }
                if let dynamicRange {
                    property("Dynamic Range", dynamicRange)
                }
                if pair == nil, let file {
                    property("File Size", ByteCountFormatter.string(fromByteCount: Int64(clamping: file.size), countStyle: .file))
                }
            } else {
                Text("Shared video details are unavailable because a source file is missing or has changed.")
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: file) {
            format = nil
            guard file != nil, let track = try? await AVURLAsset(url: url).loadTracks(withMediaType: .video).first,
                  let description = try? await track.load(.formatDescriptions).first, !Task.isCancelled else { return }
            format = description
        }
    }

    private func property(_ label: LocalizedStringKey, _ value: String) -> some View {
        LabeledContent(label) {
            Text(verbatim: value).textSelection(.enabled)
        }
    }

    private var dynamicRange: String? {
        if let format {
            let transfer = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String
            if transfer == kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String {
                return "HDR (PQ)"
            }
            if transfer == kCVImageBufferTransferFunction_ITU_R_2100_HLG as String {
                return "HDR (HLG)"
            }
        }
        return entry.sourceIsHDR.map { $0 ? "HDR" : "SDR" }
    }

    private var currentValidation: AppearancePair.Validation? {
        guard let pair, let validation = pair.saved?.validation, validation.version == 1,
              validation.frameCount > 0, validation.frameTicks > 0, validation.timescale > 0,
              pair.first?.id == entry.id, file == validation.original,
              pair.second != nil, alternateFile == validation.alternate
        else { return nil }
        return validation
    }

    private var resolution: String? {
        if pair != nil, let format {
            let size = CMVideoFormatDescriptionGetDimensions(format)
            return "\(size.width) × \(size.height)"
        }
        guard entry.resolution != .zero else { return nil }
        return "\(Int(entry.resolution.width)) × \(Int(entry.resolution.height))"
    }

    private func codecName(_ description: CMFormatDescription) -> String {
        let code = CMFormatDescriptionGetMediaSubType(description)
        switch code {
        case kCMVideoCodecType_HEVC: return "HEVC"
        case kCMVideoCodecType_H264: return "H.264"
        case kCMVideoCodecType_VP9: return "VP9"
        case kCMVideoCodecType_AV1: return "AV1"
        default:
            let bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: code >> $0) }
            return String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? String(localized: "Unknown")
        }
    }
}
