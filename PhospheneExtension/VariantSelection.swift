import Foundation

struct VideoVariant: Codable, Equatable {
    let filename: String
    let fps: Int
    let resolution: CGSize
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
        sourceFPS: Int,
        variants: [VideoVariant],
    ) -> VideoVariant? {
        guard !variants.isEmpty else { return nil }
        let sorted = variants.sorted { $0.fps > $1.fps }

        switch policy {
        case .paused:
            return nil
        case .full:
            guard let top = sorted.first, top.fps >= sourceFPS else { return nil }
            return top
        case .reduced:
            return sorted.first { $0.fps < sourceFPS } ?? sorted.last
        case .minimal:
            return sorted.last
        }
    }
}
