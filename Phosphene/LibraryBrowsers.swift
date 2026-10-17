import SwiftUI

// MARK: - Thumbnails

/// Thumbnails shared by every row and tile, so scrolling a long table never decodes
/// the same file twice. A file is decoded as a thumbnail of ``maxPixels`` a side,
/// whatever size it claims, off the main actor.
nonisolated enum ThumbnailCache {
    static let maxPixels = 720
    /// NSCache is thread-safe: filled from the decode pool, read on the main actor.
    private nonisolated(unsafe) static let cache: NSCache<NSURL, NSImage> = {
        let cache = NSCache<NSURL, NSImage>()
        cache.countLimit = 400
        return cache
    }()

    /// The thumbnail if it was decoded before, for a first draw without a wait.
    static func cached(_ url: URL?) -> NSImage? {
        url.flatMap { unsafe cache.object(forKey: $0 as NSURL) }
    }

    @concurrent
    static func image(at url: URL?) async -> NSImage? {
        guard let url else { return nil }
        if let cached = unsafe cache.object(forKey: url as NSURL) {
            return cached
        }
        guard let image = PreviewImage.thumbnail(at: url, maxPixels: maxPixels) else { return nil }
        unsafe cache.setObject(image, forKey: url as NSURL)
        return image
    }
}

/// A small 16:9 thumbnail for a table row.
struct RowThumbnail: View {
    let url: URL?
    let placeholder: String

    @State private var image: NSImage?

    var body: some View {
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
            .task(id: url) {
                image = ThumbnailCache.cached(url)
                if image == nil {
                    image = await ThumbnailCache.image(at: url)
                }
            }
    }
}

// MARK: - Videos

struct VideoBrowser: View {
    let rows: [VideoRow]
    @Binding var selection: Set<String>
    @Binding var sortOrder: [KeyPathComparator<VideoRow>]
    let mode: LibraryViewMode
    let iconSize: Double
    @Bindable var manager: PhospheneManager
    let onDelete: (Set<String>) -> Void

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
                    RowThumbnail(url: VideoDeploymentService.thumbnailURL(for: row.id), placeholder: "film")
                    Text(row.name)
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
            contextMenu(for: ids)
        }
        .onDeleteCommand { onDelete(selection) }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: iconSize), spacing: 18, alignment: .top)],
                alignment: .leading,
                spacing: 22,
            ) {
                ForEach(rows) { row in
                    VideoCardView(
                        entry: row.entry,
                        isSelected: selection.contains(row.id),
                        isInUse: row.isInUse,
                        isOptimizing: manager.isOptimizing && manager.optimizingEntryID == row.id,
                        optimizationProgress: manager.optimizationProgress,
                        onSelect: {
                            GridSelection.click(row.id, in: rows.map(\.id), selection: &selection, anchor: &anchor)
                        },
                        onDelete: { onDelete(selection.contains(row.id) ? selection : [row.id]) },
                    )
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

    @ViewBuilder
    private func contextMenu(for ids: Set<String>) -> some View {
        if !ids.isEmpty {
            Button("Show in Finder") {
                let urls = rows.filter { ids.contains($0.id) }.map { VideoDeploymentService.videoURL(for: $0.entry) }
                NSWorkspace.shared.activateFileViewerSelecting(urls)
            }
            Divider()
            Button(ids.count == 1 ? "Delete…" : "Delete \(ids.count) Videos…", role: .destructive) {
                onDelete(ids)
            }
        }
    }
}

// MARK: - Wallpaper Engine

struct WorkshopBrowser: View {
    let rows: [WorkshopRow]
    @Bindable var library: WorkshopLibrary
    @Binding var sortOrder: [KeyPathComparator<WorkshopRow>]
    let mode: LibraryViewMode
    let iconSize: Double

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
                columns: [GridItem(.adaptive(minimum: iconSize), spacing: 18, alignment: .top)],
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
        let renderable = ids.filter { library.assessments[$0]?.isRenderable ?? false }
        if !renderable.isEmpty {
            Button(renderable.count == 1 ? "Make Video" : "Make \(renderable.count) Videos") {
                library.makeVideos(Array(renderable))
            }
            Divider()
        }
        if ids.count == 1, let id = ids.first, let item = library.item(id) {
            if let page = item.workshopPageURL {
                Button("Open Workshop Page") { NSWorkspace.shared.open(page) }
            }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.folder]) }
        }
    }
}
