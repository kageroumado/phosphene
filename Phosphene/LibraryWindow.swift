import AppKit
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// The library window: a sidebar of places, the selected place as a grid or a sortable
/// list, and an inspector for what is selected.
struct LibraryWindow: View {
    let manager: PhospheneManager
    var initialSelectionID: String?

    var body: some View {
        LibraryRoot(initialSelectionID: initialSelectionID)
            .environment(manager)
            .environment(manager.library)
            .environment(manager.workshop)
    }
}

/// Column widths, and the window minimum that holds the columns at their widest.
///
/// Never let the window be narrower than the columns can be: SwiftUI leaves the split
/// view's own minimum out of the window's `contentMinSize`, and a window below it sends
/// AppKit into an endless Update Constraints loop that ends in an exception (#35).
/// ``contentMin`` is what the browser is left with when the sidebar is at its widest; it
/// is never applied as a `.frame(minWidth:)` on the detail, which starts the same loop at
/// any window size.
///
/// The minimum counts the sidebar and the inspector only while each is shown. AppKit
/// takes the minimum for the width the browser must keep, so a column that opens in a
/// window narrower than the minimum plus the column pushes the whole split view aside
/// while it animates.
enum LibraryLayout {
    static let sidebarMin: CGFloat = 180
    static let sidebarIdeal: CGFloat = 210
    static let sidebarMax: CGFloat = 260
    /// The inspector keeps one width, so selecting a row never resizes the column.
    static let inspectorWidth: CGFloat = 280
    static let contentMin: CGFloat = 420
    static let dividers: CGFloat = 2
    static let windowMinHeight: CGFloat = 520
    /// Longer than a column takes to slide in.
    static let columnSettle: Duration = .milliseconds(500)
    /// The library window's scene and `NSWindow` identifier.
    static let windowID = "library"

    static func windowMinWidth(sidebar: Bool, inspector: Bool) -> CGFloat {
        contentMin + dividers + (sidebar ? sidebarMax : 0) + (inspector ? inspectorWidth : 0)
    }
}

// MARK: - Root

private struct LibraryRoot: View {
    let initialSelectionID: String?

    @Environment(PhospheneManager.self) private var manager
    @Environment(LibraryStore.self) private var store
    @Environment(WorkshopLibrary.self) private var workshop

    /// Whether the window's minimum width counts each column. One turns true once its
    /// column has finished opening: a minimum raised as the column starts to open is the
    /// one AppKit holds the browser to.
    @State private var minimumHoldsSidebar = true
    @State private var minimumHoldsInspector = true

    var body: some View {
        @Bindable var store = store
        @Bindable var manager = manager
        NavigationSplitView(columnVisibility: Binding {
            store.columnVisibility
        } set: { visibility in
            store.setColumnVisibility(visibility)
        }) {
            LibrarySidebar()
                .navigationSplitViewColumnWidth(
                    min: LibraryLayout.sidebarMin, ideal: LibraryLayout.sidebarIdeal, max: LibraryLayout.sidebarMax,
                )
        } detail: {
            LibraryDetail()
        }
        .frame(
            minWidth: LibraryLayout.windowMinWidth(sidebar: minimumHoldsSidebar, inspector: minimumHoldsInspector),
            minHeight: LibraryLayout.windowMinHeight,
        )
        .task(id: store.showsSidebar) {
            if store.showsSidebar {
                try? await Task.sleep(for: LibraryLayout.columnSettle)
                guard !Task.isCancelled else { return }
            }
            minimumHoldsSidebar = store.showsSidebar
        }
        .task(id: store.showInspector) {
            if store.showInspector {
                try? await Task.sleep(for: LibraryLayout.columnSettle)
                guard !Task.isCancelled else { return }
            }
            minimumHoldsInspector = store.showInspector
        }
        .sheet(isPresented: $store.isMakeVideosPresented) {
            MakeVideosSheet()
        }
        .quickLookPreview($store.quickLookURL)
        .alert(store.deleteTitle, isPresented: $store.isConfirmingDelete) {
            Button("Delete", role: .destructive) { store.confirmDelete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(verbatim: store.deleteMessage)
        }
        .alert(manager.optimizationAlertTitle, isPresented: $manager.showOptimizationAlert) {} message: {
            Text(manager.optimizationAlertMessage)
        }
        .dropDestination(for: URL.self) { urls, _ in
            importDropped(urls)
        }
        .focusedSceneValue(store)
        // `phosphene://library/wallpaper-engine`: Sevoflurane opens the window at
        // the Wallpaper Engine section.
        .onOpenURL { url in
            if url.host == "library", url.path == "/wallpaper-engine" {
                store.section = .workshopAll
            }
        }
        .onAppear {
            store.reload()
            if let initialSelectionID, store.videoSelection.isEmpty {
                store.reveal(videoID: initialSelectionID)
            }
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
            store.reload()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            workshop.refresh()
        }
    }

    private func importDropped(_ urls: [URL]) {
        let videoTypes: [UTType] = [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        let videos = urls.filter { url in
            guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
            return videoTypes.contains { type.conforms(to: $0) }
        }
        guard !videos.isEmpty else { return }
        store.importVideos(videos)
    }
}

// MARK: - Detail

/// The browser with its toolbar and status bar, and the inspector beside it. The
/// inspector belongs to the detail column, so showing it moves the browser alone.
private struct LibraryDetail: View {
    @Environment(LibraryStore.self) private var store
    @Environment(WorkshopLibrary.self) private var workshop

    var body: some View {
        @Bindable var store = store
        LibraryContent()
            .navigationTitle(title)
            .safeAreaInset(edge: .bottom, spacing: 0) { LibraryStatusBar() }
            .inspector(isPresented: $store.showInspector) {
                LibraryInspector()
                    .inspectorColumnWidth(LibraryLayout.inspectorWidth)
            }
            .searchable(
                text: $store.search,
                placement: .toolbar,
                prompt: store.section.isWorkshop ? Text("Search Wallpapers") : Text("Search Videos"),
            )
            .toolbar { LibraryToolbar() }
    }

    private var title: String {
        switch store.section {
        case .allVideos:
            String(localized: "All Videos")
        case .inUse:
            String(localized: "In Use")
        case .workshopAll:
            String(localized: "Wallpaper Engine")
        case .workshopReady:
            String(localized: "Ready to Make")
        case let .workshopSource(id):
            workshop.sources.first { $0.id == id }?.label ?? String(localized: "Wallpaper Engine")
        }
    }
}

/// The current section's rows, or what to do when it has none.
private struct LibraryContent: View {
    @Environment(LibraryStore.self) private var store
    @Environment(WorkshopLibrary.self) private var workshop

    var body: some View {
        if store.section.isWorkshop {
            let rows = store.workshopRows
            Group {
                if !rows.isEmpty {
                    WorkshopBrowser(rows: rows)
                } else if !store.search.isEmpty {
                    ContentUnavailableView.search(text: store.search)
                } else {
                    WorkshopEmptyState()
                }
            }
            .navigationSubtitle(Text("\(rows.count) wallpapers"))
        } else {
            let rows = store.videoRows
            Group {
                if !rows.isEmpty {
                    VideoBrowser(rows: rows)
                } else if !store.search.isEmpty {
                    ContentUnavailableView.search(text: store.search)
                } else {
                    VideoEmptyState()
                }
            }
            .navigationSubtitle(videoSubtitle(rows))
        }
    }

    private func videoSubtitle(_ rows: [VideoRow]) -> String {
        guard !rows.isEmpty else { return String(localized: "\(rows.count) videos") }
        let bytes = rows.map(\.fileSize).reduce(0, +)
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        return String(localized: "\(rows.count) videos · \(size)")
    }
}

// MARK: - Toolbar

private struct LibraryToolbar: ToolbarContent {
    @Environment(LibraryStore.self) private var store

    var body: some ToolbarContent {
        @Bindable var store = store
        ToolbarItem {
            Picker("View", selection: $store.viewMode) {
                Label("Icons", systemImage: "square.grid.2x2")
                    .accessibilityLabel("Icons")
                    .tag(LibraryViewMode.icons)
                Label("List", systemImage: "list.bullet")
                    .accessibilityLabel("List")
                    .tag(LibraryViewMode.list)
            }
            .pickerStyle(.segmented)
            .help("Show as icons or as a list")
        }
        ToolbarSpacer(.fixed)
        if store.section.isWorkshop {
            ToolbarItem {
                // Prominent only while it can act: a filled button reads as the action to take.
                if store.renderableSelection.isEmpty {
                    makeVideosButton
                        .buttonStyle(.glass)
                        .disabled(true)
                } else {
                    makeVideosButton
                        .buttonStyle(.glassProminent)
                }
            }
        } else {
            ToolbarItem {
                Button("Add Video", systemImage: "plus") {
                    store.addVideo()
                }
                .help("Add a video to the library")
            }
        }
        ToolbarSpacer(.fixed)
        ToolbarItem {
            Button("Inspector", systemImage: "sidebar.trailing") {
                store.toggleInspector()
            }
            .help(store.showInspector ? "Hide Inspector" : "Show Inspector")
        }
    }

    private var makeVideosButton: some View {
        Button("Make Videos…") {
            store.requestMakeVideos()
        }
        .help("Turn the selected wallpapers into looping videos")
    }
}

// MARK: - Status bar

/// The strip under the browser: where wallpapers are chosen, or the video being made,
/// and the icon size.
private struct LibraryStatusBar: View {
    @Environment(LibraryStore.self) private var store
    @Environment(WorkshopLibrary.self) private var workshop

    var body: some View {
        @Bindable var store = store
        HStack(spacing: 10) {
            if let current = workshop.current.flatMap(workshop.item) {
                ProgressView(value: workshop.progress)
                    .progressViewStyle(.circular)
                    .controlSize(.mini)
                Text(verbatim: makingSummary(current))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Stop") { workshop.cancelAll() }
                    .buttonStyle(.link)
            } else {
                Button {
                    store.openWallpaperSettings()
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
            if store.viewMode == .icons {
                // The slider goes when the column is too narrow for it, so the status bar
                // never sets the detail column's minimum width.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        Image(systemName: "photo")
                            .imageScale(.small)
                        Slider(value: $store.iconSize, in: LibraryIconSize.range)
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
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private func makingSummary(_ item: WorkshopItem) -> String {
        let percent = workshop.progress.formatted(.percent.precision(.fractionLength(0)))
        let waiting = workshop.queue.count
        let base = String(localized: "Making “\(item.title)” · \(percent)")
        return waiting > 0 ? String(localized: "\(base) · \(waiting) waiting") : base
    }
}

// MARK: - Empty states

private struct VideoEmptyState: View {
    @Environment(LibraryStore.self) private var store

    var body: some View {
        switch store.section {
        case .inUse:
            ContentUnavailableView {
                Label("No Wallpaper in Use", systemImage: "play.rectangle")
            } description: {
                Text("Choose a Phosphene video in System Settings › Wallpaper.")
            } actions: {
                Button("Open Wallpaper Settings") { store.openWallpaperSettings() }
            }
        default:
            ContentUnavailableView {
                Label("No Videos", systemImage: "film.stack")
            } description: {
                Text("Add a video to use as your wallpaper, or drop one here.")
            } actions: {
                Button("Add Video…") { store.addVideo() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

private struct WorkshopEmptyState: View {
    @Environment(LibraryStore.self) private var store
    @Environment(WorkshopLibrary.self) private var workshop

    var body: some View {
        if store.section == .workshopReady, !workshop.items.isEmpty {
            ContentUnavailableView {
                Label("Nothing to Make", systemImage: "checkmark.circle")
            } description: {
                Text("Subscribe to more wallpapers on the Steam Workshop and they appear here.")
            } actions: {
                Button("Open Steam Workshop") { workshop.openWorkshop() }
            }
        } else if !workshop.sources.isEmpty {
            ContentUnavailableView {
                Label("No Wallpapers Yet", systemImage: "square.and.arrow.down")
            } description: {
                Text("Wallpaper Engine is installed. Subscribe to wallpapers on the Steam Workshop and they appear here.")
            } actions: {
                Button("Open Steam Workshop") { workshop.openWorkshop() }
                    .buttonStyle(.borderedProminent)
            }
        } else {
            getStarted
        }
    }

    private var getStarted: some View {
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
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 48)
                .padding(.bottom, 20)
        }
    }
}

// MARK: - Menu commands

/// Every library action in the menu bar, with keyboard shortcuts.
struct LibraryCommands: Commands {
    @FocusedValue(LibraryStore.self) private var store

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Add Video…") { store?.addVideo() }
                .keyboardShortcut("o")
                .disabled(store == nil)
            Button("Add Wallpaper Engine Folder…") { store?.addFolder() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(store == nil)
            Divider()
            Button("Make Videos…") { store?.requestMakeVideos() }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .disabled(store?.renderableSelection.isEmpty ?? true)
            Divider()
            Button("Quick Look") { store?.toggleQuickLook() }
                .keyboardShortcut("y")
                .disabled(!(store?.hasSelection ?? false))
            Button("Show in Finder") { store?.showSelectionInFinder() }
                .keyboardShortcut("r")
                .disabled(!(store?.hasSelection ?? false))
            Button("Delete…") { store?.requestDelete() }
                .keyboardShortcut(.delete)
                .disabled(store?.videoSelection.isEmpty ?? true)
        }
        CommandGroup(before: .sidebar) {
            if let store {
                Picker("View", selection: Bindable(store).viewMode) {
                    Text("as Icons").tag(LibraryViewMode.icons)
                        .keyboardShortcut("1")
                    Text("as List").tag(LibraryViewMode.list)
                        .keyboardShortcut("2")
                }
                .pickerStyle(.inline)
            }
            Button("Make Icons Larger") { store?.stepIconSize(by: 1) }
                .keyboardShortcut("+")
                .disabled(store?.viewMode != .icons)
            Button("Make Icons Smaller") { store?.stepIconSize(by: -1) }
                .keyboardShortcut("-")
                .disabled(store?.viewMode != .icons)
            Divider()
        }
        SidebarCommands()
        CommandGroup(after: .sidebar) {
            Button(store?.showInspector == true ? "Hide Inspector" : "Show Inspector") {
                store?.toggleInspector()
            }
            .keyboardShortcut("i", modifiers: [.command, .control])
            .disabled(store == nil)
        }
    }
}
