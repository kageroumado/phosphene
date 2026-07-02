import AVFoundation
import ImageIO

/// Resolve a video URL for a specific choice. Each rendering context owns
/// its own choice — never read the process-wide "current" selection here,
/// or concurrent acquires for different displays will race and a renderer
/// can end up initialized with the wrong monitor's video.
///
/// Falls back to the first video in the library, then bundle resources, so
/// the picker fallback path still has something to display.
func findVideoURL(forChoice videoID: String?) -> URL? {
    if let videoID,
       let url = VideoLibrary.shared.videoURL(for: videoID),
       FileManager.default.fileExists(atPath: url.path) {
        return url
    }

    if let first = VideoLibrary.shared.entries.first {
        let url = VideoLibrary.shared.videoURL(for: first)
        if FileManager.default.fileExists(atPath: url.path) {
            return url
        }
    }

    let videoExtensions = ["mp4", "mov", "m4v"]
    for ext in videoExtensions {
        if let url = Bundle.main.url(forResource: "wallpaper", withExtension: ext) {
            return url
        }
    }

    return nil
}

/// Compatibility wrapper for callers without a per-context choice (snapshot
/// requests that don't carry a wallpaperID, etc.). Uses the last user-picked
/// video as a best-effort hint — do not use this on the rendering path.
func findVideoURL() -> URL? {
    findVideoURL(forChoice: WallpaperState.shared.currentVideoID)
}

/// Generate a JPEG thumbnail from the video's first frame.
/// Used by SettingsProvider for the System Settings picker.
func generateThumbnail(from videoURL: URL) async -> URL? {
    let asset = AVURLAsset(url: videoURL)
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: 480, height: 270)

    let cgImage: CGImage
    do {
        cgImage = try await generator.image(at: .zero).image
    } catch {
        extensionLog("  Thumbnail generation failed: \(error)")
        return nil
    }

    let docsDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents")
    try? FileManager.default.createDirectory(at: docsDir, withIntermediateDirectories: true)
    let thumbnailURL = docsDir.appendingPathComponent("thumbnail.jpg")

    guard let dest = CGImageDestinationCreateWithURL(
        thumbnailURL as CFURL, "public.jpeg" as CFString, 1, nil,
    ) else {
        extensionLog("  Thumbnail: failed to create image destination")
        return nil
    }
    CGImageDestinationAddImage(dest, cgImage, [
        kCGImageDestinationLossyCompressionQuality: 0.85,
    ] as CFDictionary)
    guard CGImageDestinationFinalize(dest) else {
        extensionLog("  Thumbnail: failed to finalize")
        return nil
    }

    extensionLog("  Thumbnail saved: \(thumbnailURL.path)")
    return thumbnailURL
}
