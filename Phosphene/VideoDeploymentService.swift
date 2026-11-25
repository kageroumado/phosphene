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
        let dir = videosDir.appendingPathComponent(".import-" + id, isDirectory: true)
        defer { try? fileManager.removeItem(at: dir) }

        do {
            try Task.checkCancellation()
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            _ = try await stageEntry(
                from: url,
                in: dir,
                id: id,
                name: name ?? VideoDisplayName.pretty(from: url.deletingPathExtension().lastPathComponent),
                filename: url.lastPathComponent,
            )

            let published = try AppearancePair.withLibraryLock(in: videosDir) {
                try Task.checkCancellation()
                guard !listEntries().contains(where: { $0.filename == url.lastPathComponent }) else { return false }
                try fileManager.moveItem(at: dir, to: videosDir.appendingPathComponent(id))
                return true
            }
            guard published else { return nil }
            Log.video.info("Deployed video '\(url.lastPathComponent)' as \(id)")
            notifyExtensionLibraryChanged()
            return id
        } catch {
            Log.video.error("Failed to deploy video: \(error.localizedDescription)")
            if !Task.isCancelled {
                onError?(error)
            }
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
              isMediaFilename(filename) else { throw CocoaError(.fileReadInvalidFileName) }
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
        do {
            try await replaceSingleVideo(entryID: entryID, with: url)
            return true
        } catch {
            Log.video.error("Failed to replace video for \(entryID): \(error.localizedDescription)")
            return false
        }
    }

    private static func replaceSingleVideo(
        entryID: String, with url: URL, matching expected: FileIdentity? = nil, preserveHDR: Bool = false,
    ) async throws {
        try Task.checkCancellation()
        let source = url.resolvingSymlinksInPath()
        guard let dir = validatedEntryDir(entryID), url.isFileURL,
              isMediaFilename(url.lastPathComponent), PathSafety.isItem(at: source, ofType: .typeRegular)
        else { throw CocoaError(.fileReadInvalidFileName) }
        try AppearancePair.requireSingle(entryID, in: videosFolderURL)
        let existing = try readEntry(entryID, in: dir, matching: expected)
        guard let identity = expected ?? FileIdentity(of: videoURL(for: existing)) else { throw PairIssue.changed }

        let fm = FileManager.default
        let staged = videosFolderURL.appendingPathComponent(".replace-" + UUID().uuidString, isDirectory: true)
        let media = staged.appendingPathComponent(url.lastPathComponent)
        try fm.createDirectory(at: staged, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staged) }
        try fm.copyItem(at: source, to: media)
        let probe = await VideoProbe.inspect(media)
        guard let resolution = probe.resolution else { throw CocoaError(.fileReadCorruptFile) }
        if preserveHDR, probe.isHDR != true {
            throw VideoOptimizationService.OptimizationError.encodingFailed("HEVC export did not preserve HDR")
        }
        await generateThumbnail(for: media, in: staged)

        try AppearancePair.withLibraryLock(in: videosFolderURL) {
            try Task.checkCancellation()
            try AppearancePair.requireSingle(entryID, in: videosFolderURL)
            var current = try readEntry(entryID, in: dir, matching: identity)
            let retired = Set((current.variants ?? []).map(\.filename) + [current.filename, "thumbnail.jpg", "metadata.json", ".media-replaced"])
            for file in try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) where !retired.contains(file.lastPathComponent) {
                try fm.linkItem(at: file, to: staged.appendingPathComponent(file.lastPathComponent))
            }
            current.filename = media.lastPathComponent
            current.sourceIsHDR = probe.isHDR
            current.fps = probe.fps ?? 0
            current.resolution = resolution
            current.duration = probe.duration ?? 0
            current.variants = nil
            try JSONEncoder().encode(current).write(to: staged.appendingPathComponent("metadata.json"))
            try Task.checkCancellation()
            try Data().write(to: staged.appendingPathComponent(".media-replaced"))
            // Publish media and metadata together. Open readers can finish on their old inodes.
            guard unsafe renamex_np(staged.path, dir.path, UInt32(RENAME_SWAP)) == 0 else {
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
        }
        notifyExtensionLibraryChanged()
    }

    private nonisolated static func isMediaFilename(_ name: String) -> Bool {
        PathSafety.isSafeComponent(name) && !["metadata.json", "thumbnail.jpg", ".media-replaced", workshopRecordName].contains(name.lowercased())
    }

    // MARK: - Wallpaper Engine provenance

    /// `workshop.json` beside an entry made from a Wallpaper Engine wallpaper. The
    /// extension never reads it, and it goes when the entry's folder goes, so the
    /// library's "already made" state cannot outlive the video.
    private nonisolated static let workshopRecordName = "workshop.json"

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

    // MARK: - HEVC conversion

    private enum Conversion {
        static let progressInterval: TimeInterval = 0.2
    }

    /// Re-encode an entry's video as HEVC in a `.mov` and swap it into the same entry
    /// with ``replaceVideo(entryID:with:)``, which keeps the id and the wallpaper
    /// selections and deletes the old file and its variants. The old file stays in
    /// place until the export has finished, so a failed or cancelled export leaves the
    /// entry as it was. The temporary export is removed on every path.
    ///
    /// - Parameter progress: Called with the export's completed fraction, 0...1.
    /// - Throws: `CancellationError` when the calling task is cancelled, the export's
    ///   error when it fails, or a `CocoaError` when the swap into the library fails.
    @MainActor
    static func convertToHEVC(entry: EntryInfo, progress: @escaping @MainActor (Double) -> Void) async throws {
        try Task.checkCancellation()
        try AppearancePair.requireSingle(entry.id, in: videosFolderURL)
        let source = videoURL(for: entry)
        guard let directory = validatedEntryDir(entry.id), isMediaFilename(entry.filename),
              PathSafety.isItem(at: source, ofType: .typeRegular), let identity = FileIdentity(of: source)
        else { throw CocoaError(.fileReadNoSuchFile) }
        _ = try readEntry(entry.id, in: directory, matching: identity)
        let stem = (entry.filename as NSString).deletingPathExtension
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hevc-\(UUID().uuidString)", isDirectory: true)
        let output = workDir.appendingPathComponent(stem).appendingPathExtension("mov")
        do {
            try await createDirectory(workDir)
            try await exportHEVC(from: source, to: output, progress: progress)
            try await replaceSingleVideo(entryID: entry.id, with: output, matching: identity, preserveHDR: entry.sourceIsHDR == true)
        } catch {
            await removeItem(workDir)
            throw error
        }
        await removeItem(workDir)
        Log.video.info("Converted entry \(entry.id) to HEVC")
    }

    @MainActor
    private static func exportHEVC(
        from source: URL,
        to output: URL,
        progress: @escaping @MainActor (Double) -> Void,
    ) async throws {
        guard let session = AVAssetExportSession(
            asset: AVURLAsset(url: source), presetName: AVAssetExportPresetHEVCHighestQuality,
        ) else {
            throw AVError(.exportFailed)
        }
        let monitor = Task(name: "HEVC export progress") {
            for await state in session.states(updateInterval: Conversion.progressInterval) {
                if case let .exporting(exportProgress) = state {
                    progress(exportProgress.fractionCompleted)
                }
            }
        }
        defer { monitor.cancel() }
        try await session.export(to: output, as: .mov)
        progress(1)
    }

    @concurrent
    private nonisolated static func createDirectory(_ url: URL) async throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    @concurrent
    private nonisolated static func removeItem(_ url: URL) async {
        try? FileManager.default.removeItem(at: url)
    }

    /// Deploy optimized variants into an existing entry's directory in the extension container.
    /// Updates metadata.json with the variants array and notifies the extension.
    @MainActor
    static func deployVariants(entryID: String, source: FileIdentity, sourceIsHDR: Bool, variants: [(url: URL, variant: VideoVariant)]) throws {
        try Task.checkCancellation()
        guard !variants.isEmpty else { return }
        try publishVariants(entryID: entryID, source: (source, sourceIsHDR), variants: variants)
        notifyExtensionLibraryChanged()
    }

    /// Remove variant files and clear the variants array in metadata for an entry.
    @MainActor
    static func removeVariants(entryID: String) throws {
        try publishVariants(entryID: entryID, source: nil, variants: [])
        Log.video.info("Removed variants for entry \(entryID)")
        notifyExtensionLibraryChanged()
    }

    private static func publishVariants(
        entryID: String, source: (identity: FileIdentity, isHDR: Bool)?, variants: [(url: URL, variant: VideoVariant)],
    ) throws {
        let fm = FileManager.default
        guard let dir = validatedEntryDir(entryID) else { throw CocoaError(.fileWriteInvalidFileName) }
        try AppearancePair.withLibraryLock(in: videosFolderURL) {
            try AppearancePair.requireSingle(entryID, in: videosFolderURL)
            let stagingPrefix = ".single-variants-"
            PathSafety.pruneDirectories(in: videosFolderURL, prefix: stagingPrefix)
            var metadata = try readEntry(entryID, in: dir, matching: source?.identity)
            let incoming = variants.map(\.variant)
            let protected = [metadata.filename, "metadata.json", "thumbnail.jpg", workshopRecordName]
            func isVariantName(_ name: String) -> Bool {
                PathSafety.isSafeComponent(name) && !name.hasPrefix(".") &&
                    !protected.contains { name.caseInsensitiveCompare($0) == .orderedSame }
            }
            guard incoming.allSatisfy({ isVariantName($0.filename) }) else { throw CocoaError(.fileWriteInvalidFileName) }
            if let source {
                guard incoming.allSatisfy({ $0.supportsPublication(verifiedSourceIsHDR: source.isHDR, recordedSourceIsHDR: metadata.sourceIsHDR) }) else {
                    throw VideoOptimizationService.OptimizationError.unsupportedDynamicRange
                }
                // Publish the source classification with the tiers that depend on it.
                metadata.sourceIsHDR = source.isHDR
            }

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
                guard FileIdentity(of: videoURL(for: metadata)) == source.identity,
                      FileIdentity(of: staging.appendingPathComponent(metadata.filename)) == source.identity else { throw PairIssue.changed }
            }
            try Task.checkCancellation()
            // Keep the source inode and publish the variant files and metadata together.
            guard unsafe renamex_np(staging.path, dir.path, UInt32(RENAME_SWAP)) == 0 else {
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
        }
    }

    private static func readEntry(_ id: String, in directory: URL, matching expected: FileIdentity?) throws -> EntryInfo {
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
            _ = try readEntry(current.owner, in: owner, matching: current.validation.original)
            _ = try readEntry(current.counterpart, in: counterpart, matching: current.validation.alternate)
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
    static func renameEntry(entryID: String, to newName: String) throws {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let entryDir = validatedEntryDir(entryID) else { throw CocoaError(.fileWriteInvalidFileName) }
        let metadataURL = entryDir.appendingPathComponent("metadata.json")
        let changed = try AppearancePair.withLibraryLock(in: videosFolderURL) {
            var metadata = try readEntry(entryID, in: entryDir, matching: nil)
            guard metadata.name != trimmed else { return false }
            metadata.name = trimmed
            try JSONEncoder().encode(metadata).write(to: metadataURL, options: .atomic)
            return true
        }
        if changed {
            notifyExtensionLibraryChanged()
        }
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
        do {
            return try AppearancePair.withLibraryLock(in: videosFolderURL) {
                var current = try readEntry(entry.id, in: dir, matching: identity)
                let duration = probe.duration ?? current.duration
                let fps = probe.fps ?? current.fps
                let resolution = probe.resolution ?? current.resolution
                let isHDR = probe.isHDR ?? current.sourceIsHDR
                guard current.sourceIsHDR != isHDR || current.duration != duration ||
                    current.fps != fps || current.resolution != resolution else { return false }
                current.sourceIsHDR = isHDR
                current.duration = duration
                current.fps = fps
                current.resolution = resolution
                try JSONEncoder().encode(current).write(to: metadataURL, options: .atomic)
                return true
            }
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
            await MainActor.run {
                Log.video.error("Thumbnail generation failed: \(error.localizedDescription)")
            }
        }
    }

    @concurrent
    private static func writeThumbnail(for videoURL: URL, in directory: URL) async throws {
        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.dynamicRangePolicy = .forceSDR
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 360)

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
        let cacheDir = URL(fileURLWithPath: String(decoding: pathBytes, as: UTF8.self))
            .appendingPathComponent("com.apple.wallpaper.agent/com.apple.wallpaper.view-model-cache")
        for surface in ["desktop", "screenSaver"] {
            let file = cacheDir
                .appendingPathComponent("extension-glass.kagerou.phosphene.extension-\(surface)")
            try? FileManager.default.removeItem(at: file)
        }
    }
}
