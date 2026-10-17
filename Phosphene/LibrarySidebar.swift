import SwiftUI

/// The library window's sidebar: the videos Phosphene plays, then the Wallpaper
/// Engine downloads it can make videos from, one row per place they come from.
struct LibrarySidebar: View {
    @Binding var section: LibrarySection
    let counts: Counts
    @Bindable var workshop: WorkshopLibrary
    let onAddVideo: () -> Void

    struct Counts {
        var all = 0
        var inUse = 0
        var fromWorkshop = 0
    }

    var body: some View {
        List(selection: Binding(get: { section }, set: {
            if let new = $0 {
                section = new
            }
        })) {
            Section("Library") {
                row(Text("All Videos"), symbol: "film.stack", count: counts.all, tag: .allVideos)
                row(Text("In Use"), symbol: "play.rectangle", count: counts.inUse, tag: .inUse)
                row(Text("From Workshop"), symbol: "wand.and.sparkles", count: counts.fromWorkshop, tag: .fromWorkshop)
            }

            Section("Wallpaper Engine") {
                row(Text("Downloads"), symbol: "square.and.arrow.down", count: workshop.items.count, tag: .workshopDownloads)
                row(Text("Not Made Yet"), symbol: "circle.dashed", count: notMadeCount, tag: .workshopNotMade)
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

    private var notMadeCount: Int {
        workshop.items.count { item in
            switch workshop.status(of: item) {
            case .available, .outdated, .failed: true
            default: false
            }
        }
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
                Button("Add Video…", action: onAddVideo)
                Button("Add Wallpaper Engine Folder…") { workshop.chooseFolder() }
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
