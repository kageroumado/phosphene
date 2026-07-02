import AppKit
import Foundation
import os

@MainActor
@Observable
final class WallpaperHistory {
    static let shared = WallpaperHistory()

    private(set) var items: [WallpaperHistoryItem] = []

    private let resourceManager = SecurityScopedResourceManager.shared
    private let maxItems = 10

    private init() {
        self.items = HistoryStorageService.loadHistory()
    }

    // MARK: - Public Methods

    func addWallpaper(
        name: String,
        videoURL: URL,
        bookmarkData: Data?,
        thumbnail: NSImage?,
        showAsScreenSaver: Bool,
        showOnAllSpaces: Bool,
    ) {
        let thumbnailData = compressThumbnail(thumbnail)

        let item = WallpaperHistoryItem(
            name: name,
            videoURL: videoURL,
            bookmarkData: bookmarkData,
            thumbnailData: thumbnailData,
            showAsScreenSaver: showAsScreenSaver,
            showOnAllSpaces: showOnAllSpaces,
        )

        // Remove any existing item with the same URL, then insert at front
        items.removeAll { $0.videoURL == videoURL }
        items.insert(item, at: 0)

        if items.count > maxItems {
            items = Array(items.prefix(maxItems))
        }

        HistoryStorageService.saveHistory(items)
    }

    func removeItem(_ item: WallpaperHistoryItem) {
        items.removeAll { $0.id == item.id }
        HistoryStorageService.saveHistory(items)
    }

    func clearHistory() {
        items.removeAll()
        HistoryStorageService.saveHistory(items)
    }

    // MARK: - Bookmark Resolution

    /// Resolve a history item's bookmark and request security-scoped access.
    func resolveAndAccessBookmark(for item: WallpaperHistoryItem) -> URL? {
        guard let bookmarkData = item.bookmarkData else { return nil }

        do {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale,
            )

            if isStale {
                Log.storage.warning("Bookmark is stale for: \(item.name)")
            }

            if resourceManager.requestAccess(to: url) {
                return url
            }
            return nil
        } catch {
            Log.storage.error("Failed to resolve bookmark for \(item.name): \(error.localizedDescription)")
            return nil
        }
    }

    func releaseAccess(to url: URL) {
        resourceManager.releaseAccess(to: url)
    }

    // MARK: - Thumbnail

    private func compressThumbnail(_ image: NSImage?, maxBytes: Int = 100 * 1_024) -> Data? {
        guard let image,
              let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else {
            return nil
        }

        // Try decreasing compression until under budget
        var compression: CGFloat = 0.8
        while compression > 0.1 {
            if let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: compression]),
               data.count <= maxBytes {
                return data
            }
            compression -= 0.1
        }

        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.1])
    }
}
