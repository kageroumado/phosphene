import SwiftUI

extension CatalogSort {
    var name: String {
        switch self {
        case .trending: String(localized: "Trending")
        case .mostSubscribed: String(localized: "Most Subscribed")
        case .newest: String(localized: "Newest")
        }
    }
}

/// The Steam Workshop's wallpapers as a grid that loads a page at a time.
struct CatalogBrowser: View {
    @Environment(LibraryStore.self) private var store
    @Environment(CatalogStore.self) private var catalog
    @Environment(WorkshopLibrary.self) private var workshop

    private enum Timing {
        /// How long typing rests before the search runs.
        static let searchPause: Duration = .milliseconds(400)
    }

    var body: some View {
        Group {
            if !catalog.items.isEmpty {
                LibraryGrid(tiles: tiles, selection: catalog.selection, tileAspect: 1) {
                    catalog.loadMore()
                }
                .safeAreaInset(edge: .bottom, spacing: 0) { footer }
            } else {
                switch catalog.phase {
                case .failed:
                    unreachable
                case .loaded:
                    ContentUnavailableView.search(text: store.search)
                case .idle, .loading:
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .task { catalog.loadIfNeeded() }
        .task(id: store.search) {
            try? await Task.sleep(for: Timing.searchPause)
            guard !Task.isCancelled else { return }
            catalog.search(for: store.search)
        }
    }

    private var tiles: [LibraryTileModel] {
        let downloaded = Set(workshop.items.map(\.id))
        return catalog.items.map { item in
            let status = catalog.status(of: item.id, downloaded: downloaded)
            let badge: LibraryTileModel.Badge? = switch status {
            case .available: nil
            case .getting: .getting
            case .downloaded: .downloaded
            }
            let help = switch status {
            case .available: ""
            case .getting: String(localized: "Steam is downloading it")
            case .downloaded: String(localized: "Downloaded")
            }
            return LibraryTileModel(
                id: item.id, title: item.title, image: item.preview, imageFit: .fit, video: nil,
                placeholderSymbol: item.kind.symbol, isDimmed: false, badge: badge, help: help,
            )
        }
    }

    /// Under the grid while a further page loads, or when it could not.
    @ViewBuilder
    private var footer: some View {
        switch catalog.phase {
        case .loading:
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        case .failed:
            HStack(spacing: 8) {
                Text("Couldn’t load more wallpapers.")
                    .foregroundStyle(.secondary)
                Button("Try Again") { catalog.loadMore() }
                    .buttonStyle(.link)
            }
            .font(.subheadline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        case .idle, .loaded:
            EmptyView()
        }
    }

    private var unreachable: some View {
        ContentUnavailableView {
            Label("Can’t Reach the Workshop", systemImage: "wifi.exclamationmark")
        } description: {
            Text("Check your internet connection, or open the Workshop in Steam.")
        } actions: {
            Button("Try Again") { catalog.loadMore() }
            Button("Open Steam Workshop") { workshop.openWorkshop() }
        }
    }
}
