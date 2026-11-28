import CoreGraphics
import Foundation

nonisolated struct VideoVariant: Codable, Equatable, Sendable {
    let filename: String
    let fps: Int
    let resolution: CGSize
    var isHDR: Bool? = nil // Encoded output.
    var toneMappedToSDR: Bool? = nil // Explicit HDR-to-SDR conversion.

    func supports(sourceIsHDR: Bool?) -> Bool {
        // Older tiers were playable regardless of the source's dynamic range.
        if isHDR == nil, toneMappedToSDR == nil {
            return true
        }

        return switch sourceIsHDR {
        case true?:
            isHDR == true || (isHDR == false && toneMappedToSDR == true)
        case false?:
            isHDR != true && toneMappedToSDR != true
        case nil:
            false
        }
    }

    func supportsPublication(verifiedSourceIsHDR: Bool, recordedSourceIsHDR: Bool?) -> Bool {
        (recordedSourceIsHDR == nil || recordedSourceIsHDR == verifiedSourceIsHDR)
            && isHDR != nil && supports(sourceIsHDR: verifiedSourceIsHDR)
    }

    func isAvailable(in directory: URL, library: URL) -> Bool {
        guard PathSafety.isSafeComponent(filename), fps > 0 else { return false }
        let url = directory.appendingPathComponent(filename)
        return PathSafety.contained(url, in: library) && PathSafety.isItem(at: url, ofType: .typeRegular)
    }
}
