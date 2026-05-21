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

    /// Copy a video file into the extension's VideoLibrary folder structure.
    /// Creates `Documents/videos/<uuid>/video.<ext>` + metadata.json.
    /// Probes the video with AVFoundation to populate resolution, fps, and duration.
    /// Skips deployment if a video with the same filename already exists.
    /// Sends a Darwin notification so the extension re-scans its library.
    @MainActor
    static func deployVideo(url: URL, name: String? = nil) async {
        let fileManager = FileManager.default
        let videosDir = extensionDocsURL.appendingPathComponent("videos")
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
                fps = Double((try? await track.load(.nominalFrameRate)) ?? 0)
                resolution = (try? await track.load(.naturalSize)) ?? .zero
                let cmDuration = try? await asset.load(.duration)
                duration = cmDuration.map { CMTimeGetSeconds($0) } ?? 0
            }

            let metadata = DeploymentMetadata(
                id: id,
                name: name ?? url.deletingPathExtension().lastPathComponent,
                filename: url.lastPathComponent,
                duration: duration,
                fps: fps,
                resolution: resolution,
                dateAdded: Date()
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
            asset: asset, presetName: AVAssetExportPresetHEVCHighestQuality
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
        let entryDir = extensionDocsURL
            .appendingPathComponent("videos")
            .appendingPathComponent(entryID)

        let metadataURL = entryDir.appendingPathComponent("metadata.json")
        guard fileManager.fileExists(atPath: metadataURL.path) else {
            Log.video.error("Cannot deploy variants: entry \(entryID) not found")
            return
        }

        var deployedVariants: [VideoVariant] = []

        for (sourceURL, variant) in variants {
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
        let entryDir = extensionDocsURL
            .appendingPathComponent("videos")
            .appendingPathComponent(entryID)
        let metadataURL = entryDir.appendingPathComponent("metadata.json")
        let fm = FileManager.default

        guard let data = try? Data(contentsOf: metadataURL),
              var metadata = try? JSONDecoder().decode(DeploymentMetadata.self, from: data)
        else { return }

        for variant in metadata.variants ?? [] {
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
        let dir = extensionDocsURL
            .appendingPathComponent("videos")
            .appendingPathComponent(entryID)
        try? FileManager.default.removeItem(at: dir)
        Log.video.info("Removed video entry \(entryID) from extension container")
        notifyExtensionLibraryChanged()
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
        let videosDir = extensionDocsURL.appendingPathComponent("videos")
        let fm = FileManager.default

        guard let subdirs = try? fm.contentsOfDirectory(
            at: videosDir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
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
        let url = extensionDocsURL
            .appendingPathComponent("videos")
            .appendingPathComponent(entryID)
            .appendingPathComponent("thumbnail.jpg")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// URL to the video file for an entry.
    static func videoURL(for entry: EntryInfo) -> URL {
        extensionDocsURL
            .appendingPathComponent("videos")
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

    /// Re-probe an existing entry's video and update its metadata.json.
    /// Useful for migrating entries imported before probing was added.
    static func probeAndUpdateMetadata(for entryID: String) async {
        let entryDir = extensionDocsURL
            .appendingPathComponent("videos")
            .appendingPathComponent(entryID)
        let metadataURL = entryDir.appendingPathComponent("metadata.json")

        guard let data = try? Data(contentsOf: metadataURL),
              var metadata = try? JSONDecoder().decode(DeploymentMetadata.self, from: data)
        else { return }

        let videoFile = entryDir.appendingPathComponent(metadata.filename)
        let asset = AVURLAsset(url: videoFile)
        if let track = try? await asset.loadTracks(withMediaType: .video).first {
            metadata.fps = Double((try? await track.load(.nominalFrameRate)) ?? 0)
            metadata.resolution = (try? await track.load(.naturalSize)) ?? .zero
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
    private static func generateThumbnail(for videoURL: URL, in directory: URL) async {
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
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(
            center,
            CFNotificationName("glass.kagerou.phosphene.libraryChanged" as CFString),
            nil,
            nil,
            true
        )
        // Also post in-process so app-side views can observe
        NotificationCenter.default.post(name: libraryChangedNotification, object: nil)
    }
}
