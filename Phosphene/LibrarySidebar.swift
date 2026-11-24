import SwiftUI

/// The library window's sidebar: the videos Phosphene plays, then the Wallpaper Engine
/// wallpapers it can make videos from and the Steam Workshop to get more. The places
/// wallpapers come from get rows of their own when there are several, or when one is an
/// added folder.
struct LibrarySidebar: View {
    @Environment(LibraryStore.self) private var store
    @Environment(WorkshopLibrary.self) private var workshop

    var body: some View {
        @Bindable var store = store
        let counts = store.counts
        List(selection: $store.sidebarSelection) {
            Section("Library") {
                row(Text("All Videos"), symbol: "film.stack", count: counts.all, tag: .allVideos)
                row(Text("In Use"), symbol: "play.rectangle", count: counts.inUse, tag: .inUse)
            }

            Section("Wallpaper Engine") {
                row(Text("All Wallpapers"), symbol: "rectangle.stack", count: counts.wallpapers, tag: .workshopAll)
                row(Text("Ready to Make"), symbol: "wand.and.sparkles", count: counts.readyToMake, tag: .workshopReady)
                row(Text("Workshop"), symbol: "globe", count: 0, tag: .catalog)
                ForEach(store.showsSources ? workshop.sources : []) { source in
                    row(
                        Text(verbatim: source.label), symbol: symbol(for: source),
                        count: workshop.items.count { $0.sourceID == source.id }, tag: .workshopSource(source.id),
                    )
                    .help(source.contentFolder.path)
                    .contextMenu {
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([source.contentFolder])
                        }
                        if source.kind == .folder {
                            Divider()
                            Button("Remove Folder") { workshop.removeFolder(source) }
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .task(id: store.showsSources) {
            // A place's row can be the stored selection after its row has gone.
            if !store.showsSources, case .workshopSource = store.section {
                store.section = .workshopAll
            }
        }
        .safeAreaInset(edge: .bottom) { bottomBar }
    }

    /// A sidebar row. A count of zero shows no badge.
    private func row(_ title: Text, symbol: String, count: Int, tag: LibrarySection) -> some View {
        Label { title } icon: { Image(systemName: symbol) }
            .badge(count)
            .tag(tag)
    }

    private func symbol(for source: WorkshopSource) -> String {
        switch source.kind {
        case .sevoflurane, .crossover, .whisky: "shippingbox"
        case .steam: "gamecontroller"
        case .folder: "folder"
        }
    }

    private var bottomBar: some View {
        HStack {
            Menu {
                Button("Add Video…") { store.addVideo() }
                Button("Add Wallpaper Engine Folder…") { store.addFolder() }
                Divider()
                Button("Open Steam Workshop") { workshop.openWorkshop() }
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Add")
            .help("Add a video or a folder of Wallpaper Engine wallpapers")
            Spacer()
            if workshop.isScanning {
                ProgressView()
                    .controlSize(.small)
                    .help("Looking for Wallpaper Engine downloads")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
