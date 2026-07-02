import AVFoundation
import Foundation
import ImageIO
import os

struct VideoVariant: Codable {
    let filename: String
    let fps: Int
    let resolution: CGSize
}

struct VideoEntry: Codable {
    let id: String
    var name: String
    var filename: String
    var duration: Double
    var fps: Double
    var resolution: CGSize
    var dateAdded: Date
    var variants: [VideoVariant]?
}

final class VideoLibrary: Sendable {
    static let shared = VideoLibrary()

    private let videosDir: URL
    private let indexURL: URL
    private let lock = OSAllocatedUnfairLock(initialState: [VideoEntry]())

    private init() {
        let docs = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents")
        self.videosDir = docs.appendingPathComponent("videos")
        self.indexURL = docs.appendingPathComponent("library.json")
        try? FileManager.default.createDirectory(at: videosDir, withIntermediateDirectories: true)
    }

    // MARK: - Public API

    /// All videos currently in the library.
    var entries: [VideoEntry] {
        lock.withLock { $0 }
    }

    /// Find a video entry by its UUID string.
    func entry(for id: String) -> VideoEntry? {
        lock.withLock { entries in
            entries.first { $0.id == id }
        }
    }

    /// URL to the video file for a given entry.
    func videoURL(for entry: VideoEntry) -> URL {
        videosDir
            .appendingPathComponent(entry.id)
            .appendingPathComponent(entry.filename)
    }

    /// URL to the video file for a given video ID.
    func videoURL(for id: String) -> URL? {
        guard let entry = entry(for: id) else { return nil }
        return videoURL(for: entry)
    }

    /// URL to a specific variant file within an entry's directory.
    func variantURL(for entryId: String, variant: VideoVariant) -> URL {
        videosDir
            .appendingPathComponent(entryId)
            .appendingPathComponent(variant.filename)
    }

    /// Select the best variant URL for a given playback policy.
    ///
    /// For entries with variants: `full` picks highest fps, `reduced` picks middle tier,
    /// `minimal` picks lowest fps. Falls back to original file URL if no variants exist.
    /// Returns `nil` only if the entry itself doesn't exist.
    func bestVariantURL(for id: String, policy: PlaybackPolicy) -> URL? {
        guard let entry = entry(for: id) else { return nil }

        guard let variants = entry.variants, !variants.isEmpty else {
            return videoURL(for: entry)
        }

        let sorted = variants.sorted { $0.fps > $1.fps }

        let chosen: VideoVariant
        switch policy {
        case .paused:
            return videoURL(for: entry)
        case .full:
            chosen = sorted.first!
        case .minimal:
            chosen = sorted.last!
        case .reduced:
            let midIndex = sorted.count / 2
            chosen = sorted[midIndex]
        }

        return variantURL(for: id, variant: chosen)
    }

    /// Update the variants array for an entry and persist to metadata.json.
    func updateVariants(for id: String, variants: [VideoVariant]) {
        lock.withLock { entries in
            guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
            entries[idx].variants = variants
        }
        let metadataURL = videosDir
            .appendingPathComponent(id)
            .appendingPathComponent("metadata.json")
        if let entry = entry(for: id) {
            try? JSONEncoder().encode(entry).write(to: metadataURL)
        }
        saveIndex(entries)
    }

    /// Scan the videos directory and rebuild the in-memory index.
    /// Also migrates any legacy `wallpaper.{mp4,mov,m4v}` from Documents root.
    func scan() {
        migrateLegacyVideo()

        var discovered = [VideoEntry]()
        let fm = FileManager.default
        guard let subdirs = try? fm.contentsOfDirectory(
            at: videosDir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles,
        ) else {
            lock.withLock { $0 = [] }
            saveIndex([])
            return
        }

        for dir in subdirs where dir.hasDirectoryPath {
            let id = dir.lastPathComponent

            // Quarantine anything that isn't a well-formed entry directory.
            // Skip (never delete) so a corrupt or hand-edited library can't make
            // a stray name drive a removal outside the tree.
            guard PathSafety.isValidEntryID(id) else {
                extensionLog("[VideoLibrary] Skipping non-UUID directory: \(id)")
                continue
            }

            let metadataURL = dir.appendingPathComponent("metadata.json")

            if let data = try? Data(contentsOf: metadataURL),
               let entry = try? JSONDecoder().decode(VideoEntry.self, from: data) {
                // Metadata id must match its containing directory, and the
                // filename must be a safe basename that resolves inside `dir`.
                guard entry.id == id, PathSafety.isSafeComponent(entry.filename) else {
                    extensionLog("[VideoLibrary] Quarantining \(id): metadata id/filename mismatch or unsafe")
                    continue
                }
                let videoFile = dir.appendingPathComponent(entry.filename)
                guard PathSafety.contained(videoFile, in: videosDir) else {
                    extensionLog("[VideoLibrary] Quarantining \(id): video path escapes library")
                    continue
                }
                guard fm.fileExists(atPath: videoFile.path) else {
                    extensionLog("[VideoLibrary] Pruning orphaned entry \(id): video file missing")
                    try? fm.removeItem(at: dir)
                    continue
                }
                discovered.append(sanitizingVariants(entry))
            } else if let videoFile = findVideoFile(in: dir) {
                let entry = VideoEntry(
                    id: id,
                    name: videoFile.deletingPathExtension().lastPathComponent,
                    filename: videoFile.lastPathComponent,
                    duration: 0,
                    fps: 0,
                    resolution: .zero,
                    dateAdded: Date(),
                )
                discovered.append(entry)
                try? JSONEncoder().encode(entry).write(to: metadataURL)
            } else {
                extensionLog("[VideoLibrary] Pruning empty directory \(id): no video file found")
                try? fm.removeItem(at: dir)
            }
        }

        discovered.sort { $0.dateAdded < $1.dateAdded }
        let sorted = discovered
        lock.withLock { $0 = sorted }
        saveIndex(sorted)
        traceLog("[VideoLibrary] Scanned: \(sorted.count) video(s)")
    }

    /// Add a video file to the library, copying it into the managed directory.
    /// Returns the new entry's ID.
    @discardableResult
    func addVideo(from sourceURL: URL, name: String? = nil) -> String? {
        let id = UUID().uuidString
        let dir = videosDir.appendingPathComponent(id)
        let fm = FileManager.default

        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let destURL = dir.appendingPathComponent(sourceURL.lastPathComponent)
            try fm.copyItem(at: sourceURL, to: destURL)

            let entry = VideoEntry(
                id: id,
                name: name ?? sourceURL.deletingPathExtension().lastPathComponent,
                filename: sourceURL.lastPathComponent,
                duration: 0,
                fps: 0,
                resolution: .zero,
                dateAdded: Date(),
            )
            let metadataURL = dir.appendingPathComponent("metadata.json")
            try JSONEncoder().encode(entry).write(to: metadataURL)

            lock.withLock { $0.append(entry) }
            saveIndex(entries)
            extensionLog("[VideoLibrary] Added: \(entry.name) (\(id))")
            return id
        } catch {
            extensionLog("[VideoLibrary] Failed to add video: \(error)")
            try? fm.removeItem(at: dir)
            return nil
        }
    }

    /// Remove a video from the library.
    func removeVideo(id: String) {
        let dir = videosDir.appendingPathComponent(id)
        // Only ever delete a valid UUID directory that resolves inside the
        // library — a malformed id must not reach removeItem at all.
        guard PathSafety.isValidEntryID(id), PathSafety.contained(dir, in: videosDir) else {
            extensionLog("[VideoLibrary] Refusing to remove unsafe id: \(id)")
            return
        }
        try? FileManager.default.removeItem(at: dir)
        lock.withLock { entries in
            entries.removeAll { $0.id == id }
        }
        saveIndex(entries)
        extensionLog("[VideoLibrary] Removed: \(id)")
    }

    /// Drop any variants whose filename isn't a safe basename, so a corrupt
    /// metadata.json can't steer variant selection to an out-of-tree path.
    private func sanitizingVariants(_ entry: VideoEntry) -> VideoEntry {
        guard let variants = entry.variants else { return entry }
        let safe = variants.filter { PathSafety.isSafeComponent($0.filename) }
        guard safe.count != variants.count else { return entry }
        extensionLog("[VideoLibrary] Dropped \(variants.count - safe.count) unsafe variant(s) from \(entry.id)")
        var copy = entry
        copy.variants = safe.isEmpty ? nil : safe
        return copy
    }

    /// Update metadata for a video entry (e.g., after probing duration/fps/resolution).
    func updateMetadata(for id: String, duration: Double, fps: Double, resolution: CGSize) {
        lock.withLock { entries in
            guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
            entries[idx].duration = duration
            entries[idx].fps = fps
            entries[idx].resolution = resolution
        }
        let metadataURL = videosDir
            .appendingPathComponent(id)
            .appendingPathComponent("metadata.json")
        if let entry = entry(for: id) {
            try? JSONEncoder().encode(entry).write(to: metadataURL)
        }
        saveIndex(entries)
    }

    // MARK: - Thumbnail Generation

    /// Generate a JPEG thumbnail for a video entry, saved alongside the video.
    func generateThumbnail(for entry: VideoEntry) async -> URL? {
        let url = videoURL(for: entry)
        let thumbnailURL = videosDir
            .appendingPathComponent(entry.id)
            .appendingPathComponent("thumbnail.jpg")

        if FileManager.default.fileExists(atPath: thumbnailURL.path) {
            return thumbnailURL
        }

        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 270)

        let cgImage: CGImage
        do {
            cgImage = try await generator.image(at: .zero).image
        } catch {
            extensionLog("[VideoLibrary] Thumbnail failed for \(entry.id): \(error)")
            return nil
        }

        guard let dest = CGImageDestinationCreateWithURL(
            thumbnailURL as CFURL, "public.jpeg" as CFString, 1, nil,
        ) else { return nil }
        CGImageDestinationAddImage(dest, cgImage, [
            kCGImageDestinationLossyCompressionQuality: 0.85,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }

        return thumbnailURL
    }

    // MARK: - Private

    private func saveIndex(_ entries: [VideoEntry]) {
        try? JSONEncoder().encode(entries).write(to: indexURL, options: .atomic)
    }

    private func findVideoFile(in directory: URL) -> URL? {
        let extensions = ["mp4", "mov", "m4v"]
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil,
        ) else { return nil }
        return contents.first { file in
            extensions.contains(file.pathExtension.lowercased())
        }
    }

    /// Migrate legacy single-file `wallpaper.{mp4,mov,m4v}` from Documents root into the library.
    private func migrateLegacyVideo() {
        let docs = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents")
        let extensions = ["mp4", "mov", "m4v"]
        let fm = FileManager.default

        for ext in extensions {
            let legacyURL = docs.appendingPathComponent("wallpaper.\(ext)")
            guard fm.fileExists(atPath: legacyURL.path) else { continue }

            let id = UUID().uuidString
            let dir = videosDir.appendingPathComponent(id)
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                let destURL = dir.appendingPathComponent("wallpaper.\(ext)")
                try fm.moveItem(at: legacyURL, to: destURL)

                let entry = VideoEntry(
                    id: id,
                    name: "Wallpaper",
                    filename: "wallpaper.\(ext)",
                    duration: 0,
                    fps: 0,
                    resolution: .zero,
                    dateAdded: Date(),
                )
                let metadataURL = dir.appendingPathComponent("metadata.json")
                try JSONEncoder().encode(entry).write(to: metadataURL)
                extensionLog("[VideoLibrary] Migrated legacy wallpaper.\(ext) → \(id)")
            } catch {
                extensionLog("[VideoLibrary] Migration failed: \(error)")
                try? fm.removeItem(at: dir)
            }
            break
        }
    }
}
