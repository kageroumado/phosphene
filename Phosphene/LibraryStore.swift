import AppKit
import SwiftUI

/// The library window's state and intents: the place shown and how, what is selected,
/// and what the user asked to do with it.
@Observable
final class LibraryStore {
    @ObservationIgnored private unowned let manager: PhospheneManager

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
    var videoSort = [KeyPathComparator(\VideoRow.dateAdded, order: .reverse)]
    var workshopSort = [KeyPathComparator(\WorkshopRow.modified, order: .reverse)]

    // MARK: - Selection and requests

    var videoSelection: Set<String> = []
    var isMakeVideosPresented = false
    /// The videos a delete confirmation is asking about.
    var pendingDelete: Set<String>?

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
    private(set) var entries: [VideoDeploymentService.EntryInfo] = []
    @ObservationIgnored private var fileSizes: [String: Int64] = [:]
    @ObservationIgnored private var anchor: String?

    init(manager: PhospheneManager) {
        self.manager = manager
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
        Set(manager.prefsService.selections.map(\.videoID))
    }

    /// The videos of the current section that match the search, in sort order.
    var videoRows: [VideoRow] {
        let inUse = inUseIDs
        return entries.compactMap { entry -> VideoRow? in
            let row = VideoRow(entry: entry, isInUse: inUse.contains(entry.id), fileSize: fileSizes[entry.id] ?? 0)
            if section == .inUse, !row.isInUse {
                return nil
            }
            guard search.isEmpty || entry.name.localizedStandardContains(search) else { return nil }
            return row
        }
        .sorted(using: videoSort)
    }

    /// The downloads of the current section that match the search, in sort order.
    var workshopRows: [WorkshopRow] {
        let labels = Dictionary(workshop.sources.map { ($0.id, $0.label) }) { first, _ in first }
        let entriesByID = Dictionary(entries.map { ($0.id, $0) }) { first, _ in first }
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
        var wallpapers = 0
        var readyToMake = 0
    }

    var counts: Counts {
        let inUse = inUseIDs
        return Counts(
            all: entries.count,
            inUse: entries.count { inUse.contains($0.id) },
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
        return entries.first { $0.id == entryID }
    }

    /// The size of a library video's file, as read at the last reload.
    func fileSize(ofVideo entryID: String) -> Int64? {
        fileSizes[entryID]
    }

    var hasSelection: Bool {
        section.isWorkshop ? !workshop.staged.isEmpty : !videoSelection.isEmpty
    }

    // MARK: - Loading

    /// Read the library from disk. Thumbnails are decoded again: a replaced video keeps
    /// its thumbnail's file name.
    func reload() {
        entries = VideoDeploymentService.listEntries()
        fileSizes = Dictionary(uniqueKeysWithValues: entries.map { entry in
            (entry.id, VideoDeploymentService.fileSize(for: entry) ?? 0)
        })
        let known = Set(entries.map(\.id))
        if !videoSelection.isSubset(of: known) {
            videoSelection.formIntersection(known)
        }
        ThumbnailCache.removeAll()
        revision += 1
    }

    /// Show one video selected in All Videos.
    func reveal(videoID: String) {
        guard entries.contains(where: { $0.id == videoID }) else { return }
        section = .allVideos
        videoSelection = [videoID]
    }

    // MARK: - Selection

    private var orderedIDs: [String] {
        section.isWorkshop ? workshopRows.map(\.id) : videoRows.map(\.id)
    }

    private var selection: Set<String> {
        get { section.isWorkshop ? workshop.staged : videoSelection }
        set {
            if section.isWorkshop {
                workshop.staged = newValue
            } else {
                videoSelection = newValue
            }
        }
    }

    /// A click on a grid tile, with Finder's modifier rules.
    func click(_ id: String) {
        var current = selection
        GridSelection.click(id, in: orderedIDs, selection: &current, anchor: &anchor)
        selection = current
    }

    func clearSelection() {
        guard hasSelection else { return }
        selection = []
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
        if section.isWorkshop {
            let item = id.flatMap(workshop.item) ?? workshopRows.first { workshop.staged.contains($0.id) }?.item
            quickLookURL = item.flatMap(quickLookURL(for:))
        } else {
            let entry = id.flatMap { id in entries.first { $0.id == id } }
                ?? videoRows.first { videoSelection.contains($0.id) }?.entry
            quickLookURL = entry.map(VideoDeploymentService.videoURL(for:))
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
        let urls: [URL] = if section.isWorkshop {
            workshop.items.filter { ids.contains($0.id) }.map(\.folder)
        } else {
            entries.filter { ids.contains($0.id) }.map(VideoDeploymentService.videoURL(for:))
        }
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func showSelectionInFinder() {
        showInFinder(section.isWorkshop ? workshop.staged : videoSelection)
    }

    /// Ask to delete `ids`, or the selected videos.
    func requestDelete(_ ids: Set<String>? = nil) {
        guard !section.isWorkshop else { return }
        let ids = ids ?? videoSelection
        pendingDelete = ids.isEmpty ? nil : ids
    }

    func confirmDelete() {
        let ids = pendingDelete ?? []
        pendingDelete = nil
        for id in ids {
            manager.removeVideo(entryID: id)
        }
        videoSelection.subtract(ids)
        reload()
        workshop.refresh()
    }

    var deleteTitle: String {
        let count = pendingDelete?.count ?? 0
        if count == 1, let id = pendingDelete?.first, let entry = entries.first(where: { $0.id == id }) {
            return String(localized: "Delete “\(entry.name)”?")
        }
        return String(localized: "Delete \(count) Videos?")
    }

    var deleteMessage: String {
        let count = pendingDelete?.count ?? 0
        return String(localized: "The \(count) videos leave your library and System Settings.")
    }

    /// Ask for the Make Videos sheet for `ids`, or for the selected downloads. Every way
    /// of making a video goes through the sheet, which names the wallpapers and the size.
    func requestMakeVideos(_ ids: Set<String>? = nil) {
        guard section.isWorkshop else { return }
        if let ids, ids != workshop.staged {
            workshop.staged = ids
        }
        guard !renderableSelection.isEmpty else { return }
        isMakeVideosPresented = true
    }

    func stepIconSize(by steps: Double) {
        iconSize = LibraryIconSize.clamped(iconSize + steps * LibraryIconSize.step)
    }

    func openWallpaperSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension")!)
    }
}
