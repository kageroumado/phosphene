import AppKit
import os
import SwiftUI

/// The library window's state and intents: the place shown and how, what is selected,
/// and what the user asked to do with it.
@Observable
final class LibraryStore {
    @ObservationIgnored unowned let manager: PhospheneManager
    /// The Steam Workshop listing the Workshop section browses.
    @ObservationIgnored let catalog: CatalogStore

    private enum Key {
        static let viewMode = "libraryViewMode"
        static let iconSize = "libraryIconSize"
    }

    // MARK: - What is shown

    var section: LibrarySection {
        didSet {
            guard section != oldValue else { return }
            UserDefaults.standard.set(section.rawValue, forKey: LibrarySection.storageKey)
            search = ""
        }
    }

    var viewMode: LibraryViewMode {
        didSet {
            guard viewMode != oldValue else { return }
            UserDefaults.standard.set(viewMode.rawValue, forKey: Key.viewMode)
        }
    }

    /// The width of one grid thumbnail, in points.
    var iconSize: Double {
        didSet {
            guard iconSize != oldValue else { return }
            UserDefaults.standard.set(iconSize, forKey: Key.iconSize)
        }
    }

    /// The sidebar's selection: a row is always selected, so clearing it changes nothing.
    var sidebarSelection: LibrarySection? {
        get { section }
        set {
            if let newValue {
                section = newValue
            }
        }
    }

    var search = ""
    var showInspector = true
    private(set) var columnVisibility = NavigationSplitViewVisibility.all

    var showsSidebar: Bool {
        columnVisibility != .detailOnly
    }
    var videoSort = [KeyPathComparator(\VideoRow.dateAdded, order: .reverse)]
    var workshopSort = [KeyPathComparator(\WorkshopRow.modified, order: .reverse)]

    // MARK: - Selection and requests

    var videoSelection: Set<String> = []
    var isMakeVideosPresented = false
    var pairSheet: VideoPairSelection?
    var libraryError: String?
    /// The videos a delete confirmation is asking about.
    var pendingDelete: LibraryDeletion?
    var pendingVariantRemoval: VideoOptimizationTarget?
    var sdrOptimizationTargetID: String?

    var isConfirmingDelete: Bool {
        get { pendingDelete != nil }
        set {
            if !newValue {
                pendingDelete = nil
            }
        }
    }

    /// The file Quick Look is showing.
    var quickLookURL: URL?

    /// Bumped on every library reload; thumbnails reload when it changes.
    private(set) var revision = 0
    private var entries: [VideoDeploymentService.EntryInfo] = []
    private var sourceEntries: [VideoDeploymentService.EntryInfo] = []
    private(set) var pairs: [String: VideoPairSelection] = [:]
    @ObservationIgnored private var fileSizes: [String: Int64] = [:]
    @ObservationIgnored private var anchor: String?

    init(manager: PhospheneManager) {
        self.manager = manager
        catalog = CatalogStore(workshop: manager.workshop)
        let defaults = UserDefaults.standard
        section = defaults.string(forKey: LibrarySection.storageKey).flatMap(LibrarySection.init(rawValue:)) ?? .allVideos
        viewMode = defaults.string(forKey: Key.viewMode).flatMap(LibraryViewMode.init(rawValue:)) ?? .icons
        let storedSize = defaults.double(forKey: Key.iconSize)
        iconSize = storedSize > 0 ? LibraryIconSize.clamped(storedSize) : LibraryIconSize.standard
    }

    private var workshop: WorkshopLibrary {
        manager.workshop
    }

    // MARK: - Rows

    private var inUseIDs: Set<String> {
        Set(manager.prefsService.selections.map { visibleVideoID(for: $0.videoID) })
    }

    private var fromWorkshopIDs: Set<String> {
        Set(workshop.records.values.map { visibleVideoID(for: $0.entryID) })
    }

    /// The videos of the current section that match the search, in sort order.
    var videoRows: [VideoRow] {
        let inUse = inUseIDs
        let fromWorkshop = section == .fromWorkshop ? fromWorkshopIDs : []
        return entries.compactMap { entry -> VideoRow? in
            let pair = pairs[entry.id]
            let isInUse = inUse.contains(entry.id)
            if section == .inUse, !isInUse {
                return nil
            }
            if section == .fromWorkshop, !fromWorkshop.contains(entry.id) {
                return nil
            }
            if section == .lightDarkPairs, pair == nil {
                return nil
            }
            let members = pair?.members ?? [entry]
            guard search.isEmpty || entry.name.localizedStandardContains(search)
                || members.contains(where: { $0.name.localizedStandardContains(search) }) else { return nil }
            let size = members.reduce(0) { $0 + (fileSizes[$1.id] ?? 0) }
            return VideoRow(entry: entry, isInUse: isInUse, isPair: pair != nil, fileSize: size)
        }
        .sorted(using: videoSort)
    }

    /// The downloads of the current section that match the search, in sort order.
    var workshopRows: [WorkshopRow] {
        let labels = Dictionary(workshop.sources.map { ($0.id, $0.label) }) { first, _ in first }
        let entriesByID = Dictionary(sourceEntries.map { ($0.id, $0) }) { first, _ in first }
        return workshop.items.compactMap { item -> WorkshopRow? in
            let status = workshop.status(of: item)
            switch section {
            case .workshopReady where !Self.isReadyToMake(status):
                return nil
            case let .workshopSource(id) where item.sourceID != id:
                return nil
            default:
                break
            }
            guard search.isEmpty || item.title.localizedStandardContains(search) else { return nil }
            return WorkshopRow(
                item: item, status: status, sourceLabel: labels[item.sourceID] ?? "",
                video: workshop.records[item.id].flatMap { entriesByID[$0.entryID] },
            )
        }
        .sorted(using: workshopSort)
    }

    /// Whether a wallpaper belongs in Ready to Make: it can become a video and has no
    /// current one, or one is being made. The section's rows and its sidebar count both
    /// use this.
    private static func isReadyToMake(_ status: WorkshopLibrary.ItemStatus) -> Bool {
        switch status {
        case .available, .outdated, .failed, .queued, .rendering: true
        case .made, .unsupported: false
        }
    }

    struct Counts: Equatable {
        var all = 0
        var inUse = 0
        var fromWorkshop = 0
        var pairs = 0
        var wallpapers = 0
        var readyToMake = 0
    }

    var counts: Counts {
        let inUse = inUseIDs
        let fromWorkshop = fromWorkshopIDs
        return Counts(
            all: entries.count,
            inUse: entries.count { inUse.contains($0.id) },
            fromWorkshop: entries.count { fromWorkshop.contains($0.id) },
            pairs: pairs.count,
            wallpapers: workshop.items.count,
            readyToMake: workshop.items.count { Self.isReadyToMake(workshop.status(of: $0)) },
        )
    }

    /// Whether the sidebar lists each place wallpapers come from: with several places,
    /// or with an added folder, which its row removes.
    var showsSources: Bool {
        workshop.sources.count > 1 || workshop.sources.contains { $0.kind == .folder }
    }

    var selectedVideos: [VideoDeploymentService.EntryInfo] {
        entries.filter { videoSelection.contains($0.id) }
    }

    var selectedDownloads: [WorkshopItem] {
        workshop.items.filter { workshop.staged.contains($0.id) }
    }

    /// The selected downloads that can become videos.
    var renderableSelection: [WorkshopItem] {
        selectedDownloads.filter { workshop.assessments[$0.id]?.isRenderable ?? false }
    }

    /// The library video made from `item`, once there is one.
    func video(for item: WorkshopItem) -> VideoDeploymentService.EntryInfo? {
        guard let entryID = workshop.records[item.id]?.entryID else { return nil }
        return sourceEntries.first { $0.id == entryID }
    }

    /// The size of a library video's file, as read at the last reload.
    func fileSize(ofVideo entryID: String) -> Int64? {
        fileSizes[entryID]
    }

    var hasSelection: Bool {
        !selection.isEmpty
    }

    /// Whether the section shows as a grid of icons: the Workshop listing always does.
    var showsIcons: Bool {
        viewMode == .icons || section.content == .catalog
    }

    /// Whether the selection is files on this Mac, which Quick Look and Finder can show.
    var hasLocalSelection: Bool {
        section.content != .catalog && hasSelection
    }

    // MARK: - Loading

    /// Read the library from disk. Thumbnails are decoded again: a replaced video keeps
    /// its thumbnail's file name.
    func reload() {
        let directory = VideoDeploymentService.videosFolderURL
        var records = (try? AppearancePair.read(in: directory)) ?? []
        for record in records where record.deletionPending == true {
            do {
                try record.finishDeletion(in: directory)
                records.removeAll { $0.owner == record.owner }
            } catch {
                Log.video.error("Could not finish deleting pair \(record.owner): \(error.localizedDescription)")
            }
        }
        let physical = VideoDeploymentService.listEntries()
        sourceEntries = physical
        fileSizes = Dictionary(uniqueKeysWithValues: physical.map { entry in
            (entry.id, VideoDeploymentService.fileSize(for: entry) ?? 0)
        })
        let byID = Dictionary(uniqueKeysWithValues: physical.map { ($0.id, $0) })
        var groups: [String: VideoPairSelection] = [:]
        var hidden: Set<String> = []
        for record in records {
            let first = byID[record.owner]
            let second = byID[record.counterpart]
            guard let visible = first ?? second else { continue }
            groups[visible.id] = VideoPairSelection(first: first, second: second, saved: record)
            if first != nil {
                hidden.insert(record.counterpart)
            }
        }
        pairs = groups
        entries = physical.compactMap { source in
            guard !hidden.contains(source.id) else { return nil }
            var entry = source
            entry.name = groups[entry.id]?.saved?.name ?? entry.name
            return entry
        }
        let known = Set(entries.map(\.id))
        videoSelection = Set(videoSelection.map(visibleVideoID(for:))).intersection(known)
        anchor = anchor.map(visibleVideoID(for:))

        ThumbnailCache.removeAll()
        revision += 1
    }

    private func visibleVideoID(for id: String) -> String {
        pairs.first { $0.value.saved?.contains(id) == true }?.key ?? id
    }

    /// Show one video selected in All Videos.
    func reveal(videoID: String) {
        let visible = visibleVideoID(for: videoID)
        guard entries.contains(where: { $0.id == visible }) else { return }
        section = .allVideos
        videoSelection = [visible]
    }

    /// Show one Wallpaper Engine wallpaper selected in All Wallpapers.
    func reveal(downloadID: String) {
        guard workshop.item(downloadID) != nil else { return }
        section = .workshopAll
        workshop.staged = [downloadID]
    }

    // MARK: - Selection

    private var orderedIDs: [String] {
        switch section.content {
        case .videos: videoRows.map(\.id)
        case .downloads: workshopRows.map(\.id)
        case .catalog: catalog.items.map(\.id)
        }
    }

    /// The current section's selection.
    private(set) var selection: Set<String> {
        get {
            switch section.content {
            case .videos: videoSelection
            case .downloads: workshop.staged
            case .catalog: catalog.selection
            }
        }
        set {
            switch section.content {
            case .videos: videoSelection = newValue
            case .downloads: workshop.staged = newValue
            case .catalog: catalog.selection = newValue
            }
        }
    }

    /// A click on a grid tile, with Finder's modifier rules. The Workshop listing selects
    /// one wallpaper at a time.
    func click(_ id: String) {
        guard section.content != .catalog else {
            selection = [id]
            anchor = id
            return
        }
        var current = selection
        GridSelection.click(id, in: orderedIDs, selection: &current, anchor: &anchor)
        selection = current
    }

    func clearSelection() {
        anchor = nil
        if hasSelection {
            selection = []
        }
    }

    /// Move a grid's selection one tile in `direction`, `columns` tiles per row. Returns the
    /// tile now selected.
    @discardableResult
    func moveSelection(_ direction: MoveCommandDirection, columns: Int) -> String? {
        let ordered = orderedIDs
        guard !ordered.isEmpty else { return nil }
        let from = anchor.flatMap(ordered.firstIndex(of:)) ?? ordered.firstIndex(where: selection.contains)
        guard let from else {
            selection = [ordered[0]]
            anchor = ordered[0]
            return ordered[0]
        }
        let step = switch direction {
        case .left: -1
        case .right: 1
        case .up: -columns
        case .down: columns
        @unknown default: 0
        }
        let target = from + step
        guard ordered.indices.contains(target) else { return ordered[from] }
        selection = [ordered[target]]
        anchor = ordered[target]
        return ordered[target]
    }

    // MARK: - Quick Look

    /// A download previews as its video once made, as its Workshop picture before.
    private func quickLookURL(for item: WorkshopItem) -> URL? {
        video(for: item).map(VideoDeploymentService.videoURL(for:)) ?? item.preview
    }

    /// Show `id`, or the first selected item, in Quick Look; a second call closes it.
    func toggleQuickLook(_ id: String? = nil) {
        guard quickLookURL == nil else {
            quickLookURL = nil
            return
        }
        switch section.content {
        case .videos:
            let entry = id.flatMap { id in entries.first { $0.id == id } }
                ?? videoRows.first { videoSelection.contains($0.id) }?.entry
            quickLookURL = entry.map(VideoDeploymentService.videoURL(for:))
        case .downloads:
            let item = id.flatMap(workshop.item) ?? workshopRows.first { workshop.staged.contains($0.id) }?.item
            quickLookURL = item.flatMap(quickLookURL(for:))
        case .catalog:
            break
        }
    }

    // MARK: - Intents

    func addVideo() {
        manager.openVideoChooser()
    }

    func addFolder() {
        workshop.chooseFolder()
    }

    func importVideos(_ urls: [URL]) {
        Task(name: "Import dropped videos") {
            for url in urls {
                await manager.importVideo(url)
            }
        }
    }

    func showInFinder(_ ids: Set<String>) {
        let urls: [URL] = switch section.content {
        case .videos: entries.filter { ids.contains($0.id) }.flatMap { entry in
                (pairs[entry.id]?.members ?? [entry]).map(VideoDeploymentService.videoURL(for:))
            }
        case .downloads: workshop.items.filter { ids.contains($0.id) }.map(\.folder)
        case .catalog: []
        }
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func showSelectionInFinder() {
        showInFinder(selection)
    }

    func optimizationTarget(for ids: Set<String>) -> VideoOptimizationTarget? {
        guard section.content == .videos, ids.count == 1, let id = ids.first,
              let entry = entries.first(where: { $0.id == id }) else { return nil }
        return VideoOptimizationTarget(entry: entry, pair: pairs[id])
    }

    func pairAction(for ids: Set<String>) -> VideoPairSelection? {
        guard section.content == .videos else { return nil }
        if ids.count == 1, let id = ids.first, let pair = pairs[id],
           pair.saved?.deletionPending != true, !isEditingBlocked(pair) {
            return pair
        }
        guard ids.count == 2 else { return nil }
        let selected = entries.filter { ids.contains($0.id) }
        guard selected.count == 2, selected.allSatisfy({ pairs[$0.id] == nil }) else { return nil }
        let pair = VideoPairSelection(first: selected[0], second: selected[1], saved: nil)
        return isEditingBlocked(pair) ? nil : pair
    }

    private func isEditingBlocked(_ pair: VideoPairSelection) -> Bool {
        guard let working = manager.optimizingEntryID else { return false }
        return pair.id == working || pair.members.contains { $0.id == working }
    }

    func completePairEdit(_ ids: Set<String>) {
        reload()
        if section == .lightDarkPairs {
            section = .allVideos
        }
        videoSelection = ids.intersection(videoRows.map(\.id))
    }

    func swapAppearances(_ pair: VideoPairSelection) {
        guard let record = pair.saved, pair.members.count == 2, !isEditingBlocked(pair) else { return }
        do {
            try record.edit(in: VideoDeploymentService.videosFolderURL, split: false)
            VideoDeploymentService.notifyExtensionLibraryChanged()
        } catch {
            libraryError = error.localizedDescription
        }
    }

    func renameVideo(entryID: String, to name: String, memberID: String? = nil) {
        do {
            if let pair = pairs[entryID], let record = pair.saved {
                if let memberID {
                    guard let member = pair.members.first(where: { $0.id == memberID }) else { throw PairIssue.changed }
                    if record.name == nil, memberID == entryID {
                        try record.rename(to: member.name, in: VideoDeploymentService.videosFolderURL)
                    }
                    try VideoDeploymentService.renameEntry(entryID: memberID, to: name)
                } else {
                    try record.rename(to: name, in: VideoDeploymentService.videosFolderURL)
                    VideoDeploymentService.notifyExtensionLibraryChanged()
                }
            } else {
                guard memberID == nil else { throw PairIssue.changed }
                try VideoDeploymentService.renameEntry(entryID: entryID, to: name)
            }
        } catch {
            libraryError = error.localizedDescription
        }
    }

    /// Ask to delete `ids`, or the selected videos.
    func requestDelete(_ ids: Set<String>? = nil) {
        guard section.content == .videos else { return }
        let ids = ids ?? videoSelection
        let selected = entries.filter { ids.contains($0.id) }
        guard !selected.isEmpty else { return }
        pendingDelete = LibraryDeletion(entries: selected, pairs: pairs.filter { ids.contains($0.key) })
    }

    func confirmDelete() {
        guard let deletion = pendingDelete else { return }
        pendingDelete = nil
        var failures: [String] = []
        for entry in deletion.entries {
            do {
                if let record = deletion.pairs[entry.id]?.saved {
                    try VideoDeploymentService.removePair(record)
                } else {
                    try VideoDeploymentService.removeVideo(entryID: entry.id)
                }
                videoSelection.remove(entry.id)
            } catch {
                failures.append("\(entry.name) — \(error.localizedDescription)")
            }
        }
        reload()
        workshop.refresh()
        if !failures.isEmpty {
            libraryError = failures.joined(separator: "\n")
        }
    }

    /// Ask for the Make Videos sheet for `ids`, or for the selected downloads. Every way
    /// of making a video goes through the sheet, which names the wallpapers and the size.
    func requestMakeVideos(_ ids: Set<String>? = nil) {
        guard section.content == .downloads else { return }
        if let ids, ids != workshop.staged {
            workshop.staged = ids
        }
        guard !renderableSelection.isEmpty else { return }
        isMakeVideosPresented = true
    }

    /// Show or hide the inspector.
    func toggleInspector() {
        let opens = !showInspector
        change(opening: opens, needs: LibraryLayout.windowMinWidth(sidebar: showsSidebar, inspector: true)) {
            showInspector.toggle()
        }
    }

    /// Show or hide the sidebar, as the split view asks.
    func setColumnVisibility(_ visibility: NavigationSplitViewVisibility) {
        let opens = visibility != .detailOnly && !showsSidebar
        change(opening: opens, needs: LibraryLayout.windowMinWidth(sidebar: true, inspector: showInspector)) {
            columnVisibility = visibility
        }
    }

    /// Show or hide a column. A window narrower than `width` is too narrow for a column
    /// that opens, so it widens first; a window that cannot widen keeps the column shut.
    /// A column that opens in too narrow a window is pushed aside by AppKit with the whole
    /// split view, or ends its layout in an exception.
    private func change(opening: Bool, needs width: CGFloat, _ body: () -> Void) {
        guard !opening || makeRoom(width) else { return }
        body()
    }

    /// Widen the library window to `width`, moving it left where the screen ends. False
    /// when the window stays narrower, as in full screen beside another app.
    private func makeRoom(_ width: CGFloat) -> Bool {
        guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue == LibraryLayout.windowID }) else {
            return true
        }
        var frame = window.frame
        guard frame.width < width else { return true }
        frame.size.width = width
        if let visible = window.screen?.visibleFrame {
            frame.origin.x = max(visible.minX, min(frame.origin.x, visible.maxX - width))
        }
        window.setFrame(frame, display: true)
        return window.frame.width >= width
    }

    func stepIconSize(by steps: Double) {
        iconSize = LibraryIconSize.clamped(iconSize + steps * LibraryIconSize.step)
    }

    func openWallpaperSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension")!)
    }
}
