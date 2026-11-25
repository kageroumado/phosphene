import CoreGraphics
import Foundation

struct VideoVariant: Codable, Equatable {
    let filename: String
    let fps: Int
    let resolution: CGSize
    var isHDR: Bool? = nil // Encoded output.
    var toneMappedToSDR: Bool? = nil // Explicit HDR-to-SDR conversion.
}

/// Picks the variant to play for a playback policy — the pure half of
/// `VideoLibrary.bestVariantURL`, separated so it can be tested.
enum VariantSelection {
    /// The variant to play, or nil for the original file.
    ///
    /// `full` plays a variant only when one matches the source frame rate (Battery
    /// Saver's downscaled full-rate tier) — the optimizer skips the full-FPS tier
    /// when it isn't downscaling, so the top variant can be a half-rate tier and
    /// full policy must fall back to the original file. `reduced` picks the highest
    /// tier below the source rate, `minimal` the lowest. `paused` and an empty
    /// variant list resolve to the original.
    static func variant(
        for policy: PlaybackPolicy,
        sourceIsHDR: Bool?,
        sourceFPS: Int,
        variants: [VideoVariant],
    ) -> VideoVariant? {
        tier(for: policy, sourceFPS: sourceFPS, tiers: variants.filter { $0.supports(sourceIsHDR: sourceIsHDR) }, fps: \.fps)
    }

    static func tier<T>(for policy: PlaybackPolicy, sourceFPS: Int, tiers: [T], fps: KeyPath<T, Int>) -> T? {
        let sorted = tiers.filter { $0[keyPath: fps] > 0 }.sorted { $0[keyPath: fps] > $1[keyPath: fps] }

        switch policy {
        case .paused:
            return nil
        case .full:
            guard let top = sorted.first, top[keyPath: fps] >= sourceFPS else { return nil }
            return top
        case .reduced:
            return sorted.first { $0[keyPath: fps] < sourceFPS } ?? sorted.last
        case .minimal:
            return sorted.last
        }
    }
}

extension VideoVariant {
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
