import SwiftUI

// MARK: - Thumbnails

/// Stores bounded, decoded thumbnails shared by the library and popover.
nonisolated enum ThumbnailCache {
    private static let maxPixels = 720
    private static let decoder = Decoder()
    private nonisolated(unsafe) static let cache: NSCache<NSURL, Thumbnail> = {
        let cache = NSCache<NSURL, Thumbnail>()
        cache.countLimit = 400
        cache.totalCostLimit = 64 * 1_024 * 1_024
        return cache
    }()

    private final class Thumbnail {
        let identity: FileIdentity
        let image: NSImage

        init(identity: FileIdentity, image: NSImage) {
            self.identity = identity
            self.image = image
        }
    }

    /// The thumbnail if it was decoded before, for a first draw without a wait.
    static func cached(_ url: URL?) -> NSImage? {
        url.flatMap { unsafe cache.object(forKey: $0 as NSURL)?.image }
    }

    static func image(at url: URL?) async -> NSImage? {
        guard let url else { return nil }
        return await decoder.image(at: url)
    }

    /// Serializing misses lets simultaneous views share the same decode.
    private actor Decoder {
        func image(at url: URL) -> NSImage? {
            guard !Task.isCancelled, let identity = FileIdentity(of: url) else { return nil }
            let key = url as NSURL
            if let thumbnail = unsafe cache.object(forKey: key), thumbnail.identity == identity {
                return thumbnail.image
            }
            guard let image = PreviewImage.thumbnail(at: url, maxPixels: maxPixels) else { return nil }
            let bitmap = image.representations.first as? NSBitmapImageRep
            let cost = bitmap.map { $0.bytesPerRow * $0.pixelsHigh } ?? Int(image.size.width * image.size.height) * 4
            unsafe cache.setObject(Thumbnail(identity: identity, image: image), forKey: key, cost: cost)
            return image
        }
    }
}

/// Reads the same preview JPEG that Wallpaper Settings uses.
struct VideoThumbnail<Content: View>: View {
    let videoID: String?
    var legacyVideoURL: URL?
    @ViewBuilder let content: (NSImage?) -> Content

    @State private var image: NSImage?
    @State private var loadedID: String?
    @State private var revision = 0

    private struct Request: Equatable {
        let videoID: String?
        let legacyVideoURL: URL?
        let revision: Int
    }

    var body: some View {
        let url = videoID.map(VideoDeploymentService.thumbnailURL(for:))
        content(loadedID == videoID ? image : ThumbnailCache.cached(url))
            .task(id: Request(videoID: videoID, legacyVideoURL: legacyVideoURL, revision: revision)) {
                guard let videoID else { return }
                var image = await ThumbnailCache.image(at: url)
                if image == nil, let legacyVideoURL, !Task.isCancelled {
                    await VideoDeploymentService.generateThumbnail(for: legacyVideoURL, in: legacyVideoURL.deletingLastPathComponent())
                    image = await ThumbnailCache.image(at: url)
                }
                guard !Task.isCancelled else { return }
                loadedID = videoID
                self.image = image
            }
            .onReceive(NotificationCenter.default.publisher(for: VideoDeploymentService.libraryChangedNotification)) { _ in
                revision += 1
            }
            .onDisappear {
                loadedID = nil
                image = nil
            }
    }
}

/// A small 16:9 thumbnail for a table row.
struct RowThumbnail: View {
    let url: URL?
    let placeholder: String

    @State private var image: NSImage?

    var body: some View {
        Self.tile(image: image, placeholder: placeholder)
            .task(id: url) {
                image = ThumbnailCache.cached(url)
                if image == nil {
                    let loaded = await ThumbnailCache.image(at: url)
                    guard !Task.isCancelled else { return }
                    image = loaded
                }
            }
            .onDisappear { image = nil }
    }

    static func tile(image: NSImage?, placeholder: String) -> some View {
        Color.clear
            .overlay {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Rectangle()
                        .fill(.quaternary)
                        .overlay {
                            Image(systemName: placeholder)
                                .imageScale(.small)
                                .foregroundStyle(.tertiary)
                        }
                }
            }
            .frame(width: 48, height: 27)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

struct BrowserHoverPreview<Content: View>: View {
    @ViewBuilder let content: (_ isHovered: Bool, _ isPlaying: Bool) -> Content

    @State private var isHovered = false
    @State private var isPlaying = false
    @Environment(\.appearsActive) private var appearsActive

    var body: some View {
        content(isHovered, isPlaying)
            .contentShape(Rectangle())
            .onHover(perform: updateHover)
            .onScrollVisibilityChange(threshold: 0.01) { visible in
                if !visible {
                    updateHover(false)
                }
            }
            .task(id: isHovered) {
                guard isHovered else { return }
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled, isHovered else { return }
                isPlaying = true
            }
            .onDisappear { updateHover(false) }
            .onChange(of: appearsActive) {
                if !appearsActive {
                    updateHover(false)
                }
            }
    }

    private func updateHover(_ hovering: Bool) {
        isHovered = hovering
        if !hovering {
            isPlaying = false
        }
    }
}

// MARK: - Videos

struct VideoEntryTitle: View {
    let name: String
    let isPair: Bool
    @ScaledMetric(relativeTo: .callout) private var badgeSize: CGFloat = 13

    var body: some View {
        HStack(spacing: 5) {
            if isPair {
                Image(.lightDarkPair)
                    .resizable()
                    .frame(width: badgeSize, height: badgeSize)
                    .foregroundStyle(.secondary)
                    .help("Light/Dark Pair")
                    .accessibilityHidden(true)
            }
            Text(verbatim: name)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(isPair ? Text("Light/Dark Pair") : Text(verbatim: ""))
    }
}

struct VideoBrowser<ItemMenu: View>: View {
    let rows: [VideoRow]
    @Binding var selection: Set<String>
    @Binding var sortOrder: [KeyPathComparator<VideoRow>]
    let mode: LibraryViewMode
    let iconSize: Double
    @Bindable var manager: PhospheneManager
    let onDelete: (Set<String>) -> Void
    @ViewBuilder let itemMenu: (Set<String>) -> ItemMenu

    @State private var anchor: String?

    var body: some View {
        switch mode {
        case .list: table
        case .icons: grid
        }
    }

    private var table: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { row in
                HStack(spacing: 8) {
                    if let pair = row.pair, let saved = pair.saved {
                        BrowserHoverPreview { _, isPlaying in
                            VideoPairPreview(selection: pair, swapped: saved.swapped, isPlaying: isPlaying)
                                .frame(width: 48, height: 27)
                                .clipShape(.rect(cornerRadius: 4))
                        }
                    } else {
                        VideoThumbnail(videoID: row.id) { image in
                            RowThumbnail.tile(image: image, placeholder: "film")
                        }
                    }
                    VideoEntryTitle(name: row.name, isPair: row.pair != nil)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .width(min: 160, ideal: 300)
            TableColumn("In Use", value: \.inUseRank) { row in
                if row.isInUse {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.tint)
                        .help("In use as wallpaper")
                        .accessibilityLabel("In use")
                }
            }
            .width(min: 44, ideal: 52, max: 64)
            TableColumn("Resolution", value: \.pixelCount) { row in
                Text(row.resolutionLabel)
            }
            .width(min: 64, ideal: 84)
            TableColumn("Frame Rate", value: \.fps) { row in
                Text(row.fps > 0 ? "\(Int(row.fps.rounded())) fps" : "—")
            }
            .width(min: 60, ideal: 76)
            TableColumn("Duration", value: \.duration) { row in
                Text(Duration.seconds(row.duration).formatted(.time(pattern: .minuteSecond)))
                    .monospacedDigit()
            }
            .width(min: 56, ideal: 70)
            TableColumn("Size", value: \.fileSize) { row in
                Text(ByteCountFormatter.string(fromByteCount: row.fileSize, countStyle: .file))
                    .monospacedDigit()
            }
            .width(min: 60, ideal: 76)
            TableColumn("Added", value: \.dateAdded) { row in
                Text(row.dateAdded, format: Date.FormatStyle(date: .numeric, time: .omitted))
                    .monospacedDigit()
            }
            .width(min: 76, ideal: 88)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: String.self) { ids in
            if !ids.isEmpty {
                itemMenu(ids)
            }
        }
        .onDeleteCommand { onDelete(selection) }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: iconSize, maximum: iconSize), spacing: 18, alignment: .top)],
                alignment: .leading,
                spacing: 22,
            ) {
                ForEach(rows) { row in
                    let ids: Set<String> = selection.contains(row.id) ? selection : [row.id]
                    VideoCardView(
                        entry: row.entry, pair: row.pair,
                        isSelected: selection.contains(row.id),
                        isInUse: row.isInUse,
                        isOptimizing: manager.isOptimizing && manager.optimizingEntryID == row.id,
                        optimizationProgress: manager.optimizationProgress,
                        onSelect: { modifiers in
                            GridSelection.click(row.id, in: rows.map(\.id), selection: &selection, anchor: &anchor, modifiers: modifiers)
                        },
                    )
                    .contextMenu { itemMenu(ids) }
                }
            }
            .padding(20)
        }
        .background {
            // A click on empty space clears the selection, as in Finder.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { selection.removeAll() }
        }
        .onDeleteCommand { onDelete(selection) }
    }
}

// MARK: - Wallpaper Engine

struct WorkshopBrowser: View {
    let rows: [WorkshopRow]
    @Bindable var library: WorkshopLibrary
    @Binding var sortOrder: [KeyPathComparator<WorkshopRow>]
    let mode: LibraryViewMode
    let iconSize: Double
    let showVideo: (String) -> Void

    @State private var anchor: String?

    var body: some View {
        switch mode {
        case .list: table
        case .icons: grid
        }
    }

    private var table: some View {
        Table(rows, selection: $library.staged, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.title) { row in
                HStack(spacing: 8) {
                    RowThumbnail(url: row.item.preview, placeholder: "photo")
                    Text(row.title)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(row.status.isUnsupported ? .secondary : .primary)
                }
            }
            .width(min: 180, ideal: 320)
            TableColumn("Video", value: \.statusRank) { row in
                Text(row.statusName)
                    .foregroundStyle(row.status.isUnsupported ? .secondary : .primary)
                    .help(row.status.explanation ?? "")
            }
            .width(min: 90, ideal: 110)
            TableColumn("Type", value: \.kindName) { row in
                Text(row.kindName)
            }
            .width(min: 64, ideal: 76)
            TableColumn("Size", value: \.size) { row in
                Text(ByteCountFormatter.string(fromByteCount: row.size, countStyle: .file))
                    .monospacedDigit()
            }
            .width(min: 60, ideal: 76)
            TableColumn("Updated", value: \.modified) { row in
                Text(row.modified, format: Date.FormatStyle(date: .numeric, time: .omitted))
                    .monospacedDigit()
            }
            .width(min: 76, ideal: 88)
            TableColumn("Source", value: \.sourceLabel) { row in
                Text(row.sourceLabel)
                    .foregroundStyle(.secondary)
            }
            .width(min: 90, ideal: 110)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: String.self) { ids in
            contextMenu(for: ids)
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: iconSize, maximum: iconSize), spacing: 18, alignment: .top)],
                alignment: .leading,
                spacing: 22,
            ) {
                ForEach(rows) { row in
                    WorkshopTileView(
                        item: row.item,
                        status: row.status,
                        isStaged: library.staged.contains(row.id),
                        onTap: {
                            GridSelection.click(
                                row.id, in: rows.map(\.id), selection: &library.staged, anchor: &anchor,
                            )
                        },
                    )
                    .contextMenu { contextMenu(for: library.staged.contains(row.id) ? library.staged : [row.id]) }
                }
            }
            .padding(20)
        }
        .background {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { library.staged.removeAll() }
        }
    }

    @ViewBuilder
    private func contextMenu(for ids: Set<String>) -> some View {
        let renderable = ids.filter {
            library.assessments[$0]?.isRenderable == true && library.current != $0 && !library.queue.contains($0)
        }
        if !renderable.isEmpty {
            let title: LocalizedStringKey = if renderable.count > 1 {
                "Make \(renderable.count) Videos"
            } else if let id = renderable.first, library.records[id] != nil {
                "Make Video Again"
            } else {
                "Make Video"
            }
            Button(title) {
                library.makeVideos(Array(renderable))
            }
            Divider()
        }
        WorkshopItemActions(ids: ids, library: library, showVideo: showVideo)
    }
}
