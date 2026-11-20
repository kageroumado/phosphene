import SwiftUI

/// The library window's sidebar: the videos Phosphene plays, then the Wallpaper
/// Engine downloads it can make videos from, one row per place they come from.
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
                row(Text("From Workshop"), symbol: "wand.and.sparkles", count: counts.fromWorkshop, tag: .fromWorkshop)
            }

            Section("Wallpaper Engine") {
                row(Text("Downloads"), symbol: "square.and.arrow.down", count: counts.downloads, tag: .workshopDownloads)
                row(Text("Not Made Yet"), symbol: "circle.dashed", count: counts.notMade, tag: .workshopNotMade)
                ForEach(workshop.sources) { source in
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
        .safeAreaInset(edge: .bottom) { bottomBar }
    }

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
