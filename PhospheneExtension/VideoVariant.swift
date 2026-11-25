import CoreGraphics
import Foundation

nonisolated struct VideoVariant: Codable, Equatable, Sendable {
    let filename: String
    let fps: Int
    let resolution: CGSize
    var isHDR: Bool? = nil // Encoded output.
    var toneMappedToSDR: Bool? = nil // Explicit HDR-to-SDR conversion.

    func supports(sourceIsHDR: Bool?) -> Bool {
        switch sourceIsHDR {
        case true?:
            isHDR == true || (isHDR == false && toneMappedToSDR == true)
        case false?:
            isHDR != true && toneMappedToSDR != true
        case nil:
            isHDR == nil && toneMappedToSDR == nil
        }
    }
}
