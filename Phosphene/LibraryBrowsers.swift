import AVFoundation
import SwiftUI

// MARK: - Thumbnails

/// Thumbnails shared by every row and tile, so scrolling never decodes the same file
/// twice. A file is decoded as a thumbnail of ``maxPixels`` a side, whatever size it
/// claims, off the main actor.
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
        let decoded = if url.isFileURL {
            PreviewImage.thumbnail(at: url, maxPixels: maxPixels)
        } else {
            await remoteThumbnail(at: url)
        }
        guard let image = decoded else { return nil }
        unsafe cache.setObject(image, forKey: url as NSURL)
        return image
    }

    /// Fetches web images with nothing kept on disk and no cookies.
    private static let remote: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        return URLSession(configuration: configuration)
    }()

    private enum Remote {
        /// The bytes asked for first. A Workshop preview is often an animated GIF of a
        /// megabyte whose first frame lies in its first tenth.
        static let head = 192 * 1_024
    }

    /// A still of a web image: from its first bytes when they hold a whole frame,
    /// otherwise from the whole file.
    private static func remoteThumbnail(at url: URL) async -> NSImage? {
        var request = URLRequest(url: url)
        request.setValue("bytes=0-\(Remote.head - 1)", forHTTPHeaderField: "Range")
        if let (data, response) = try? await remote.data(for: request),
           let status = (response as? HTTPURLResponse)?.statusCode {
            if status == 200 {
                return PreviewImage.thumbnail(of: data, maxPixels: maxPixels)
            }
            if status == 206, let image = PreviewImage.firstFrame(ofPartial: data, maxPixels: maxPixels) {
                return image
            }
        }
        guard let (data, response) = try? await remote.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return PreviewImage.thumbnail(of: data, maxPixels: maxPixels)
    }

    static func removeAll() {
        unsafe cache.removeAllObjects()
    }
}

/// What a thumbnail load depends on: the file, and the library revision it was read at.
private struct ThumbnailKey: Equatable {
    let url: URL?
    let revision: Int
}

/// A small 16:9 thumbnail for a table row.
struct RowThumbnail: View {
    let url: URL?
    let placeholder: String
    var revision = 0

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
            .task(id: ThumbnailKey(url: url, revision: revision)) {
                image = ThumbnailCache.cached(url)
                if image == nil {
                    image = await ThumbnailCache.image(at: url)
                }
            }
    }
}

// MARK: - Videos

/// The library's videos as a sortable table or a grid of thumbnails.
struct VideoBrowser: View {
    let rows: [VideoRow]

    @Environment(LibraryStore.self) private var store
    @Environment(PhospheneManager.self) private var manager

    var body: some View {
        switch store.viewMode {
        case .list: table
        case .icons: LibraryGrid(tiles: tiles, selection: store.videoSelection)
        }
    }

    private var tiles: [LibraryTileModel] {
        let working = manager.isOptimizing ? manager.optimizingEntryID : nil
        return rows.map { row in
            let pair = store.pairs[row.id]
            let badge: LibraryTileModel.Badge? = if (pair?.id ?? row.id) == working {
                .working(
                    label: manager.isConverting ? String(localized: "Converting") : String(localized: "Optimizing"),
                    progress: manager.optimizationProgress,
                )
            } else if row.isInUse {
                .inUse
            } else {
                nil
            }
            return LibraryTileModel(
                id: row.id, title: row.name,
                image: VideoDeploymentService.thumbnailURL(for: row.id), imageFit: .fill,
                video: row.isPair ? nil : VideoDeploymentService.videoURL(for: row.entry),
                placeholderSymbol: "film", isDimmed: false, badge: badge,
                help: row.isInUse ? String(localized: "In use as wallpaper") : "", isPair: row.isPair,
            )
        }
    }

    private var table: some View {
        @Bindable var store = store
        return Table(rows, selection: $store.videoSelection, sortOrder: $store.videoSort) {
            TableColumn("Name", value: \.name) { row in
                HStack(spacing: 8) {
                    RowThumbnail(
                        url: VideoDeploymentService.thumbnailURL(for: row.id), placeholder: "film",
                        revision: store.revision,
                    )
                    Text(row.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if row.isPair {
                        Image(.lightDarkPair)
                            .help("Light/Dark Pair")
                            .accessibilityLabel("Light/Dark Pair")
                    }
                    if row.isInUse {
                        Spacer(minLength: 4)
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.tint)
                            .help("In use as wallpaper")
                            .accessibilityLabel("In use")
                    }
                }
            }
            .width(min: ColumnWidth.nameMin)
            TableColumn("Resolution", value: \.pixelCount) { row in
                Text(row.resolutionLabel)
            }
            .width(min: ColumnWidth.resolution, ideal: ColumnWidth.resolution, max: ColumnWidth.resolution * 2)
            TableColumn("Frame Rate", value: \.fps) { row in
                Text(row.fps > 0 ? "\(Int(row.fps.rounded())) fps" : "—")
            }
            .width(min: ColumnWidth.frameRate, ideal: ColumnWidth.frameRate, max: ColumnWidth.frameRate * 2)
            TableColumn("Duration", value: \.duration) { row in
                Text(Duration.seconds(row.duration).formatted(.time(pattern: .minuteSecond)))
                    .monospacedDigit()
            }
            .width(min: ColumnWidth.duration, ideal: ColumnWidth.duration, max: ColumnWidth.duration * 2)
            TableColumn("Size", value: \.fileSize) { row in
                Text(ByteCountFormatter.string(fromByteCount: row.fileSize, countStyle: .file))
                    .monospacedDigit()
            }
            .width(min: ColumnWidth.size, ideal: ColumnWidth.size, max: ColumnWidth.size * 2)
            TableColumn("Added", value: \.dateAdded) { row in
                Text(row.dateAdded, format: Date.FormatStyle(date: .numeric, time: .omitted))
                    .monospacedDigit()
            }
            .width(min: ColumnWidth.date, ideal: ColumnWidth.date, max: ColumnWidth.date * 2)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: String.self) { ids in
            LibraryItemMenu(ids: ids)
        } primaryAction: { ids in
            store.toggleQuickLook(ids.first)
        }
        .onKeyPress(.space) {
            store.toggleQuickLook()
            return .handled
        }
        .onDeleteCommand { store.requestDelete() }
        .revealsSelection(rows.first { store.videoSelection.contains($0.id) }?.id, in: store.section)
    }
}

/// Widths of the table columns beside Name, each wide enough for its header with the
/// sort indicator and for its longest value; Name takes the rest.
private enum ColumnWidth {
    static let nameMin: CGFloat = 160
    static let resolution: CGFloat = 96
    static let frameRate: CGFloat = 90
    static let duration: CGFloat = 76
    static let size: CGFloat = 80
    static let date: CGFloat = 92
    static let status: CGFloat = 104
    static let type: CGFloat = 84
    static let source: CGFloat = 120
}

extension View {
    /// Scroll the row or tile `id` into view when this appears and when the section
    /// changes, so switching views or places keeps the selection in sight.
    func revealsSelection(_ id: String?, in section: LibrarySection) -> some View {
        modifier(RevealSelection(id: id, section: section))
    }
}

private struct RevealSelection: ViewModifier {
    let id: String?
    let section: LibrarySection

    func body(content: Content) -> some View {
        ScrollViewReader { proxy in
            content
                .onAppear { reveal(proxy) }
                .onChange(of: section) { reveal(proxy) }
        }
    }

    private func reveal(_ proxy: ScrollViewProxy) {
        if let id {
            proxy.scrollTo(id)
        }
    }
}

// MARK: - Wallpaper Engine

/// The Wallpaper Engine downloads as a sortable table or a grid of previews.
struct WorkshopBrowser: View {
    let rows: [WorkshopRow]

    @Environment(LibraryStore.self) private var store
    @Environment(WorkshopLibrary.self) private var workshop

    var body: some View {
        switch store.viewMode {
        case .list: table
        case .icons: LibraryGrid(tiles: rows.map(Self.tile), selection: workshop.staged)
        }
    }

    /// A download draws as its library video once it has one: the video's thumbnail,
    /// playing on hover. Before that it draws its Workshop preview.
    private static func tile(for row: WorkshopRow) -> LibraryTileModel {
        let badge: LibraryTileModel.Badge? = switch row.status {
        case .available: nil
        case .made: .made
        case .outdated: .outdated
        case .failed: .failed
        case .unsupported: .unsupported
        case .queued: .waiting
        case let .rendering(progress, _):
            .working(label: progress.formatted(.percent.precision(.fractionLength(0))), progress: progress)
        }
        let help = switch row.status {
        case .made: String(localized: "In your library")
        case .queued: String(localized: "Waiting to be made")
        case .rendering: String(localized: "Making its video")
        default: row.status.explanation ?? ""
        }
        return LibraryTileModel(
            id: row.id, title: row.title,
            image: thumbnail(of: row), imageFit: row.video == nil ? .actualSize : .fill,
            video: row.video.map(VideoDeploymentService.videoURL(for:)),
            placeholderSymbol: row.item.kind.symbol, isDimmed: row.status.isUnsupported, badge: badge, help: help,
        )
    }

    private static func thumbnail(of row: WorkshopRow) -> URL? {
        guard let video = row.video else { return row.item.preview }
        return VideoDeploymentService.thumbnailURL(for: video.id)
    }

    private var table: some View {
        @Bindable var workshop = workshop
        @Bindable var store = store
        return Table(rows, selection: $workshop.staged, sortOrder: $store.workshopSort) {
            TableColumn("Name", value: \.title) { row in
                HStack(spacing: 8) {
                    RowThumbnail(
                        url: Self.thumbnail(of: row), placeholder: row.item.kind.symbol, revision: store.revision,
                    )
                    Text(row.title)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(row.status.isUnsupported ? .secondary : .primary)
                }
            }
            .width(min: ColumnWidth.nameMin)
            TableColumn("Status", value: \.statusRank) { row in
                Text(row.statusName)
                    .foregroundStyle(row.status.isUnsupported ? .secondary : .primary)
                    .help(row.status.explanation ?? "")
            }
            .width(min: ColumnWidth.status, ideal: ColumnWidth.status, max: ColumnWidth.status * 2)
            TableColumn("Type", value: \.kindName) { row in
                Text(row.kindName)
            }
            .width(min: ColumnWidth.type, ideal: ColumnWidth.type, max: ColumnWidth.type * 2)
            TableColumn("Size", value: \.size) { row in
                Text(ByteCountFormatter.string(fromByteCount: row.size, countStyle: .file))
                    .monospacedDigit()
            }
            .width(min: ColumnWidth.size, ideal: ColumnWidth.size, max: ColumnWidth.size * 2)
            TableColumn("Updated", value: \.modified) { row in
                Text(row.modified, format: Date.FormatStyle(date: .numeric, time: .omitted))
                    .monospacedDigit()
            }
            .width(min: ColumnWidth.date, ideal: ColumnWidth.date, max: ColumnWidth.date * 2)
            if workshop.sources.count > 1 {
                TableColumn("Source", value: \.sourceLabel) { row in
                    Text(row.sourceLabel)
                        .foregroundStyle(.secondary)
                }
                .width(min: ColumnWidth.source, ideal: ColumnWidth.source, max: ColumnWidth.source * 2)
            }
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: String.self) { ids in
            LibraryItemMenu(ids: ids)
        } primaryAction: { ids in
            store.toggleQuickLook(ids.first)
        }
        .onKeyPress(.space) {
            store.toggleQuickLook()
            return .handled
        }
        .revealsSelection(rows.first { workshop.staged.contains($0.id) }?.id, in: store.section)
    }
}

// MARK: - Grid

/// Thumbnails at exactly the icon size, as many to a row as fit, with the leftover width
/// spread evenly between the columns like Finder's icon view. Arrow keys move the
/// selection and Space previews it.
struct LibraryGrid: View {
    let tiles: [LibraryTileModel]
    let selection: Set<String>
    /// A thumbnail's width over its height.
    var tileAspect: CGFloat = 16 / 9
    /// Called as the last tile comes into view, for a list that loads in pages.
    var onReachEnd: (() -> Void)?

    @Environment(LibraryStore.self) private var store

    var body: some View {
        let size = CGFloat(store.iconSize)
        // The reader takes whatever width the split view leaves and has no minimum of its
        // own, so the grid never holds the column wider than the window can give it: a
        // browser that needs room for its columns makes the split view hide the sidebar
        // while the inspector opens. The column count follows the width in the same
        // layout pass.
        GeometryReader { proxy in
            LibraryGridColumns(
                tiles: tiles, selection: selection, tileWidth: size,
                columns: LibraryGridMetrics.columns(in: proxy.size.width, tileWidth: size),
                tileAspect: tileAspect, onReachEnd: onReachEnd,
            )
        }
    }
}

/// The grid at a column count. Its inputs change only when a column is gained or lost,
/// so resizing the window re-renders it only then.
private struct LibraryGridColumns: View {
    let tiles: [LibraryTileModel]
    let selection: Set<String>
    let tileWidth: CGFloat
    let columns: Int
    let tileAspect: CGFloat
    let onReachEnd: (() -> Void)?

    @Environment(LibraryStore.self) private var store
    @Environment(\.controlActiveState) private var controlActiveState
    @FocusState private var isFocused: Bool

    var body: some View {
        let isEmphasized = controlActiveState == .key
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 0, alignment: .top), count: columns),
                    alignment: .leading,
                    spacing: LibraryGridMetrics.rowSpacing,
                ) {
                    ForEach(Array(tiles.enumerated()), id: \.element.id) { index, tile in
                        CellPlacement(placement: LibraryGridMetrics.placement(ofColumn: index % columns, columns: columns)) {
                            LibraryTile(
                                model: tile, width: tileWidth, aspect: tileAspect,
                                isSelected: selection.contains(tile.id),
                                isEmphasized: isEmphasized, revision: store.revision,
                            )
                        }
                        .onAppear {
                            if index == tiles.count - 1 {
                                onReachEnd?()
                            }
                        }
                    }
                }
                .padding(LibraryGridMetrics.padding)
            }
            .background {
                // A click on empty space clears the selection, as in Finder.
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { store.clearSelection() }
            }
            .focusable()
            .focusEffectDisabled()
            .focused($isFocused)
            .simultaneousGesture(TapGesture().onEnded { isFocused = true })
            .onKeyPress(.space) {
                store.toggleQuickLook()
                return .handled
            }
            .onMoveCommand { direction in
                if let id = store.moveSelection(direction, columns: columns) {
                    proxy.scrollTo(id)
                }
            }
            .onDeleteCommand { store.requestDelete() }
            .revealsSelection(tiles.first { selection.contains($0.id) }?.id, in: store.section)
        }
    }
}

/// Places its one subview across the width it is offered: at `placement` 0 against the
/// leading edge, at 1 against the trailing edge.
private struct CellPlacement: Layout {
    let placement: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        let size = subview.sizeThatFits(.unspecified)
        return CGSize(width: proposal.width ?? size.width, height: size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        guard let subview = subviews.first else { return }
        let size = subview.sizeThatFits(.unspecified)
        subview.place(
            at: CGPoint(x: bounds.minX + (bounds.width - size.width) * placement, y: bounds.minY),
            proposal: ProposedViewSize(size),
        )
    }
}

// MARK: - Tile

/// A muted player that loops one file.
final class LoopingPlayer {
    let player: AVQueuePlayer
    private let looper: AVPlayerLooper

    init(url: URL) {
        let item = AVPlayerItem(url: url)
        player = AVQueuePlayer(playerItem: item)
        player.isMuted = true
        looper = AVPlayerLooper(player: player, templateItem: item)
        player.play()
    }

    func stop() {
        looper.disableLooping()
        player.pause()
    }
}

/// One thumbnail and its name. A click selects it with Finder's modifier rules, a double
/// click opens Quick Look, and a video plays while the pointer rests on it.
struct LibraryTile: View {
    let model: LibraryTileModel
    let width: CGFloat
    /// The thumbnail's width over its height.
    let aspect: CGFloat
    let isSelected: Bool
    /// Whether the selection draws in the accent color: in the key window.
    let isEmphasized: Bool
    let revision: Int

    @Environment(LibraryStore.self) private var store
    @State private var image: NSImage?
    @State private var isHovered = false
    @State private var preview: LoopingPlayer?

    private enum Metrics {
        static let cornerRadius: CGFloat = 8
        static let ringWidth: CGFloat = 3
        /// The ring's outer edge from the thumbnail's: its width plus a 1-pt gap.
        static let ringOutset: CGFloat = ringWidth + 1
        static let badgeSize: CGFloat = 20
        static let badgeInset: CGFloat = 6
        static let hoverDelay: Duration = .milliseconds(350)
    }

    var body: some View {
        VStack(spacing: 6) {
            thumbnail
            Text(model.title)
                .font(.callout)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .truncationMode(.middle)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .foregroundStyle(titleStyle)
                .background(
                    isSelected ? selectionStyle : AnyShapeStyle(.clear),
                    in: RoundedRectangle(cornerRadius: 4, style: .continuous),
                )
        }
        .frame(width: width, alignment: .top)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .gesture(TapGesture(count: 2).onEnded { store.toggleQuickLook(model.id) })
        .simultaneousGesture(TapGesture().onEnded { store.click(model.id) })
        .contextMenu { LibraryItemMenu(clicked: model.id) }
        .help(model.help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.title)
        .accessibilityValue(model.isPair ? Text("Light/Dark Pair") : Text(""))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { store.click(model.id) }
        .task(id: ThumbnailKey(url: model.image, revision: revision)) {
            image = ThumbnailCache.cached(model.image)
            if image == nil {
                image = await ThumbnailCache.image(at: model.image)
            }
        }
        .task(id: isHovered) {
            guard isHovered, let video = model.video else {
                preview?.stop()
                preview = nil
                return
            }
            try? await Task.sleep(for: Metrics.hoverDelay)
            guard !Task.isCancelled else { return }
            preview = LoopingPlayer(url: video)
        }
        .onDisappear {
            preview?.stop()
            preview = nil
        }
    }

    private var titleStyle: AnyShapeStyle {
        if isSelected {
            return isEmphasized ? AnyShapeStyle(.white) : AnyShapeStyle(.primary)
        }
        return model.isDimmed ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary)
    }

    /// The ring and title fill: the accent in the key window, gray elsewhere, like a
    /// table's selection.
    private var selectionStyle: AnyShapeStyle {
        isEmphasized
            ? AnyShapeStyle(Color.accentColor)
            : AnyShapeStyle(Color(nsColor: .unemphasizedSelectedContentBackgroundColor))
    }

    private var thumbnail: some View {
        ZStack {
            if let image {
                switch model.imageFit {
                case .fill:
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFill()
                case .actualSize:
                    ActualSizeFrame(pixelSize: image.pixelSize) {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.high)
                    }
                case .fit:
                    Rectangle()
                        .fill(.black)
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                }
            } else {
                Rectangle()
                    .fill(.quaternary)
                Image(systemName: model.placeholderSymbol)
                    .font(.title2)
                    .foregroundStyle(.tertiary)
            }
            if let preview {
                PlayerLayerView(player: preview.player)
            }
        }
        .frame(width: width, height: (width / aspect).rounded())
        .unsupportedDimming(model.isDimmed)
        .clipShape(RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous)
                .strokeBorder(.separator, lineWidth: 0.5)
        }
        .overlay(alignment: .bottomTrailing) { badge }
        .overlay(alignment: .topTrailing) {
            if model.isPair {
                pill { Image(.lightDarkPair) }
            }
        }
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: Metrics.cornerRadius + Metrics.ringOutset, style: .continuous)
                    .strokeBorder(selectionStyle, lineWidth: Metrics.ringWidth)
                    .padding(-Metrics.ringOutset)
            }
        }
    }

    @ViewBuilder
    private var badge: some View {
        switch model.badge {
        case .inUse:
            symbolBadge("checkmark", fill: AnyShapeStyle(Color.accentColor))
        case .made:
            symbolBadge("film", fill: AnyShapeStyle(.black.opacity(0.55)))
        case .outdated:
            symbolBadge("arrow.triangle.2.circlepath", fill: AnyShapeStyle(.orange))
        case .failed:
            symbolBadge("exclamationmark", fill: AnyShapeStyle(.red))
        case .unsupported:
            symbolBadge("nosign", fill: AnyShapeStyle(.gray))
        case .waiting:
            pill { Text("Waiting") }
        case .getting:
            pill {
                ProgressView()
                    .controlSize(.mini)
                    .tint(.white)
                Text("Getting")
            }
        case .downloaded:
            symbolBadge("arrow.down", fill: AnyShapeStyle(.black.opacity(0.55)))
        case let .working(label, progress):
            pill {
                ProgressView(value: progress)
                    .progressViewStyle(.circular)
                    .controlSize(.mini)
                    .tint(.white)
                Text(verbatim: label)
            }
        case nil:
            EmptyView()
        }
    }

    private func symbolBadge(_ symbol: String, fill: AnyShapeStyle) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: Metrics.badgeSize, height: Metrics.badgeSize)
            .background(fill, in: Circle())
            .padding(Metrics.badgeInset)
    }

    private func pill(@ViewBuilder _ content: () -> some View) -> some View {
        HStack(spacing: 5, content: content)
            .font(.caption2)
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.black.opacity(0.55), in: Capsule())
            .padding(Metrics.badgeInset)
    }
}

// MARK: - Context menu

/// What a click with the secondary button offers for videos or downloads. A click on an
/// unselected item acts on that item; a click inside the selection acts on all of it.
struct LibraryItemMenu: View {
    private let explicit: Set<String>?
    private let clicked: String?

    @Environment(LibraryStore.self) private var store
    @Environment(WorkshopLibrary.self) private var workshop
    @Environment(CatalogStore.self) private var catalog

    init(ids: Set<String>) {
        explicit = ids
        clicked = nil
    }

    init(clicked: String) {
        explicit = nil
        self.clicked = clicked
    }

    private var ids: Set<String> {
        if let explicit {
            return explicit
        }
        guard let clicked else { return [] }
        let selection = store.selection
        return selection.contains(clicked) ? selection : [clicked]
    }

    var body: some View {
        let ids = ids
        if !ids.isEmpty {
            switch store.section.content {
            case .videos: videoItems(ids)
            case .downloads: downloadItems(ids)
            case .catalog: catalogItems(ids)
            }
        }
    }

    @ViewBuilder
    private func catalogItems(_ ids: Set<String>) -> some View {
        if let id = ids.first {
            let downloaded = workshop.item(id) != nil
            if downloaded {
                Button("Show in All Wallpapers") { store.reveal(downloadID: id) }
            } else if workshop.subscribeBlocker == nil {
                Button("Get") { catalog.get(id) }
            }
            Button("Open Workshop Page") { workshop.openWorkshopPage(ofID: id) }
        }
    }

    @ViewBuilder
    private func videoItems(_ ids: Set<String>) -> some View {
        Button("Quick Look") { store.toggleQuickLook(ids.first) }
        Button("Open Wallpaper Settings…") { store.openWallpaperSettings() }
        if let pair = store.pairAction(for: ids) {
            Button { store.pairSheet = pair } label: {
                Label(pair.actionTitle, image: .lightDarkPair)
            }
            if pair.saved != nil, pair.members.count == 2 {
                Button("Swap Light and Dark", systemImage: "arrow.left.arrow.right") { store.swapAppearances(pair) }
            }
        }
        Divider()
        Button("Show in Finder") { store.showInFinder(ids) }
        Divider()
        let title: LocalizedStringKey = if ids.count == 1, let id = ids.first, store.pairs[id] != nil {
            "Delete Pair…"
        } else {
            ids.count == 1 ? "Delete…" : "Delete \(ids.count) Videos…"
        }
        Button(title, role: .destructive) {
            store.requestDelete(ids)
        }
    }

    @ViewBuilder
    private func downloadItems(_ ids: Set<String>) -> some View {
        let renderable = ids.filter { workshop.assessments[$0]?.isRenderable ?? false }
        if !renderable.isEmpty {
            Button(renderable.count == 1 ? "Make Video…" : "Make \(renderable.count) Videos…") {
                store.requestMakeVideos(ids)
            }
            Divider()
        }
        Button("Quick Look") { store.toggleQuickLook(ids.first) }
        if ids.count == 1, let item = ids.first.flatMap(workshop.item), item.workshopPageURL != nil {
            Button("Open Workshop Page") { workshop.openWorkshopPage(of: item) }
        }
        Button("Show in Finder") { store.showInFinder(ids) }
    }
}
