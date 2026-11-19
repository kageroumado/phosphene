import AppKit
import AVFoundation
import Foundation
import os

enum VideoDeploymentService {
    /// Extension container where the wallpaper extension looks for video files.
    private static let extensionDocsURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Containers/glass.kagerou.phosphene.extension/Data/Documents", isDirectory: true)

    /// The library folder holding one subfolder per video (media + metadata + thumbnail).
    static let videosFolderURL = extensionDocsURL.appendingPathComponent("videos", isDirectory: true)

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
            _ = try await stageEntry(
                from: url,
                in: dir,
                id: id,
                name: name ?? VideoDisplayName.pretty(from: url.deletingPathExtension().lastPathComponent),
                filename: url.lastPathComponent,
            )

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

    @concurrent
    private static func stageEntry(
        from url: URL,
        in directory: URL,
        id: String,
        name: String,
        filename: String,
        requiresThumbnail: Bool = false,
    ) async throws -> URL {
        let source = url.resolvingSymlinksInPath()
        guard url.isFileURL, PathSafety.isItem(at: source, ofType: .typeRegular),
              PathSafety.isSafeComponent(filename) else { throw CocoaError(.fileReadInvalidFileName) }
        let video = directory.appendingPathComponent(filename)
        try FileManager.default.copyItem(at: source, to: video)
        let probe = await VideoProbe.inspect(video)
        guard let resolution = probe.resolution else { throw CocoaError(.fileReadCorruptFile) }
        let metadata = EntryInfo(
            id: id, name: name, filename: filename, duration: probe.duration ?? 0, fps: probe.fps ?? 0,
            resolution: resolution, dateAdded: Date(), sourceIsHDR: probe.isHDR,
        )
        try JSONEncoder().encode(metadata).write(to: directory.appendingPathComponent("metadata.json"))
        if requiresThumbnail {
            try await writeThumbnail(for: video, in: directory)
        } else {
            await generateThumbnail(for: video, in: directory)
        }
        return video
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
            try AppearancePair.withLibraryLock(in: videosFolderURL) {
                try AppearancePair.requireSingle(entryID, in: videosFolderURL)
                guard unsafe renamex_np(staged.path, dir.path, UInt32(RENAME_SWAP)) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            }
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

    /// Import fresh copies of the conversion outputs as a single video or a validated pair.
    @MainActor
    static func importConversion(light: URL, dark: URL?, name: String) async throws {
        try Task.checkCancellation()
        let fm = FileManager.default
        let library = videosFolderURL
        let staging = library.appendingPathComponent(".import-conversion-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: library, withIntermediateDirectories: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) }

        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = trimmed.isEmpty ? String(localized: "Converted Video") : trimmed
        func stage(_ output: URL, name: String) async throws -> URL {
            try Task.checkCancellation()
            let id = UUID().uuidString
            let directory = staging.appendingPathComponent(id, isDirectory: true)
            try fm.createDirectory(at: directory, withIntermediateDirectories: false)
            let ext = output.pathExtension
            let filename = ext.isEmpty ? id : "\(id).\(ext)"
            return try await stageEntry(from: output, in: directory, id: id, name: name, filename: filename, requiresThumbnail: true)
        }

        let first = try await stage(light, name: dark == nil ? title : String(localized: "\(title) (Light)"))
        var moved: [(from: URL, to: URL)] = []
        func publish(_ video: URL) throws -> URL {
            try Task.checkCancellation()
            let from = video.deletingLastPathComponent()
            let to = library.appendingPathComponent(from.lastPathComponent, isDirectory: true)
            guard unsafe renamex_np(from.path, to.path, UInt32(RENAME_EXCL)) == 0 else {
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
            moved.append((from, to))
            return to.appendingPathComponent(video.lastPathComponent)
        }

        if let dark {
            let second = try await stage(dark, name: String(localized: "\(title) (Dark)"))
            let validation = try await PairEligibility.validate(first, second)
            let pair = AppearancePair(
                owner: first.deletingLastPathComponent().lastPathComponent,
                counterpart: second.deletingLastPathComponent().lastPathComponent,
                swapped: false, validation: validation, name: title,
            )
            try pair.merge(in: library, onFailure: {
                for (from, to) in moved.reversed() {
                    if unsafe renamex_np(to.path, from.path, UInt32(RENAME_EXCL)) != 0 {
                        do {
                            try fm.removeItem(at: to)
                        } catch {
                            Log.video.error("Failed to roll back conversion import at \(to.lastPathComponent): \(error.localizedDescription)")
                        }
                    }
                }
            }) {
                let original = try publish(first)
                let alternate = try publish(second)
                try Task.checkCancellation()
                return (original, alternate)
            }
        } else {
            try AppearancePair.withLibraryLock(in: library) {
                _ = try publish(first)
            }
        }
        notifyExtensionLibraryChanged()
    }

    /// Deploy optimized variants into an existing entry's directory in the extension container.
    /// Updates metadata.json with the variants array and notifies the extension.
    @MainActor
    static func deployVariants(entryID: String, source: FileIdentity, variants: [(url: URL, variant: VideoVariant)]) throws {
        guard !variants.isEmpty else { return }
        try publishVariants(entryID: entryID, source: source, variants: variants)
        notifyExtensionLibraryChanged()
    }

    /// Remove variant files and clear the variants array in metadata for an entry.
    @MainActor
    static func removeVariants(entryID: String) throws {
        try publishVariants(entryID: entryID, source: nil, variants: [])
        Log.video.info("Removed variants for entry \(entryID)")
        notifyExtensionLibraryChanged()
    }

    private static func publishVariants(entryID: String, source: FileIdentity?, variants: [(url: URL, variant: VideoVariant)]) throws {
        let fm = FileManager.default
        guard let dir = validatedEntryDir(entryID) else { throw CocoaError(.fileWriteInvalidFileName) }
        try AppearancePair.withLibraryLock(in: videosFolderURL) {
            try AppearancePair.requireSingle(entryID, in: videosFolderURL)
            let stagingPrefix = ".single-variants-"
            PathSafety.pruneDirectories(in: videosFolderURL, prefix: stagingPrefix)
            var metadata = try variantEntry(entryID, in: dir, matching: source)
            let incoming = variants.map(\.variant)
            let protected = [metadata.filename, "metadata.json", "thumbnail.jpg", workshopRecordName]
            func isVariantName(_ name: String) -> Bool {
                PathSafety.isSafeComponent(name) && !name.hasPrefix(".") &&
                    !protected.contains { name.caseInsensitiveCompare($0) == .orderedSame }
            }
            guard incoming.allSatisfy({ isVariantName($0.filename) }) else { throw CocoaError(.fileWriteInvalidFileName) }
            guard incoming.allSatisfy({ variant in
                switch metadata.sourceIsHDR {
                case true?: variant.isHDR == true || (variant.isHDR == false && variant.toneMappedToSDR == true)
                case false?: variant.isHDR != true && variant.toneMappedToSDR != true
                case nil: false
                }
            }) else { throw VideoOptimizationService.OptimizationError.unsupportedDynamicRange }

            let staging = videosFolderURL.appendingPathComponent(stagingPrefix + UUID().uuidString, isDirectory: true)
            try fm.createDirectory(at: staging, withIntermediateDirectories: false)
            defer { try? fm.removeItem(at: staging) }
            for (url, variant) in variants {
                guard url.isFileURL, PathSafety.isItem(at: url, ofType: .typeRegular),
                      let identity = FileIdentity(of: url) else { throw CocoaError(.fileWriteInvalidFileName) }
                let target = staging.appendingPathComponent(variant.filename)
                try fm.copyItem(at: url, to: target)
                guard PathSafety.isItem(at: target, ofType: .typeRegular),
                      FileIdentity(of: url) == identity else { throw PairIssue.changed }
            }

            let retired = Set((metadata.variants ?? []).map(\.filename).filter(isVariantName))
            for file in try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                let name = file.lastPathComponent
                if name == "metadata.json" || (retired.contains(name) && PathSafety.isItem(at: file, ofType: .typeRegular)) {
                    continue
                }
                try fm.linkItem(at: file, to: staging.appendingPathComponent(name))
            }
            metadata.variants = incoming.isEmpty ? nil : incoming
            try JSONEncoder().encode(metadata).write(to: staging.appendingPathComponent("metadata.json"))
            if let source {
                guard FileIdentity(of: videoURL(for: metadata)) == source,
                      FileIdentity(of: staging.appendingPathComponent(metadata.filename)) == source else { throw PairIssue.changed }
            }
            // Keep the source inode and publish the variant files and metadata together.
            guard unsafe renamex_np(staging.path, dir.path, UInt32(RENAME_SWAP)) == 0 else {
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
        }
    }

    private static func variantEntry(_ id: String, in directory: URL, matching expected: FileIdentity?) throws -> EntryInfo {
        let metadataURL = directory.appendingPathComponent("metadata.json")
        guard PathSafety.isItem(at: directory, ofType: .typeDirectory),
              PathSafety.isItem(at: metadataURL, ofType: .typeRegular) else { throw PairIssue.changed }
        let entry = try JSONDecoder().decode(EntryInfo.self, from: Data(contentsOf: metadataURL))
        guard entry.id == id, PathSafety.isSafeComponent(entry.filename) else { throw PairIssue.changed }
        if let expected {
            let url = videoURL(for: entry)
            guard expected.basename == entry.filename, PathSafety.isItem(at: url, ofType: .typeRegular),
                  FileIdentity(of: url) == expected else { throw PairIssue.changed }
        }
        return entry
    }

    static func deployPairVariants(
        pair: AppearancePair,
        directory: URL,
        tiers: [AppearancePair.Tier],
        convertToSDR: Bool,
    ) throws {
        try pair.deployOptimization(from: directory, tiers: tiers, convertToSDR: convertToSDR, in: videosFolderURL) { current in
            guard let owner = validatedEntryDir(current.owner), let counterpart = validatedEntryDir(current.counterpart) else {
                throw PairIssue.changed
            }
            _ = try variantEntry(current.owner, in: owner, matching: current.validation.original)
            _ = try variantEntry(current.counterpart, in: counterpart, matching: current.validation.alternate)
        }
        notifyExtensionLibraryChanged()
    }

    static func removePairVariants(_ pair: AppearancePair) throws {
        try pair.removeOptimization(in: videosFolderURL)
        notifyExtensionLibraryChanged()
    }

    static func removePair(_ pair: AppearancePair) throws {
        try pair.remove(in: videosFolderURL)
        notifyExtensionLibraryChanged()
    }

    /// Remove a video entry from the extension container.
    static func removeVideo(entryID: String) throws {
        guard let dir = validatedEntryDir(entryID) else { throw CocoaError(.fileWriteInvalidFileName) }
        try AppearancePair.withLibraryLock(in: videosFolderURL) {
            try AppearancePair.requireSingle(entryID, in: videosFolderURL)
            do {
                try FileManager.default.removeItem(at: dir)
            } catch let error as CocoaError where error.code == .fileNoSuchFile {
                // A stale selection may refer to a library copy that has already been deleted.
            }
        }
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
            guard entry.id == dir.lastPathComponent, PathSafety.isValidEntryID(entry.id),
                  PathSafety.isSafeComponent(entry.filename), PathSafety.contained(dir, in: videosDir),
                  PathSafety.contained(videoFile, in: dir), fm.fileExists(atPath: videoFile.path) else { continue }

            entries.append(entry)
        }

        return entries.sorted { $0.dateAdded < $1.dateAdded }
    }

    static func thumbnailURL(for entryID: String) -> URL {
        videosFolderURL
            .appendingPathComponent(entryID, isDirectory: true)
            .appendingPathComponent("thumbnail.jpg", isDirectory: false)
    }

    /// URL to the video file for an entry.
    static func videoURL(for entry: EntryInfo) -> URL {
        videosFolderURL
            .appendingPathComponent(entry.id, isDirectory: true)
            .appendingPathComponent(entry.filename, isDirectory: false)
    }

    /// Rename a source video without changing its filename.
    static func renameEntry(entryID: String, to newName: String) throws {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let entryDir = validatedEntryDir(entryID) else { throw CocoaError(.fileWriteInvalidFileName) }
        let metadataURL = entryDir.appendingPathComponent("metadata.json")
        try AppearancePair.withLibraryLock(in: videosFolderURL) {
            let data = try Data(contentsOf: metadataURL)
            var metadata = try JSONDecoder().decode(EntryInfo.self, from: data)
            guard metadata.id == entryID else { throw CocoaError(.fileReadCorruptFile) }
            metadata.name = trimmed
            try JSONEncoder().encode(metadata).write(to: metadataURL, options: .atomic)
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
            do {
                try renameEntry(entryID: entry.id, to: pretty)
                changed = true
            } catch {
                Log.video.error("Could not rename \(entry.id): \(error.localizedDescription)")
            }
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
    @concurrent
    static func generateThumbnail(for videoURL: URL, in directory: URL) async {
        do {
            try await writeThumbnail(for: videoURL, in: directory)
        } catch {
            Log.video.error("Thumbnail generation failed: \(error.localizedDescription)")
        }
    }

    @concurrent
    private static func writeThumbnail(for videoURL: URL, in directory: URL) async throws {
        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.dynamicRangePolicy = .forceSDR
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 360)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        let cgImage = try await generator.image(at: .zero).image
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let jpegData = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else {
            throw CocoaError(.fileWriteUnknown)
        }

        let thumbnailURL = directory.appendingPathComponent("thumbnail.jpg")
        try jpegData.write(to: thumbnailURL, options: .atomic)
    }

    static func notifyExtensionLibraryChanged() {
        refreshWallpaperPicker(notifying: "glass.kagerou.phosphene.libraryChanged")
        NotificationCenter.default.post(name: libraryChangedNotification, object: nil)
    }

    static func refreshWallpaperPicker(notifying notification: String = "glass.kagerou.phosphene.pickerChanged") {
        invalidateHostViewModelCache()
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(
            center,
            CFNotificationName(notification as CFString),
            nil,
            nil,
            true,
        )
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
        guard length > 0, length <= buf.count else { return }
        let pathBytes = buf.prefix(length - 1).map { UInt8(bitPattern: $0) }
        guard let path = String(bytes: pathBytes, encoding: .utf8) else { return }
        let cacheDir = URL(fileURLWithPath: path)
            .appendingPathComponent("com.apple.wallpaper.agent/com.apple.wallpaper.view-model-cache")
        for surface in ["desktop", "screenSaver"] {
            let file = cacheDir
                .appendingPathComponent("extension-glass.kagerou.phosphene.extension-\(surface)")
            try? FileManager.default.removeItem(at: file)
        }
    }
}
