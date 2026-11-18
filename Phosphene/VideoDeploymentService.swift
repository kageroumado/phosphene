import AppKit
import AVFoundation
import Foundation
import os

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
    /// Returns the new entry's id.
    @MainActor
    @discardableResult
    static func deployVideo(url: URL, name: String? = nil, onError: ((any Error) -> Void)? = nil) async -> String? {
        let fileManager = FileManager.default
        let videosDir = videosFolderURL

        // Dedup: skip if a video with the same filename already exists in the library
        if listEntries().contains(where: { $0.filename == url.lastPathComponent }) {
            Log.video.info("Video '\(url.lastPathComponent)' already in library, skipping deploy")
            return nil
        }

        let id = UUID().uuidString
        let dir = videosDir.appendingPathComponent(".import-" + id)

        do {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            let destURL = dir.appendingPathComponent(url.lastPathComponent)
            try fileManager.copyItem(at: url.resolvingSymlinksInPath(), to: destURL)

            let probe = await VideoProbe.inspect(destURL)
            guard probe.resolution != nil else { throw CocoaError(.fileReadCorruptFile) }
            let metadata = EntryInfo(
                id: id,
                name: name ?? VideoDisplayName.pretty(from: url.deletingPathExtension().lastPathComponent),
                filename: url.lastPathComponent,
                duration: probe.duration ?? 0,
                fps: probe.fps ?? 0,
                resolution: probe.resolution ?? .zero,
                dateAdded: Date(),
                sourceIsHDR: probe.isHDR,
            )
            let data = try JSONEncoder().encode(metadata)
            try data.write(to: dir.appendingPathComponent("metadata.json"))

            await generateThumbnail(for: destURL, in: dir)

            if listEntries().contains(where: { $0.filename == url.lastPathComponent }) {
                try fileManager.removeItem(at: dir)
                return nil
            }
            try fileManager.moveItem(at: dir, to: videosDir.appendingPathComponent(id))
            Log.video.info("Deployed video '\(url.lastPathComponent)' as \(id)")
            notifyExtensionLibraryChanged()
            return id
        } catch {
            Log.video.error("Failed to deploy video: \(error.localizedDescription)")
            try? fileManager.removeItem(at: dir)
            onError?(error)
            return nil
        }
    }

    /// Swap an entry's video for `url`, keeping its id, name and the wallpaper
    /// selections that point at it. Variants of the old video are removed.
    @MainActor
    @discardableResult
    static func replaceVideo(entryID: String, with url: URL) async -> Bool {
        guard let dir = validatedEntryDir(entryID), PathSafety.isSafeComponent(url.lastPathComponent) else { return false }
        let fm = FileManager.default
        let metadataURL = dir.appendingPathComponent("metadata.json")
        guard let old = try? JSONDecoder().decode(EntryInfo.self, from: Data(contentsOf: metadataURL)),
              old.id == entryID, PathSafety.isSafeComponent(old.filename),
              let identity = FileIdentity(of: dir.appendingPathComponent(old.filename)) else { return false }

        let staged = videosFolderURL.appendingPathComponent(".replace-" + UUID().uuidString)
        let media = staged.appendingPathComponent(url.lastPathComponent)
        defer { try? fm.removeItem(at: staged) }
        do {
            try fm.createDirectory(at: staged, withIntermediateDirectories: false)
            try fm.copyItem(at: url.resolvingSymlinksInPath(), to: media)
            let probe = await VideoProbe.inspect(media)
            guard probe.resolution != nil else { throw CocoaError(.fileReadCorruptFile) }
            await generateThumbnail(for: media, in: staged)

            var current = try JSONDecoder().decode(EntryInfo.self, from: Data(contentsOf: metadataURL))
            guard current.filename == old.filename, current.id == entryID,
                  FileIdentity(of: dir.appendingPathComponent(current.filename)) == identity else { return false }
            let retired = Set((current.variants ?? []).map(\.filename) + [current.filename, "thumbnail.jpg", "metadata.json"])
            for file in try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) where !retired.contains(file.lastPathComponent) {
                try fm.linkItem(at: file, to: staged.appendingPathComponent(file.lastPathComponent))
            }
            current.filename = media.lastPathComponent
            current.sourceIsHDR = probe.isHDR
            current.fps = probe.fps ?? 0
            current.resolution = probe.resolution ?? .zero
            current.duration = probe.duration ?? 0
            current.variants = nil
            try JSONEncoder().encode(current).write(to: staged.appendingPathComponent("metadata.json"))
            // Publish media and metadata together. Open readers can finish on their old inodes.
            guard unsafe renamex_np(staged.path, dir.path, UInt32(RENAME_SWAP)) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        } catch {
            Log.video.error("Failed to replace video for \(entryID): \(error.localizedDescription)")
            return false
        }
        notifyExtensionLibraryChanged()
        return true
    }

    // MARK: - Wallpaper Engine provenance

    /// `workshop.json` beside an entry made from a Wallpaper Engine wallpaper. The
    /// extension never reads it, and it goes when the entry's folder goes, so the
    /// library's "already made" state cannot outlive the video.
    private static let workshopRecordName = "workshop.json"

    static func writeWorkshopRecord(_ record: WorkshopRecord, entryID: String) {
        guard let dir = validatedEntryDir(entryID), let data = try? JSONEncoder().encode(record) else { return }
        try? data.write(to: dir.appendingPathComponent(workshopRecordName), options: .atomic)
    }

    /// Workshop item id → the entry made from it and how.
    static func workshopRecords() -> [String: (entryID: String, record: WorkshopRecord)] {
        var records: [String: (entryID: String, record: WorkshopRecord)] = [:]
        for entry in listEntries() {
            let url = videosFolderURL.appendingPathComponent(entry.id).appendingPathComponent(workshopRecordName)
            guard let data = try? Data(contentsOf: url),
                  let record = try? JSONDecoder().decode(WorkshopRecord.self, from: data) else { continue }
            records[record.publishedFileID] = (entry.id, record)
        }
        return records
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
    static func deployVariants(entryID: String, source: FileIdentity, variants: [(url: URL, variant: VideoVariant)]) throws {
        guard !variants.isEmpty else { return }
        guard let dir = validatedEntryDir(entryID) else { throw CocoaError(.fileNoSuchFile) }
        let metadataURL = dir.appendingPathComponent("metadata.json")
        var metadata = try JSONDecoder().decode(EntryInfo.self, from: Data(contentsOf: metadataURL))
        guard metadata.id == entryID, metadata.filename == source.basename, metadata.sourceIsHDR == false,
              FileIdentity(of: dir.appendingPathComponent(metadata.filename)) == source else {
            throw VideoOptimizationService.OptimizationError.requiresSDR
        }
        for (url, variant) in variants {
            let target = dir.appendingPathComponent(variant.filename)
            guard PathSafety.isSafeComponent(variant.filename), variant.filename.caseInsensitiveCompare(metadata.filename) != .orderedSame,
                  PathSafety.contained(target, in: dir) else { throw CocoaError(.fileWriteInvalidFileName) }
            let incoming = dir.appendingPathComponent(".variant-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: incoming) }
            try FileManager.default.copyItem(at: url, to: incoming)
            guard unsafe rename(incoming.path, target.path) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        }
        metadata.variants = variants.map(\.variant)
        try JSONEncoder().encode(metadata).write(to: metadataURL, options: .atomic)
        notifyExtensionLibraryChanged()
    }

    /// Remove variant files and clear the variants array in metadata for an entry.
    @MainActor
    static func removeVariants(entryID: String) {
        guard let entryDir = validatedEntryDir(entryID) else { return }
        let metadataURL = entryDir.appendingPathComponent("metadata.json")
        let fm = FileManager.default

        guard let data = try? Data(contentsOf: metadataURL),
              var metadata = try? JSONDecoder().decode(EntryInfo.self, from: data)
        else { return }

        for variant in metadata.variants ?? [] {
            guard PathSafety.isSafeComponent(variant.filename), variant.filename.caseInsensitiveCompare(metadata.filename) != .orderedSame else { continue }
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
    nonisolated struct EntryInfo: Codable, Sendable {
        let id: String
        var name: String
        var filename: String
        var duration: Double
        var fps: Double
        var resolution: CGSize
        var dateAdded: Date
        var sourceIsHDR: Bool?
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
              var metadata = try? JSONDecoder().decode(EntryInfo.self, from: data),
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
    @MainActor
    static func probeAndUpdateMetadata(for entry: EntryInfo) async -> Bool {
        guard let dir = validatedEntryDir(entry.id), PathSafety.isSafeComponent(entry.filename) else { return false }
        let url = dir.appendingPathComponent(entry.filename)
        guard PathSafety.contained(url, in: dir), let identity = FileIdentity(of: url) else { return false }
        let probe = await VideoProbe.inspect(url)
        let metadataURL = dir.appendingPathComponent("metadata.json")
        guard identity == FileIdentity(of: url),
              var current = try? JSONDecoder().decode(EntryInfo.self, from: Data(contentsOf: metadataURL)),
              current.id == entry.id, current.filename == entry.filename else { return false }
        if probe.isHDR == nil {
            Log.video.info("Dynamic range unresolved for \(entry.id)")
        }
        let duration = probe.duration ?? current.duration
        let fps = probe.fps ?? current.fps
        let resolution = probe.resolution ?? current.resolution
        guard current.sourceIsHDR != probe.isHDR || current.duration != duration || current.fps != fps || current.resolution != resolution else { return false }
        current.sourceIsHDR = probe.isHDR
        current.duration = duration
        current.fps = fps
        current.resolution = resolution
        do {
            try JSONEncoder().encode(current).write(to: metadataURL, options: .atomic)
            return true
        } catch {
            Log.video.error("Failed to enrich \(entry.id): \(error.localizedDescription)")
            return false
        }
    }

    /// Notification posted in-process when the library changes.
    static let libraryChangedNotification = Notification.Name("glass.kagerou.phosphene.libraryChanged")

    /// Generate a thumbnail.jpg from the first frame of a video.
    /// Uses async/await so the caller can coordinate thumbnail availability.
    @MainActor
    static func generateThumbnail(for videoURL: URL, in directory: URL) async {
        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.dynamicRangePolicy = .forceSDR
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

    static func notifyExtensionLibraryChanged() {
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
