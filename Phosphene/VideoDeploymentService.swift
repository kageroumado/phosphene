import AppKit
import AVFoundation
import Foundation
import os

/// Metadata structure matching the extension's VideoEntry Codable format.
private struct DeploymentMetadata: Codable {
    let id: String
    var name: String
    var filename: String
    var duration: Double
    var fps: Double
    var resolution: CGSize
    var dateAdded: Date
    var variants: [VideoVariant]?
}

enum VideoDeploymentService {
    /// Extension container where the wallpaper extension looks for video files.
    private static var extensionDocsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/glass.kagerou.phosphene.extension/Data/Documents")
    }

    /// The library folder holding one subfolder per video (media + metadata + thumbnail).
    static var videosFolderURL: URL {
        extensionDocsURL.appendingPathComponent("videos")
    }

    /// Copy a video file into the extension's VideoLibrary folder structure.
    /// Creates `Documents/videos/<uuid>/video.<ext>` + metadata.json.
    /// Probes the video with AVFoundation to populate resolution, fps, and duration.
    /// Skips deployment if a video with the same filename already exists.
    /// Sends a Darwin notification so the extension re-scans its library.
    @MainActor
    static func deployVideo(url: URL, name: String? = nil) async {
        let fileManager = FileManager.default
        let videosDir = videosFolderURL
        try? fileManager.createDirectory(at: videosDir, withIntermediateDirectories: true)

        // Dedup: skip if a video with the same filename already exists in the library
        let existing = listEntries()
        if existing.contains(where: { $0.filename == url.lastPathComponent }) {
            Log.video.info("Video '\(url.lastPathComponent)' already in library, skipping deploy")
            return
        }

        let id = UUID().uuidString
        let dir = videosDir.appendingPathComponent(id)

        do {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            let destURL = dir.appendingPathComponent(url.lastPathComponent)
            try fileManager.copyItem(at: url, to: destURL)

            var fps: Double = 0
            var resolution: CGSize = .zero
            var duration: Double = 0

            let asset = AVURLAsset(url: destURL)
            if let track = try? await asset.loadTracks(withMediaType: .video).first {
                fps = await Double((try? track.load(.nominalFrameRate)) ?? 0)
                resolution = await (try? track.load(.naturalSize)) ?? .zero
                let cmDuration = try? await asset.load(.duration)
                duration = cmDuration.map { CMTimeGetSeconds($0) } ?? 0
            }

            let metadata = DeploymentMetadata(
                id: id,
                name: name ?? VideoDisplayName.pretty(from: url.deletingPathExtension().lastPathComponent),
                filename: url.lastPathComponent,
                duration: duration,
                fps: fps,
                resolution: resolution,
                dateAdded: Date(),
            )
            let data = try JSONEncoder().encode(metadata)
            try data.write(to: dir.appendingPathComponent("metadata.json"))

            await generateThumbnail(for: destURL, in: dir)

            Log.video.info("Deployed video '\(url.lastPathComponent)' as \(id) to \(dir.path)")
            notifyExtensionLibraryChanged()
        } catch {
            Log.video.error("Failed to deploy video: \(error.localizedDescription)")
            try? fileManager.removeItem(at: dir)
        }
    }

    /// Convert a video to HEVC and deploy to the extension.
    @MainActor
    static func convertAndDeploy(url: URL, name: String? = nil) async {
        let fileManager = FileManager.default
        let tempURL = fileManager.temporaryDirectory
            .appendingPathComponent("convert_\(UUID().uuidString).mov")

        let asset = AVURLAsset(url: url)
        guard let exportSession = AVAssetExportSession(
            asset: asset, presetName: AVAssetExportPresetHEVCHighestQuality,
        ) else {
            await deployVideo(url: url, name: name)
            return
        }

        do {
            try await exportSession.export(to: tempURL, as: .mov)
            await deployVideo(url: tempURL, name: name)
            try? fileManager.removeItem(at: tempURL)
        } catch {
            Log.video.error("HEVC conversion failed: \(error.localizedDescription)")
            await deployVideo(url: url, name: name)
        }
    }

    /// Deploy optimized variants into an existing entry's directory in the extension container.
    /// Updates metadata.json with the variants array and notifies the extension.
    @MainActor
    static func deployVariants(entryID: String, variants: [(url: URL, variant: VideoVariant)]) {
        let fileManager = FileManager.default
        guard let entryDir = validatedEntryDir(entryID) else { return }

        let metadataURL = entryDir.appendingPathComponent("metadata.json")
        guard fileManager.fileExists(atPath: metadataURL.path) else {
            Log.video.error("Cannot deploy variants: entry \(entryID) not found")
            return
        }

        var deployedVariants: [VideoVariant] = []

        for (sourceURL, variant) in variants {
            // Reject any variant whose filename isn't a safe basename.
            guard PathSafety.isSafeComponent(variant.filename) else {
                Log.video.error("Skipping variant with unsafe filename: \(variant.filename)")
                continue
            }
            let destURL = entryDir.appendingPathComponent(variant.filename)
            do {
                if fileManager.fileExists(atPath: destURL.path) {
                    try fileManager.removeItem(at: destURL)
                }
                try fileManager.copyItem(at: sourceURL, to: destURL)
                deployedVariants.append(variant)
            } catch {
                Log.video.error("Failed to deploy variant \(variant.filename): \(error.localizedDescription)")
            }
        }

        guard !deployedVariants.isEmpty else { return }

        do {
            let data = try Data(contentsOf: metadataURL)
            var metadata = try JSONDecoder().decode(DeploymentMetadata.self, from: data)
            metadata.variants = deployedVariants
            let updated = try JSONEncoder().encode(metadata)
            try updated.write(to: metadataURL, options: .atomic)
            Log.video.info("Deployed \(deployedVariants.count) variant(s) for entry \(entryID)")
        } catch {
            Log.video.error("Failed to update metadata for variants: \(error.localizedDescription)")
        }

        notifyExtensionLibraryChanged()
    }

    /// Remove variant files and clear the variants array in metadata for an entry.
    @MainActor
    static func removeVariants(entryID: String) {
        guard let entryDir = validatedEntryDir(entryID) else { return }
        let metadataURL = entryDir.appendingPathComponent("metadata.json")
        let fm = FileManager.default

        guard let data = try? Data(contentsOf: metadataURL),
              var metadata = try? JSONDecoder().decode(DeploymentMetadata.self, from: data)
        else { return }

        for variant in metadata.variants ?? [] {
            guard PathSafety.isSafeComponent(variant.filename) else { continue }
            let variantURL = entryDir.appendingPathComponent(variant.filename)
            try? fm.removeItem(at: variantURL)
        }

        metadata.variants = nil
        if let updated = try? JSONEncoder().encode(metadata) {
            try? updated.write(to: metadataURL, options: .atomic)
        }
        Log.video.info("Removed variants for entry \(entryID)")
        notifyExtensionLibraryChanged()
    }

    /// Remove a video entry from the extension container.
    static func removeVideo(entryID: String) {
        guard let dir = validatedEntryDir(entryID) else { return }
        try? FileManager.default.removeItem(at: dir)
        Log.video.info("Removed video entry \(entryID) from extension container")
        notifyExtensionLibraryChanged()
    }

    /// Resolve an entry's directory only when `entryID` is a valid UUID and the
    /// resulting path stays inside the extension's `videos/` tree. The single
    /// gate every entry-id-derived filesystem mutation passes through, so a
    /// malformed id can never reach removeItem/copyItem with an escaped path.
    private static func validatedEntryDir(_ entryID: String) -> URL? {
        let videosDir = videosFolderURL
        let dir = videosDir.appendingPathComponent(entryID)
        guard PathSafety.isValidEntryID(entryID), PathSafety.contained(dir, in: videosDir) else {
            Log.video.error("Rejecting unsafe entry id: \(entryID)")
            return nil
        }
        return dir
    }

    /// Metadata structure for reading entries (mirrors the extension's VideoEntry).
    struct EntryInfo: Codable {
        let id: String
        var name: String
        var filename: String
        var duration: Double
        var fps: Double
        var resolution: CGSize
        var dateAdded: Date
        var variants: [VideoVariant]?
    }

    /// List all valid video entries in the extension container.
    /// Validates that the video file exists, skipping orphaned entries.
    static func listEntries() -> [EntryInfo] {
        let videosDir = videosFolderURL
        let fm = FileManager.default

        guard let subdirs = try? fm.contentsOfDirectory(
            at: videosDir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles,
        ) else { return [] }

        var entries = [EntryInfo]()
        for dir in subdirs where dir.hasDirectoryPath {
            let metadataURL = dir.appendingPathComponent("metadata.json")
            guard let data = try? Data(contentsOf: metadataURL),
                  let entry = try? JSONDecoder().decode(EntryInfo.self, from: data) else { continue }

            let videoFile = dir.appendingPathComponent(entry.filename)
            guard fm.fileExists(atPath: videoFile.path) else { continue }

            entries.append(entry)
        }

        return entries.sorted { $0.dateAdded < $1.dateAdded }
    }

    /// URL to the thumbnail for an entry, if it exists.
    static func thumbnailURL(for entryID: String) -> URL? {
        let url = videosFolderURL
            .appendingPathComponent(entryID)
            .appendingPathComponent("thumbnail.jpg")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// URL to the video file for an entry.
    static func videoURL(for entry: EntryInfo) -> URL {
        videosFolderURL
            .appendingPathComponent(entry.id)
            .appendingPathComponent(entry.filename)
    }

    /// File size of the video for a library entry, in bytes.
    static func fileSize(for entry: EntryInfo) -> Int64? {
        let url = videoURL(for: entry)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64
        else { return nil }
        return size
    }

    /// Rename an entry. The stored `name` is the display name everywhere —
    /// library, popover, and the System Settings wallpaper picker.
    static func renameEntry(entryID: String, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let entryDir = validatedEntryDir(entryID) else { return }
        let metadataURL = entryDir.appendingPathComponent("metadata.json")
        guard let data = try? Data(contentsOf: metadataURL),
              var metadata = try? JSONDecoder().decode(DeploymentMetadata.self, from: data),
              metadata.name != trimmed
        else { return }
        metadata.name = trimmed
        if let updated = try? JSONEncoder().encode(metadata) {
            try? updated.write(to: metadataURL, options: .atomic)
        }
        notifyExtensionLibraryChanged()
    }

    /// One-shot cleanup for entries imported before names were prettified at import:
    /// a name still equal to its file-name stem is a slug, not a choice, so it gets the
    /// same treatment new imports get. Returns whether anything changed.
    static func prettifyLegacyNames() -> Bool {
        var changed = false
        for entry in listEntries() {
            let stem = (entry.filename as NSString).deletingPathExtension
            guard entry.name == stem else { continue }
            let pretty = VideoDisplayName.pretty(from: entry.name)
            guard pretty != entry.name else { continue }
            renameEntry(entryID: entry.id, to: pretty)
            changed = true
        }
        return changed
    }

    /// Re-probe an existing entry's video and update its metadata.json.
    /// Useful for migrating entries imported before probing was added.
    static func probeAndUpdateMetadata(for entryID: String) async {
        guard let entryDir = validatedEntryDir(entryID) else { return }
        let metadataURL = entryDir.appendingPathComponent("metadata.json")

        guard let data = try? Data(contentsOf: metadataURL),
              var metadata = try? JSONDecoder().decode(DeploymentMetadata.self, from: data)
        else { return }

        let videoFile = entryDir.appendingPathComponent(metadata.filename)
        let asset = AVURLAsset(url: videoFile)
        if let track = try? await asset.loadTracks(withMediaType: .video).first {
            metadata.fps = await Double((try? track.load(.nominalFrameRate)) ?? 0)
            metadata.resolution = await (try? track.load(.naturalSize)) ?? .zero
            let cmDuration = try? await asset.load(.duration)
            metadata.duration = cmDuration.map { CMTimeGetSeconds($0) } ?? 0
        }

        if let updated = try? JSONEncoder().encode(metadata) {
            try? updated.write(to: metadataURL, options: .atomic)
        }
        Log.video.info("Re-probed metadata for entry \(entryID)")
    }

    /// Notification posted in-process when the library changes.
    static let libraryChangedNotification = Notification.Name("glass.kagerou.phosphene.libraryChanged")

    /// Generate a thumbnail.jpg from the first frame of a video.
    /// Uses async/await so the caller can coordinate thumbnail availability.
    @MainActor
    static func generateThumbnail(for videoURL: URL, in directory: URL) async {
        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 360)

        let cgImage: CGImage
        do {
            cgImage = try await generator.image(at: .zero).image
        } catch {
            Log.video.error("Thumbnail generation failed: \(error.localizedDescription)")
            return
        }

        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let jpegData = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else {
            Log.video.error("Thumbnail JPEG encoding failed")
            return
        }

        let thumbnailURL = directory.appendingPathComponent("thumbnail.jpg")
        do {
            try jpegData.write(to: thumbnailURL, options: .atomic)
        } catch {
            Log.video.error("Thumbnail write failed: \(error.localizedDescription)")
        }
    }

    private static func notifyExtensionLibraryChanged() {
        invalidateHostViewModelCache()
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(
            center,
            CFNotificationName("glass.kagerou.phosphene.libraryChanged" as CFString),
            nil,
            nil,
            true,
        )
        // Also post in-process so app-side views can observe
        NotificationCenter.default.post(name: libraryChangedNotification, object: nil)
    }

    /// Delete WallpaperAgent's cached copy of the extension's settings view models.
    /// The agent caches each provider's tiles on disk and (on macOS 26.6) serves
    /// that cache on every Settings launch without re-querying the extension, so a
    /// library change made while the extension process is not running would never
    /// surface (issue #27). The darwin notification updates a live extension in
    /// place; deleting the cache covers a dead one — the next Settings query then
    /// has to go to the extension. Deleted before the notification is posted so a
    /// live extension's push (debounced ~0.5s) always lands after the deletion.
    private static func invalidateHostViewModelCache() {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        let length = unsafe confstr(_CS_DARWIN_USER_CACHE_DIR, &buf, buf.count)
        guard length > 0 else { return }
        let pathBytes = buf.prefix(length - 1).map { UInt8(bitPattern: $0) }
        let cacheDir = URL(fileURLWithPath: String(decoding: pathBytes, as: UTF8.self))
            .appendingPathComponent("com.apple.wallpaper.agent/com.apple.wallpaper.view-model-cache")
        for surface in ["desktop", "screenSaver"] {
            let file = cacheDir
                .appendingPathComponent("extension-glass.kagerou.phosphene.extension-\(surface)")
            try? FileManager.default.removeItem(at: file)
        }
    }
}
