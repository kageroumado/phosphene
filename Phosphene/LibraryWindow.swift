import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The library: a sidebar of places, a browser of the selected place as icons or a
/// sortable list, and an inspector for what is selected.
struct LibraryWindow: View {
    @Bindable var manager: PhospheneManager
    var initialSelectionID: String?

    @AppStorage(LibrarySection.storageKey) private var section: LibrarySection = .allVideos
    @AppStorage("libraryViewMode") private var viewMode: LibraryViewMode = .icons
    @AppStorage("libraryIconSize") private var iconSize = LibraryIconSize.standard
    @State private var search = ""
    @State private var entries: [VideoDeploymentService.EntryInfo] = []
    @State private var videoSelection: Set<String> = []
    @State private var videoSort = [KeyPathComparator(\VideoRow.dateAdded, order: .reverse)]
    @State private var workshopSort = [KeyPathComparator(\WorkshopRow.modified, order: .reverse)]
    @State private var showInspector = true
    @State private var showingMakeVideos = false
    @State private var pendingDelete: Set<String>?

    private var workshop: WorkshopLibrary {
        manager.workshop
    }

    var body: some View {
        NavigationSplitView {
            LibrarySidebar(section: $section, counts: counts, workshop: workshop) {
                manager.openVideoChooser()
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 300)
        } detail: {
            detail
                .safeAreaInset(edge: .bottom, spacing: 0) { statusBar }
                .navigationTitle(sectionTitle)
                .navigationSubtitle(sectionSubtitle)
                .searchable(
                    text: $search,
                    placement: .toolbar,
                    prompt: section.isWorkshop
                        ? Text("Search Downloads") : Text("Search Videos"),
                )
                .toolbar { toolbar }
        }
        .inspector(isPresented: $showInspector) {
            inspector
                .inspectorColumnWidth(min: 260, ideal: 300, max: 380)
        }
        .frame(minWidth: 860, minHeight: 520)
        .sheet(isPresented: $showingMakeVideos) {
            MakeVideoSheet(library: workshop)
        }
        .alert(deleteTitle, isPresented: .init(
            get: { pendingDelete != nil },
            set: {
                if !$0 {
                    pendingDelete = nil
                }
            },
        )) {
            Button("Delete", role: .destructive) { deletePending() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The videos leave your library and System Settings.")
        }
        .dropDestination(for: URL.self) { urls, _ in
            importDropped(urls)
        }
        .focusedSceneValue(\.libraryActions, actions)
        // `phosphene://library/wallpaper-engine`: Sevoflurane opens the window at
        // the Wallpaper Engine section.
        .onOpenURL { url in
            if url.host == "library", url.path == "/wallpaper-engine" {
                section = .workshopDownloads
            }
        }
        .onAppear {
            loadEntries()
            if !workshop.hasScanned {
                workshop.refresh()
            }
            // Promote to a regular app for every open path (menu bar, URL scheme):
            // the window needs a Dock icon and menu bar while visible. The
            // AppDelegate's willClose observer demotes back to accessory.
            NSApplication.shared.setActivationPolicy(.regular)
            NSApplication.shared.activate()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: VideoDeploymentService.libraryChangedNotification),
        ) { _ in
            loadEntries()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            workshop.refresh()
        }
        .onChange(of: section) {
            search = ""
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var detail: some View {
        if section.isWorkshop {
            workshopContent
        } else {
            videoContent
        }
    }

    @ViewBuilder
    private var videoContent: some View {
        let rows = videoRows
        if rows.isEmpty {
            if !search.isEmpty {
                ContentUnavailableView.search(text: search)
            } else {
                videoEmptyState
            }
        } else {
            VideoBrowser(
                rows: rows.sorted(using: videoSort), selection: $videoSelection, sortOrder: $videoSort,
                mode: viewMode, iconSize: iconSize, manager: manager,
                onDelete: { pendingDelete = $0.isEmpty ? nil : $0 },
            )
        }
    }

    @ViewBuilder
    private var workshopContent: some View {
        let rows = workshopRows
        if rows.isEmpty {
            if !search.isEmpty {
                ContentUnavailableView.search(text: search)
            } else {
                workshopEmptyState
            }
        } else {
            VStack(spacing: 0) {
                WorkshopIntro(library: workshop)
                WorkshopBrowser(
                    rows: rows.sorted(using: workshopSort), library: workshop, sortOrder: $workshopSort,
                    mode: viewMode, iconSize: iconSize,
                )
            }
        }
    }

    @ViewBuilder
    private var videoEmptyState: some View {
        switch section {
        case .inUse:
            ContentUnavailableView {
                Label("No Wallpaper in Use", systemImage: "play.rectangle")
            } description: {
                Text("Choose a Phosphene video in System Settings › Wallpaper.")
            } actions: {
                Button("Open Wallpaper Settings") { openWallpaperSettings() }
            }
        case .fromWorkshop:
            ContentUnavailableView {
                Label("No Videos from Wallpaper Engine", systemImage: "wand.and.sparkles")
            } description: {
                Text("Select Wallpaper Engine downloads and choose Make Videos.")
            } actions: {
                Button("Show Downloads") { section = .workshopDownloads }
            }
        default:
            ContentUnavailableView {
                Label("No Videos", systemImage: "film.stack")
            } description: {
                Text("Add a video to use as your wallpaper, or drop one here.")
            } actions: {
                Button("Add Video…") { manager.openVideoChooser() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    @ViewBuilder
    private var workshopEmptyState: some View {
        if section == .workshopNotMade, !workshop.items.isEmpty {
            ContentUnavailableView {
                Label("Every Download Has a Video", systemImage: "checkmark.circle")
            } description: {
                Text("Subscribe to more wallpapers on the Steam Workshop and they appear here.")
            } actions: {
                Button("Open Steam Workshop") { workshop.openWorkshop() }
            }
        } else if !workshop.sources.isEmpty {
            ContentUnavailableView {
                Label("No Downloads Yet", systemImage: "square.and.arrow.down")
            } description: {
                Text("Wallpaper Engine is installed. Subscribe to wallpapers on the Steam Workshop and they appear here.")
            } actions: {
                Button("Open Steam Workshop") { workshop.openWorkshop() }
                    .buttonStyle(.borderedProminent)
            }
        } else {
            VStack(spacing: 0) {
                ContentUnavailableView {
                    Label("Wallpaper Engine Wallpapers on Your Mac", systemImage: "wand.and.sparkles")
                } description: {
                    if workshop.isSevofluraneInstalled {
                        Text("""
                        Subscribe to wallpapers on the Steam Workshop and Phosphene makes them into video wallpapers. \
                        In Sevoflurane’s Steam, install Wallpaper Engine first.
                        """)
                    } else {
                        Text("""
                        Subscribe to wallpapers on the Steam Workshop and Phosphene makes them into video wallpapers. \
                        Wallpaper Engine runs in Windows Steam; Sevoflurane brings that Steam to your Mac, free, \
                        from the maker of Phosphene.
                        """)
                    }
                } actions: {
                    if workshop.isSevofluraneInstalled {
                        Button("Open Steam Workshop") { workshop.openWorkshop() }
                            .buttonStyle(.borderedProminent)
                    } else {
                        Button("Get Sevoflurane") { NSWorkspace.shared.open(WorkshopDiscovery.sevofluraneURL) }
                            .buttonStyle(.borderedProminent)
                            .help("Sevoflurane runs Windows Steam on your Mac. It’s free, from the maker of Phosphene.")
                    }
                    Button("Add Folder…") { workshop.chooseFolder() }
                        .help("A Steam folder from CrossOver or Whisky, or any folder of Wallpaper Engine wallpapers")
                }
                Text("Wallpaper Engine is a trademark of Wallpaper Engine Team; Steam is a trademark of Valve Corporation. Phosphene is an independent app.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 48)
                    .padding(.bottom, 20)
            }
        }
    }

    // MARK: - Rows

    private var inUseIDs: Set<String> {
        Set(manager.prefsService.selections.map(\.videoID))
    }

    private var workshopEntryIDs: Set<String> {
        Set(workshop.records.values.map(\.entryID))
    }

    private var videoRows: [VideoRow] {
        let inUse = inUseIDs
        let fromWorkshop = workshopEntryIDs
        return entries.compactMap { entry -> VideoRow? in
            let row = VideoRow(
                entry: entry, isInUse: inUse.contains(entry.id), isFromWorkshop: fromWorkshop.contains(entry.id),
                fileSize: VideoDeploymentService.fileSize(for: entry) ?? 0,
            )
            switch section {
            case .inUse where !row.isInUse: return nil
            case .fromWorkshop where !row.isFromWorkshop: return nil
            default: break
            }
            guard search.isEmpty || entry.name.localizedStandardContains(search) else { return nil }
            return row
        }
    }

    private var workshopRows: [WorkshopRow] {
        let labels = Dictionary(workshop.sources.map { ($0.id, $0.label) }) { first, _ in first }
        return workshop.items.compactMap { item -> WorkshopRow? in
            let status = workshop.status(of: item)
            switch section {
            case .workshopNotMade:
                switch status {
                case .available, .outdated, .failed, .queued, .rendering: break
                default: return nil
                }
            case let .workshopSource(id) where item.sourceID != id:
                return nil
            default:
                break
            }
            guard search.isEmpty || item.title.localizedStandardContains(search) else { return nil }
            return WorkshopRow(item: item, status: status, sourceLabel: labels[item.sourceID] ?? "")
        }
    }

    private var counts: LibrarySidebar.Counts {
        let inUse = inUseIDs
        let fromWorkshop = workshopEntryIDs
        return LibrarySidebar.Counts(
            all: entries.count,
            inUse: entries.count { inUse.contains($0.id) },
            fromWorkshop: entries.count { fromWorkshop.contains($0.id) },
        )
    }

    // MARK: - Titles

    private var sectionTitle: String {
        switch section {
        case .allVideos: String(localized: "All Videos")
        case .inUse: String(localized: "In Use")
        case .fromWorkshop: String(localized: "From Workshop")
        case .workshopDownloads: String(localized: "Wallpaper Engine")
        case .workshopNotMade: String(localized: "Not Made Yet")
        case let .workshopSource(id): workshop.sources.first { $0.id == id }?.label ?? String(localized: "Wallpaper Engine")
        }
    }

    private var sectionSubtitle: String {
        if section.isWorkshop {
            let count = workshopRows.count
            return String(localized: "\(count) wallpapers")
        }
        let rows = videoRows
        let bytes = rows.map(\.fileSize).reduce(0, +)
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        return String(localized: "\(rows.count) videos · \(size)")
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem {
            Picker("View", selection: $viewMode) {
                Label("Icons", systemImage: "square.grid.2x2").tag(LibraryViewMode.icons)
                Label("List", systemImage: "list.bullet").tag(LibraryViewMode.list)
            }
            .pickerStyle(.segmented)
            .help("Show as icons or as a list")
        }
        ToolbarSpacer(.fixed)
        if section.isWorkshop {
            ToolbarItem {
                Button {
                    workshop.openWorkshop()
                } label: {
                    Label("Steam Workshop", systemImage: "safari")
                }
                .help("Open the Wallpaper Engine Workshop in Steam")
            }
            ToolbarItem {
                Button {
                    showingMakeVideos = true
                } label: {
                    Label(makeVideosTitle, systemImage: "film.stack")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.glassProminent)
                .disabled(renderableSelection.isEmpty)
                .help("Turn the selected wallpapers into looping videos")
            }
        } else {
            ToolbarItem {
                Button {
                    manager.openVideoChooser()
                } label: {
                    Label("Add Video", systemImage: "plus")
                }
                .help("Add a video to the library")
            }
        }
        ToolbarSpacer(.fixed)
        ToolbarItem {
            Button {
                showInspector.toggle()
            } label: {
                Label("Inspector", systemImage: "sidebar.trailing")
            }
            .help(showInspector ? "Hide Inspector" : "Show Inspector")
        }
    }

    private var renderableSelection: Set<String> {
        workshop.staged.filter { workshop.assessments[$0]?.isRenderable ?? false }
    }

    private var makeVideosTitle: String {
        let count = renderableSelection.count
        switch count {
        case 0: return String(localized: "Make Videos")
        case 1: return String(localized: "Make Video")
        default: return String(localized: "Make \(count) Videos")
        }
    }

    // MARK: - Inspector

    @ViewBuilder
    private var inspector: some View {
        if section.isWorkshop {
            let selected = workshop.staged.compactMap { workshop.item($0) }
            if selected.count == 1, let item = selected.first {
                WorkshopInspectorView(item: item, library: workshop) { entryID in
                    section = .allVideos
                    videoSelection = [entryID]
                }
            } else if selected.count > 1 {
                MultipleSelectionInspector(
                    count: selected.count,
                    detail: String(localized: "\(renderableSelection.count) can become videos"),
                    actionTitle: makeVideosTitle,
                    action: renderableSelection.isEmpty ? nil : { showingMakeVideos = true },
                )
            } else {
                emptyInspector
            }
        } else {
            let selected = entries.filter { videoSelection.contains($0.id) }
            if selected.count == 1, let entry = selected.first {
                VideoInspectorView(entry: entry, manager: manager)
            } else if selected.count > 1 {
                let bytes = selected.compactMap { VideoDeploymentService.fileSize(for: $0) }.reduce(0, +)
                MultipleSelectionInspector(
                    count: selected.count,
                    detail: ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file),
                    actionTitle: String(localized: "Delete \(selected.count) Videos…"),
                    action: { pendingDelete = Set(selected.map(\.id)) },
                    isDestructive: true,
                )
            } else {
                emptyInspector
            }
        }
    }

    private var emptyInspector: some View {
        ContentUnavailableView {
            Label("No Selection", systemImage: "sidebar.right")
        } description: {
            Text(section.isWorkshop
                ? "Select wallpapers to see what Phosphene can make of them."
                : "Select a video to view its details.")
        }
    }

    // MARK: - Status Bar

    private var statusBar: some View {
        HStack(spacing: 10) {
            if let current = workshop.current.flatMap(workshop.item) {
                ProgressView(value: workshop.progress)
                    .progressViewStyle(.circular)
                    .controlSize(.mini)
                Text(renderingSummary(current))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Stop") { workshop.cancelAll() }
                    .buttonStyle(.link)
            } else {
                Button {
                    openWallpaperSettings()
                } label: {
                    Text("Wallpapers apply in System Settings \(Image(systemName: "arrow.up.right"))")
                }
                .buttonStyle(.plain)
                .help("Open macOS Wallpaper Settings")
            }
            Spacer()
            if viewMode == .icons {
                Image(systemName: "photo")
                    .imageScale(.small)
                Slider(value: $iconSize, in: LibraryIconSize.range)
                    .controlSize(.mini)
                    .frame(width: 96)
                    .help("Icon size")
                    .accessibilityLabel("Icon size")
                Image(systemName: "photo")
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private func renderingSummary(_ item: WorkshopItem) -> String {
        let percent = workshop.progress.formatted(.percent.precision(.fractionLength(0)))
        let waiting = workshop.queue.count
        let base = String(localized: "Making “\(item.title)” · \(percent)")
        return waiting > 0 ? String(localized: "\(base) · \(waiting) waiting") : base
    }

    // MARK: - Actions

    private var actions: LibraryActions {
        LibraryActions(
            addVideo: { manager.openVideoChooser() },
            addFolder: { workshop.chooseFolder() },
            makeVideos: renderableSelection.isEmpty || !section.isWorkshop ? nil : { showingMakeVideos = true },
            showAsIcons: { viewMode = .icons },
            showAsList: { viewMode = .list },
            largerIcons: { iconSize = min(LibraryIconSize.range.upperBound, iconSize + LibraryIconSize.step) },
            smallerIcons: { iconSize = max(LibraryIconSize.range.lowerBound, iconSize - LibraryIconSize.step) },
            viewMode: viewMode,
        )
    }

    private var deleteTitle: String {
        let count = pendingDelete?.count ?? 0
        if count == 1, let id = pendingDelete?.first, let entry = entries.first(where: { $0.id == id }) {
            return String(localized: "Delete “\(entry.name)”?")
        }
        return String(localized: "Delete \(count) Videos?")
    }

    private func deletePending() {
        for id in pendingDelete ?? [] {
            manager.removeVideo(entryID: id)
        }
        videoSelection.subtract(pendingDelete ?? [])
        pendingDelete = nil
        loadEntries()
        workshop.refresh()
    }

    private func importDropped(_ urls: [URL]) {
        let videoTypes: [UTType] = [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        let videos = urls.filter { url in
            guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
            return videoTypes.contains { type.conforms(to: $0) }
        }
        guard !videos.isEmpty else { return }
        Task {
            for url in videos {
                await manager.importVideo(url)
            }
        }
    }

    private func openWallpaperSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension")!)
    }

    private func loadEntries() {
        entries = VideoDeploymentService.listEntries()
        videoSelection = videoSelection.filter { id in entries.contains { $0.id == id } }
        if videoSelection.isEmpty, let initialSelectionID, entries.contains(where: { $0.id == initialSelectionID }) {
            videoSelection = [initialSelectionID]
        }
    }
}

// MARK: - Pieces

/// One line at the top of a Wallpaper Engine list saying what the list is for.
private struct WorkshopIntro: View {
    @Bindable var library: WorkshopLibrary

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle")
            Text("Subscribe on the Steam Workshop and downloads appear here. Select wallpapers, then choose Make Videos.")
                .lineLimit(2)
            Spacer(minLength: 0)
            Button("Open Workshop") { library.openWorkshop() }
                .controlSize(.small)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }
}

/// The inspector when several things are selected.
private struct MultipleSelectionInspector: View {
    let count: Int
    let detail: String
    let actionTitle: String
    let action: (() -> Void)?
    var isDestructive = false

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.secondary)
            Text("\(count) Selected")
                .font(.headline)
            Text(detail)
                .foregroundStyle(.secondary)
            if let action {
                Button(role: isDestructive ? .destructive : nil, action: action) {
                    Text(actionTitle)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .padding(.horizontal, 14)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(14)
    }
}

// MARK: - Menu commands

/// The library window's actions, published to the menu bar.
struct LibraryActions {
    let addVideo: () -> Void
    let addFolder: () -> Void
    let makeVideos: (() -> Void)?
    let showAsIcons: () -> Void
    let showAsList: () -> Void
    let largerIcons: () -> Void
    let smallerIcons: () -> Void
    let viewMode: LibraryViewMode
}

extension FocusedValues {
    @Entry var libraryActions: LibraryActions?
}

/// Every toolbar action also lives in the menu bar, with keyboard shortcuts.
struct LibraryCommands: Commands {
    @FocusedValue(\.libraryActions) private var actions

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Add Video…") { actions?.addVideo() }
                .keyboardShortcut("o")
                .disabled(actions == nil)
            Button("Add Wallpaper Engine Folder…") { actions?.addFolder() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(actions == nil)
            Divider()
            Button("Make Videos…") { actions?.makeVideos?() }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .disabled(actions?.makeVideos == nil)
        }
        CommandGroup(before: .sidebar) {
            Toggle("as Icons", isOn: Binding(
                get: { actions?.viewMode == .icons },
                set: {
                    if $0 {
                        actions?.showAsIcons()
                    }
                },
            ))
            .keyboardShortcut("1")
            .disabled(actions == nil)
            Toggle("as List", isOn: Binding(
                get: { actions?.viewMode == .list },
                set: {
                    if $0 {
                        actions?.showAsList()
                    }
                },
            ))
            .keyboardShortcut("2")
            .disabled(actions == nil)
            Divider()
            Button("Make Icons Larger") { actions?.largerIcons() }
                .keyboardShortcut("+")
                .disabled(actions?.viewMode != .icons)
            Button("Make Icons Smaller") { actions?.smallerIcons() }
                .keyboardShortcut("-")
                .disabled(actions?.viewMode != .icons)
            Divider()
        }
        SidebarCommands()
        InspectorCommands()
    }
}
