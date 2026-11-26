import AVFoundation
import Foundation
import ImageIO
import os

struct VideoEntry: Codable {
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

final class VideoLibrary: Sendable {
    static let shared = VideoLibrary()

    let videosDir: URL
    private let indexURL: URL
    private let lock = OSAllocatedUnfairLock(initialState: [VideoEntry]())

    init(documents: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents")) {
        self.videosDir = documents.appendingPathComponent("videos")
        self.indexURL = documents.appendingPathComponent("library.json")
        try? FileManager.default.createDirectory(at: videosDir, withIntermediateDirectories: true)
    }

    // MARK: - Public API

    /// The choices offered by the picker and shuffle. A pair keeps its owner's ID.
    var entries: [VideoEntry] {
        choices.map(\.entry)
    }

    var choices: [(entry: VideoEntry, pair: AppearancePair?)] {
        let physical = lock.withLock { $0 }
        let ids = Set(physical.map(\.id))
        let pairs = (try? AppearancePair.read(in: videosDir)) ?? []
        let membership = Dictionary(uniqueKeysWithValues: pairs.flatMap { [($0.owner, $0), ($0.counterpart, $0)] })
        return physical.compactMap { entry in
            let pair = membership[entry.id]
            if let pair {
                guard pair.deletionPending != true, entry.id == pair.owner || !ids.contains(pair.owner) else { return nil }
            }
            return (entry, pair)
        }
    }

    func pairRendition(for id: String) -> PairRendition? {
        guard let pair = try? AppearancePair.read(in: videosDir).first(where: { $0.contains(id) }) else { return nil }
        return PairRendition(pair, library: self)
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

    /// A selected pair keeps its choice ID when only the other member survives.
    func videoURL(for id: String) -> URL? {
        if let entry = entry(for: id) {
            return videoURL(for: entry)
        }
        guard let pair = try? AppearancePair.read(in: videosDir).first(where: { $0.contains(id) }),
              pair.deletionPending != true,
              let survivor = entry(for: id == pair.owner ? pair.counterpart : pair.owner) else { return nil }
        let url = videoURL(for: survivor)
        return isLocalVideo(url) ? url : nil
    }

    func isChoiceDownloaded(_ id: String) -> Bool {
        guard let original = videoURL(for: id), isLocalVideo(original) else { return false }
        let pair = (try? AppearancePair.read(in: videosDir))?.first { $0.contains(id) }
        return pair?.deletionPending != true
    }

    func removeDownloadedChoice(_ id: String, files: [URL]) throws {
        guard PathSafety.isValidEntryID(id) else { throw CocoaError(.fileWriteInvalidFileName) }
        guard files.allSatisfy(\.isFileURL) else { throw PairIssue.changed }
        let paths = files.map(\.standardizedFileURL.path)

        try AppearancePair.withLibraryLock(in: videosDir) {
            let pairs = try AppearancePair.read(in: videosDir)
            let selected = try currentVideoURL(for: id)
            if let pair = pairs.first(where: { $0.contains(id) }) {
                guard pair.deletionPending != true, let selected else { throw PairIssue.changed }
                let original = id == pair.owner ? selected : try currentVideoURL(for: pair.owner, allowMissingMedia: true)
                let alternate = id == pair.counterpart ? selected : try currentVideoURL(for: pair.counterpart, allowMissingMedia: true)
                if let original, let alternate,
                   PairRendition.Playback(original: original, alternate: alternate, validation: pair.validation) != nil {
                    guard id == pair.owner, paths == [original, alternate].map(\.standardizedFileURL.path) else { throw PairIssue.changed }
                    try pair.removeWhileLocked(in: videosDir, pairs: pairs)
                    return
                }
                guard id == (original == nil ? pair.counterpart : pair.owner),
                      paths == [selected.standardizedFileURL.path], let identity = FileIdentity(of: selected) else { throw PairIssue.changed }
                try pair.removeDegradedWhileLocked(id, media: identity, in: videosDir, pairs: pairs)
                return
            }
            guard let selected else { return }
            guard paths.isEmpty || paths == [selected.standardizedFileURL.path] else { throw PairIssue.changed }
            try FileManager.default.removeItem(at: selected.deletingLastPathComponent())
        }
    }

    /// Resolve current metadata under the library lock, since the scanned index can predate a replacement.
    private func currentVideoURL(for id: String, allowMissingMedia: Bool = false) throws -> URL? {
        let directory = videosDir.appendingPathComponent(id)
        guard let attributes = try PathSafety.attributes(at: directory) else { return nil }
        let metadata = directory.appendingPathComponent("metadata.json")
        guard attributes[.type] as? FileAttributeType == .typeDirectory, PathSafety.contained(directory, in: videosDir),
              try PathSafety.attributes(at: metadata)?[.type] as? FileAttributeType == .typeRegular else { throw PairIssue.changed }
        let entry = try JSONDecoder().decode(VideoEntry.self, from: Data(contentsOf: metadata))
        guard entry.id == id, PathSafety.isSafeComponent(entry.filename) else { throw PairIssue.changed }
        let url = videoURL(for: entry)
        let media = try PathSafety.attributes(at: url)
        if media == nil, allowMissingMedia {
            return nil
        }
        guard media?[.type] as? FileAttributeType == .typeRegular else { throw PairIssue.changed }
        return url
    }

    func legacySnapshotOriginal(_ url: URL, for choice: String) -> URL? {
        guard videoURL(for: choice) == url, isLocalVideo(url),
              (try? AppearancePair.requireSingle(choice, in: videosDir)) != nil else { return nil }
        return url
    }

    private func isLocalVideo(_ url: URL) -> Bool {
        PathSafety.contained(url, in: videosDir) && PathSafety.isItem(at: url, ofType: .typeRegular)
    }

    /// URL to a specific variant file within an entry's directory.
    func variantURL(for entryId: String, variant: VideoVariant) -> URL {
        videosDir
            .appendingPathComponent(entryId)
            .appendingPathComponent(variant.filename)
    }

    /// Select the best variant URL for a given playback policy (selection rules
    /// in `VariantSelection`). Falls back to the original file URL when the policy
    /// resolves to no variant. Returns `nil` only if the entry doesn't exist.
    func bestVariantURL(for id: String, policy: PlaybackPolicy) -> URL? {
        guard let entry = entry(for: id) else { return nil }
        guard policy != .paused, let sourceFPS = Int(exactly: entry.fps.rounded()), sourceFPS > 0, let chosen = VariantSelection.variant(
            for: policy,
            sourceIsHDR: entry.sourceIsHDR,
            sourceFPS: sourceFPS,
            variants: availableVariants(for: entry),
        ) else {
            return videoURL(for: entry)
        }
        return variantURL(for: id, variant: chosen)
    }

    func hasPlayableVariant(_ url: URL, for id: String) -> Bool {
        guard let entry = entry(for: id) else { return false }
        return availableVariants(for: entry).contains {
            $0.supports(sourceIsHDR: entry.sourceIsHDR) && variantURL(for: id, variant: $0) == url
        }
    }

    private func availableVariants(for entry: VideoEntry) -> [VideoVariant] {
        guard let variants = entry.variants, !variants.isEmpty,
              (try? AppearancePair.requireSingle(entry.id, in: videosDir)) != nil else { return [] }
        let directory = videosDir.appendingPathComponent(entry.id)
        return variants.filter { $0.isAvailable(in: directory, library: videosDir) }
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
    @discardableResult
    func scan() -> Bool {
        for pair in (try? AppearancePair.read(in: videosDir)) ?? [] where pair.deletionPending == true {
            do {
                try pair.finishDeletion(in: videosDir)
            } catch {
                extensionLog("[VideoLibrary] Could not finish deleting pair \(pair.owner): \(error)")
            }
        }

        do {
            try AppearancePair.withLibraryLock(in: videosDir) {
                migrateLegacyVideo()
                try scanEntries()
            }
            return true
        } catch {
            extensionLog("[VideoLibrary] Scan failed: \(error)")
            return false
        }
    }

    /// Read, prune and publish one index while replacements are excluded.
    private func scanEntries() throws {
        var discovered = [VideoEntry]()
        let fm = FileManager.default
        let subdirs = try fm.contentsOfDirectory(at: videosDir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
        let pending = Set(((try? AppearancePair.read(in: videosDir)) ?? []).filter { $0.deletionPending == true }
            .flatMap { [$0.owner, $0.counterpart] })
        for dir in subdirs where dir.hasDirectoryPath && !pending.contains(dir.lastPathComponent) {
            let id = dir.lastPathComponent

            // Quarantine anything that isn't a well-formed entry directory.
            // Skip (never delete) so a corrupt or hand-edited library can't make
            // a stray name drive a removal outside the tree.
            guard PathSafety.isValidEntryID(id) else {
                extensionLog("[VideoLibrary] Skipping non-UUID directory: \(id)")
                continue
            }

            let metadataURL = dir.appendingPathComponent("metadata.json")

            let entry: VideoEntry?
            do {
                let data = try Data(contentsOf: metadataURL)
                entry = try? JSONDecoder().decode(VideoEntry.self, from: data)
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                entry = nil
            } catch {
                extensionLog("[VideoLibrary] Could not read metadata for \(id): \(error)")
                continue
            }
            if let entry {
                // Metadata id must match its containing directory, and the
                // filename must be a safe basename that resolves inside `dir`.
                guard entry.id == id, PathSafety.isSafeComponent(entry.filename) else {
                    extensionLog("[VideoLibrary] Quarantining \(id): metadata id/filename mismatch or unsafe")
                    continue
                }
                let videoFile = dir.appendingPathComponent(entry.filename)
                do {
                    guard try PathSafety.attributes(at: videoFile) != nil else {
                        try pruneMetadataOnlyOrphan(in: dir, metadataURL: metadataURL)
                        continue
                    }
                } catch {
                    extensionLog("[VideoLibrary] Could not inspect video for \(id): \(error)")
                    continue
                }
                guard PathSafety.contained(videoFile, in: videosDir) else {
                    extensionLog("[VideoLibrary] Quarantining \(id): video path escapes library")
                    continue
                }
                discovered.append(sanitizingVariants(entry))
            } else {
                do {
                    if let recovered = try recoverEntry(in: dir, metadataURL: metadataURL) {
                        discovered.append(recovered)
                    }
                } catch {
                    extensionLog("[VideoLibrary] Could not inspect directory \(id): \(error)")
                }
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
        generator.dynamicRangePolicy = .forceSDR
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

    private func pruneMetadataOnlyOrphan(in directory: URL, metadataURL: URL) throws {
        guard PathSafety.contained(directory, in: videosDir), PathSafety.isItem(at: directory, ofType: .typeDirectory),
              PathSafety.isItem(at: metadataURL, ofType: .typeRegular),
              try FileManager.default.contentsOfDirectory(atPath: directory.path) == [metadataURL.lastPathComponent],
              unsafe unlink(metadataURL.path) == 0, unsafe rmdir(directory.path) == 0 else { return }
        extensionLog("[VideoLibrary] Pruned orphaned entry \(directory.lastPathComponent): video file missing")
    }

    private func recoverEntry(in directory: URL, metadataURL: URL) throws -> VideoEntry? {
        let extensions = ["mp4", "mov", "m4v"]
        let id = directory.lastPathComponent
        let contents = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        guard let videoFile = contents.first(where: { extensions.contains($0.pathExtension.lowercased()) && isLocalVideo($0) }) else {
            if contents.isEmpty, unsafe rmdir(directory.path) == 0 {
                extensionLog("[VideoLibrary] Pruning empty directory \(id): no video file found")
            }
            return nil
        }
        let entry = VideoEntry(
            id: id,
            name: videoFile.deletingPathExtension().lastPathComponent,
            filename: videoFile.lastPathComponent,
            duration: 0,
            fps: 0,
            resolution: .zero,
            dateAdded: Date(),
        )
        try? JSONEncoder().encode(entry).write(to: metadataURL)
        return entry
    }

    /// Migrate legacy single-file `wallpaper.{mp4,mov,m4v}` from Documents root into the library.
    private func migrateLegacyVideo() {
        let docs = indexURL.deletingLastPathComponent()
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
