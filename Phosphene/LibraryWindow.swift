import AppKit
import os
import SwiftUI
import UniformTypeIdentifiers

/// The library: a sidebar of places, a browser of the selected place as icons or a
/// sortable list, and an inspector for what is selected.
struct LibraryWindow: View {
    @Environment(\.appearsActive) private var appearsActive
    @Bindable var manager: PhospheneManager
    var initialSelectionID: String?

    @AppStorage(LibrarySection.storageKey) private var section: LibrarySection = .allVideos
    @AppStorage("libraryViewMode") private var viewMode: LibraryViewMode = .icons
    @AppStorage("libraryIconSize") private var iconSize = LibraryIconSize.standard
    @State private var search = ""
    @State private var searchPresented = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var entries: [VideoDeploymentService.EntryInfo] = []
    @State private var files: [String: FileIdentity] = [:]
    @State private var videoSelection: Set<String> = []
    @State private var videoSort = [KeyPathComparator(\VideoRow.dateAdded, order: .reverse)]
    @State private var workshopSort = [KeyPathComparator(\WorkshopRow.modified, order: .reverse)]
    @State private var showInspector = true
    @State private var showingMakeVideos = false
    @State private var pairs: [String: VideoPairSelection] = [:]
    @State private var pairSheet: VideoPairSelection?
    @State private var pendingDelete: LibraryDeletion?
    @State private var pendingVariantRemoval: VideoOptimizationTarget?
    @State private var convertToSDRSelection: String?
    @State private var optimizationUnavailableReason: String?
    @State private var deletionNotice: String?

    private var workshop: WorkshopLibrary {
        manager.workshop
    }

    var body: some View {
        columns
            .sheet(item: $pairSheet) { selection in
                VideoPairSheet(selection: selection) { ids in
                    loadEntries()
                    videoSelection = ids.intersection(videoRows.map(\.id))
                }
            }
            .sheet(isPresented: $showingMakeVideos) {
                MakeVideoSheet(library: workshop)
            }
            .alert(pendingDelete?.title ?? "", isPresented: .init(
                get: { pendingDelete != nil },
                set: {
                    if !$0 {
                        pendingDelete = nil
                    }
                },
            ), presenting: pendingDelete) { deletion in
                Button(deletion.isSinglePair ? "Delete Pair" : "Delete", role: .destructive) { delete(deletion) }
                Button("Cancel", role: .cancel) {}
            } message: { deletion in
                Text(verbatim: deletion.message)
            }
            .alert("Remove Variants", isPresented: Binding(
                get: { pendingVariantRemoval != nil },
                set: {
                    if !$0 {
                        pendingVariantRemoval = nil
                    }
                },
            ), presenting: pendingVariantRemoval) { target in
                Button("Remove", role: .destructive) { manager.removeVariants(for: target) }
                Button("Cancel", role: .cancel) {}
            } message: { target in
                if target.pair != nil {
                    Text("This will remove the optimized versions of both videos and keep the original pair.")
                } else {
                    Text("This will delete the optimized variants. The original video is not affected.")
                }
            }
            .alert("Can’t Optimize Video", isPresented: Binding(
                get: { optimizationUnavailableReason != nil },
                set: {
                    if !$0 {
                        optimizationUnavailableReason = nil
                    }
                },
            ), presenting: optimizationUnavailableReason) { _ in
                Button("OK", role: .cancel) {}
            } message: { reason in
                Text(verbatim: reason)
            }
            .dropDestination(for: URL.self) { urls, _ in
                importDropped(urls)
            }
            .focusedSceneValue(\.libraryActions, actions)
            // `phosphene://library/wallpaper-engine`: Sevoflurane opens the window at
            // the Wallpaper Engine section.
            .onOpenURL { url in
                guard url.host == "library" else { return }
                if url.path == "/wallpaper-engine" {
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
                loadEntries()
                workshop.refresh()
            }
            .onChange(of: section) {
                search = ""
                searchPresented = false
                if !section.isWorkshop {
                    videoSelection.formIntersection(videoRows.map(\.id))
                }
            }
            .onChange(of: search) {
                if !section.isWorkshop {
                    videoSelection.formIntersection(videoRows.map(\.id))
                }
            }
            .onChange(of: appearsActive) {
                if !appearsActive, search.isEmpty {
                    searchPresented = false
                }
            }
    }

    // MARK: - Content

    private var columns: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            LibrarySidebar(section: $section, counts: counts, workshop: workshop) {
                manager.openVideoChooser()
            }
            .navigationSplitViewColumnWidth(
                min: Layout.sidebarMin, ideal: Layout.sidebarIdeal, max: Layout.sidebarMax,
            )
        } detail: {
            // Grid and table intrinsic sizes must not feed back into the split view during live resize.
            Color.clear
                .overlay {
                    detail
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .safeAreaInset(edge: .bottom, spacing: 0) { statusBar }
                }
                .alert("Library Error", isPresented: $manager.showOptimizationAlert) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(manager.optimizationAlertMessage)
                }
                .navigationTitle(sectionTitle)
                .navigationSubtitle(sectionSubtitle)
                .toolbar { toolbar }
        }
        .navigationSplitViewStyle(.balanced)
        .inspector(isPresented: $showInspector) {
            Color.clear.overlay { inspector }
                .inspectorColumnWidth(min: Layout.inspectorMin, ideal: Layout.inspectorIdeal, max: Layout.inspectorMax)
                .toolbar { ToolbarSpacer(.flexible, placement: .principal) }
        }
        .frame(minWidth: minimumWindowWidth, minHeight: 520, alignment: .leading)
    }

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
                onDelete: requestDelete, itemMenu: videoContextMenu,
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
                    mode: viewMode, iconSize: iconSize, showVideo: showWorkshopVideo,
                )
            }
        }
    }

    @ViewBuilder
    private var videoEmptyState: some View {
        switch section {
        case .lightDarkPairs:
            ContentUnavailableView {
                Label("No Light/Dark Pairs", image: .lightDarkPair)
            } description: {
                Text("Select two videos in All Videos to create a light/dark pair.")
            } actions: {
                Button("All Videos") { section = .allVideos }
            }
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

    private func pairAction(for ids: Set<String>) -> VideoPairSelection? {
        guard !section.isWorkshop else { return nil }
        if ids.count == 1, let id = ids.first {
            return pairs[id]
        }
        guard ids.count == 2 else { return nil }
        let selected = entries.filter { ids.contains($0.id) }
        guard selected.count == 2, selected.allSatisfy({ pairs[$0.id] == nil }) else { return nil }
        return VideoPairSelection(first: selected[0], second: selected[1], saved: nil)
    }

    private func includes(_ entry: VideoDeploymentService.EntryInfo, ids: Set<String>) -> Bool {
        ids.contains(entry.id) || pairs[entry.id]?.saved.map { ids.contains($0.counterpart) } == true
    }

    private func size(of entry: VideoDeploymentService.EntryInfo) -> Int64 {
        (pairs[entry.id]?.members ?? [entry]).reduce(0) { $0 + Int64(clamping: files[$1.id]?.size ?? 0) }
    }

    private var videoRows: [VideoRow] {
        let inUse = inUseIDs
        let fromWorkshop = workshopEntryIDs
        return entries.compactMap { entry -> VideoRow? in
            let members = pairs[entry.id]?.members ?? [entry]
            let row = VideoRow(
                entry: entry, pair: pairs[entry.id], isInUse: includes(entry, ids: inUse), isFromWorkshop: includes(entry, ids: fromWorkshop),
                fileSize: size(of: entry),
            )
            switch section {
            case .lightDarkPairs where row.pair == nil: return nil
            case .inUse where !row.isInUse: return nil
            case .fromWorkshop where !row.isFromWorkshop: return nil
            default: break
            }
            guard search.isEmpty || entry.name.localizedStandardContains(search)
                || members.contains(where: { $0.name.localizedStandardContains(search) }) else { return nil }
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
            pairs: pairs.count,
            inUse: entries.count { includes($0, ids: inUse) },
            fromWorkshop: entries.count { includes($0, ids: fromWorkshop) },
        )
    }

    // MARK: - Titles

    private var sectionTitle: String {
        switch section {
        case .allVideos: String(localized: "All Videos")
        case .lightDarkPairs: String(localized: "Light/Dark Pairs")
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
        if section == .lightDarkPairs {
            return rows.count == 1 ? String(localized: "1 pair · \(size)") : String(localized: "\(rows.count) pairs · \(size)")
        }
        if rows.count == 1 {
            return String(localized: "1 video · \(size)")
        }
        return String(localized: "\(rows.count) videos · \(size)")
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem { viewPicker.pickerStyle(.segmented) }
        ToolbarSpacer(.fixed)
        ToolbarItemGroup { browserActions }
        ToolbarSpacer(.fixed)
        if section.isWorkshop {
            ToolbarItemGroup {
                WorkshopItemActions(ids: workshop.staged, library: workshop, showVideo: showWorkshopVideo)
            }
        } else if !videoSelection.isEmpty {
            ToolbarItemGroup {
                primaryVideoActions(for: videoSelection)
            }
            .highVisibilityPriority()
            ToolbarItemGroup {
                finderButton(for: videoSelection)
                videoEditingActions(for: videoSelection, inToolbar: true)
            }
            ToolbarSpacer(.fixed)
        }
        ToolbarItem { inspectorButton }
        searchItem.highVisibilityPriority()
    }

    @ToolbarContentBuilder
    private var searchItem: some ToolbarContent {
        if searchPresented {
            ToolbarSpacer(.fixed)
            ToolbarItem {
                LibrarySearchField(text: $search, prompt: searchPrompt) {
                    search = ""
                    searchPresented = false
                }
                .frame(width: 144)
            }
        } else {
            ToolbarItem {
                Button {
                    searchPresented = true
                } label: {
                    Label(searchPrompt, systemImage: "magnifyingglass")
                }
                .keyboardShortcut("f")
            }
        }
    }

    private var viewPicker: some View {
        Picker("View", selection: $viewMode) {
            Label("Icons", systemImage: "square.grid.2x2").tag(LibraryViewMode.icons)
            Label("List", systemImage: "list.bullet").tag(LibraryViewMode.list)
        }
        .help("Show as icons or as a list")
    }

    @ViewBuilder
    private var browserActions: some View {
        if section.isWorkshop {
            Button { workshop.openWorkshop() } label: {
                Label("Steam Workshop", systemImage: "safari")
            }
            .help("Open the Wallpaper Engine Workshop in Steam")
            Button { showingMakeVideos = true } label: {
                Label(makeVideosTitle, systemImage: "film.stack")
            }
            .disabled(renderableSelection.isEmpty)
            .help("Turn the selected wallpapers into looping videos")
        } else {
            Button { manager.openVideoChooser() } label: {
                Label("Add Video", systemImage: "plus")
            }
            .help("Add a video to the library")
        }
    }

    @ViewBuilder
    private func videoContextMenu(for ids: Set<String>) -> some View {
        primaryVideoActions(for: ids)
        finderButton(for: ids)
        videoEditingActions(for: ids, inToolbar: false)
    }

    @ViewBuilder
    private func primaryVideoActions(for ids: Set<String>) -> some View {
        if ids.count == 1 {
            Button("Use as Wallpaper…", systemImage: "desktopcomputer", action: openWallpaperSettings)
                .help("Phosphene wallpapers are selected in System Settings → Wallpaper")
        }
        deleteButton(for: ids)
    }

    private func finderButton(for ids: Set<String>) -> some View {
        Button("Show in Finder", systemImage: "folder") {
            let urls = entries.filter { ids.contains($0.id) }.flatMap { entry in
                (pairs[entry.id]?.members ?? [entry]).map(VideoDeploymentService.videoURL)
            }
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
        .help("Show in Finder")
    }

    private func deleteButton(for ids: Set<String>) -> some View {
        let title: LocalizedStringKey = if ids.count > 1 {
            "Delete \(ids.count) Videos…"
        } else if let id = ids.first, pairs[id] != nil {
            "Delete Pair…"
        } else {
            "Delete…"
        }
        return Button(title, systemImage: "trash", role: .destructive) { requestDelete(ids) }
            .help(Text(title))
    }

    @ViewBuilder
    private func videoEditingActions(for ids: Set<String>, inToolbar: Bool) -> some View {
        if let pair = pairAction(for: ids) {
            let label = Label(pair.actionTitle, image: .lightDarkPair)
            if inToolbar {
                Toggle(isOn: Binding(get: { pair.saved != nil }, set: { _ in pairSheet = pair })) { label }
                    .toggleStyle(.button)
                    .help(pair.actionTitle)
            } else {
                Button { pairSheet = pair } label: { label }
            }
            if let record = pair.saved {
                Button("Swap Light and Dark", systemImage: "arrow.left.arrow.right") { swap(record) }
                    .disabled(pair.members.count != 2)
            }
        }
        if ids.count == 1, let id = ids.first, let entry = entries.first(where: { $0.id == id }) {
            let target = VideoOptimizationTarget(entry: entry, pair: pairs[id])
            VideoOptimizationMenu(target: target, manager: manager, convertToSDR: Binding(
                get: { convertToSDRSelection == id },
                set: { convertToSDRSelection = $0 ? id : nil },
            ), showUnavailable: { optimizationUnavailableReason = $0 }) {
                pendingVariantRemoval = target
            }
        }
    }

    private var inspectorButton: some View {
        Button(action: toggleInspector) {
            Label("Inspector", systemImage: "sidebar.trailing")
        }
        .help(showInspector ? "Hide Inspector" : "Show Inspector")
    }

    private var searchPrompt: String {
        section.isWorkshop ? String(localized: "Search Downloads") : String(localized: "Search Videos")
    }

    private var renderableSelection: Set<String> {
        workshop.staged.filter { workshop.assessments[$0]?.isRenderable ?? false }
    }

    private func showWorkshopVideo(_ entryID: String) {
        section = .allVideos
        videoSelection = [visibleID(for: entryID)]
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
                WorkshopInspectorView(item: item, library: workshop)
            } else if selected.count > 1 {
                MultipleSelectionInspector(
                    count: selected.count,
                    detail: String(localized: "\(renderableSelection.count) can become videos"),
                )
            } else {
                emptyInspector
            }
        } else {
            let selected = entries.filter { videoSelection.contains($0.id) }
            if selected.count == 1, let entry = selected.first {
                let pair = pairs[entry.id]
                VideoInspectorView(
                    entry: entry, file: files[entry.id], pair: pair,
                    alternateFile: pair?.second.flatMap { files[$0.id] }, manager: manager,
                )
                .id(entry.id)
            } else if selected.count > 1 {
                let bytes = selected.reduce(0) { $0 + size(of: $1) }
                MultipleSelectionInspector(
                    count: selected.count,
                    detail: ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file),
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
            } else if let deletionNotice {
                Label(deletionNotice, systemImage: "checkmark.circle")
                    .lineLimit(1)
                    .help(deletionNotice)
                    .task(id: deletionNotice) {
                        do { try await Task.sleep(for: .seconds(5)) } catch { return }
                        self.deletionNotice = nil
                    }
            } else {
                Button {
                    openWallpaperSettings()
                } label: {
                    Text("Wallpapers apply in System Settings \(Image(systemName: "arrow.up.right"))")
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .buttonStyle(.plain)
                .layoutPriority(-1)
                .help("Open macOS Wallpaper Settings")
                WallpaperPlacementHelpButton()
            }
            Spacer(minLength: 0)
            if viewMode == .icons {
                // The slider goes when the column is too narrow for it, so the status bar
                // never sets the detail column's minimum width.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        Image(systemName: "photo")
                            .imageScale(.small)
                        Slider(value: $iconSize, in: LibraryIconSize.range)
                            .controlSize(.mini)
                            .frame(width: 96)
                            .help("Icon size")
                            .accessibilityLabel("Icon size")
                        Image(systemName: "photo")
                    }
                    Color.clear
                        .frame(width: 0, height: 0)
                }
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

    /// Split view children must stay compressible while AppKit negotiates divider positions.
    private var minimumWindowWidth: CGFloat {
        let sidebar = columnVisibility == .detailOnly ? 0 : Layout.sidebarMax + 1
        let inspector = showInspector ? Layout.inspectorMax + 1 : 0
        return max(500, 280 + sidebar + inspector)
    }

    private func toggleInspector() {
        guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "library" }),
              let root = window.contentView, let controller = inspectorController(in: root) else {
            showInspector.toggle()
            return
        }
        controller.toggleInspector(nil)
    }

    /// The navigation sidebar and the inspector can belong to different split controllers.
    private func inspectorController(in view: NSView) -> NSSplitViewController? {
        if let split = (view as? NSSplitView)?.delegate as? NSSplitViewController,
           split.splitViewItems.contains(where: { $0.behavior == .inspector }) {
            return split
        }
        for child in view.subviews {
            if let split = inspectorController(in: child) {
                return split
            }
        }
        return nil
    }

    private var actions: LibraryActions {
        LibraryActions(
            showsInspector: showInspector, toggleInspector: toggleInspector,
            pair: pairAction(for: videoSelection), openPair: { pairSheet = $0 },
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

    private func requestDelete(_ ids: Set<String>) {
        let selected = entries.filter { ids.contains($0.id) }
        guard !selected.isEmpty else { return }
        pendingDelete = LibraryDeletion(entries: selected, pairs: pairs.filter { ids.contains($0.key) })
    }

    private func swap(_ record: AppearancePair) {
        do {
            try record.edit(in: VideoDeploymentService.videosFolderURL, split: false)
            VideoDeploymentService.notifyExtensionLibraryChanged()
        } catch {
            manager.optimizationAlertMessage = error.localizedDescription
            manager.showOptimizationAlert = true
        }
    }

    private func delete(_ deletion: LibraryDeletion) {
        var failures = [String]()
        for entry in deletion.entries {
            do {
                if let pair = deletion.pairs[entry.id]?.saved {
                    try VideoDeploymentService.removePair(pair)
                } else {
                    try VideoDeploymentService.removeVideo(entryID: entry.id)
                }
            } catch {
                failures.append("\(entry.name) — \(error.localizedDescription)")
            }
        }
        loadEntries()
        workshop.refresh()
        if !failures.isEmpty {
            manager.optimizationAlertMessage = failures.joined(separator: "\n")
            manager.showOptimizationAlert = true
        } else if !deletion.pairs.isEmpty {
            let message = deletion.isSinglePair
                ? String(localized: "Deleted the pair “\(deletion.entries[0].name)” and both library copies.")
                : String(localized: "Deleted the selected items and their library copies.")
            deletionNotice = message
            AccessibilityNotification.Announcement(message).post()
        }
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
        NSWorkspace.shared.open(WallpaperPrefsService.wallpaperSettingsURL)
    }

    private func visibleID(for id: String) -> String {
        pairs.first { $0.value.saved?.contains(id) == true }?.key ?? id
    }

    private func loadEntries() {
        let directory = VideoDeploymentService.videosFolderURL
        var records = (try? AppearancePair.read(in: directory)) ?? []
        for pair in records where pair.deletionPending == true {
            do {
                try pair.finishDeletion(in: directory)
                records.removeAll { $0.owner == pair.owner }
            } catch {
                Log.video.error("Could not finish deleting pair \(pair.owner): \(error.localizedDescription)")
            }
        }
        let physical = VideoDeploymentService.listEntries()
        files = Dictionary(uniqueKeysWithValues: physical.compactMap { entry in
            FileIdentity(of: VideoDeploymentService.videoURL(for: entry)).map { (entry.id, $0) }
        })
        let byID = Dictionary(uniqueKeysWithValues: physical.map { ($0.id, $0) })
        var groups = [String: VideoPairSelection]()
        var hidden = Set<String>()
        for record in records {
            let first = byID[record.owner], second = byID[record.counterpart]
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
            entry.name = groups[source.id]?.saved?.name ?? source.name
            return entry
        }
        videoSelection = Set(videoSelection.map(visibleID))
        videoSelection = videoSelection.filter { id in entries.contains { $0.id == id } }
        if videoSelection.isEmpty, let initialSelectionID, entries.contains(where: { $0.id == visibleID(for: initialSelectionID) }) {
            videoSelection = [visibleID(for: initialSelectionID)]
        }
    }
}

private extension ToolbarContent {
    @ToolbarContentBuilder
    func highVisibilityPriority() -> some ToolbarContent {
        if #available(macOS 26.1, *) {
            visibilityPriority(.high)
        } else {
            self
        }
    }
}

private enum Layout {
    static let sidebarMin: CGFloat = 180
    static let sidebarIdeal: CGFloat = 220
    static let sidebarMax: CGFloat = 260
    static let inspectorMin: CGFloat = 260
    static let inspectorIdeal: CGFloat = 300
    static let inspectorMax: CGFloat = 340
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

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.secondary)
            Text("\(count) Selected")
                .font(.headline)
            Text(detail)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(14)
    }
}
