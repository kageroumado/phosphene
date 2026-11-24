import SwiftUI

/// The Steam Workshop listing the library window browses: the wallpapers loaded so far,
/// the one selected, and the ones asked of Steam.
@Observable
final class CatalogStore {
    enum Phase: Equatable {
        case idle
        case loading
        case loaded
        /// The last page asked for could not be read.
        case failed
    }

    /// Where a listed wallpaper stands on this Mac.
    enum Status: Equatable {
        case available
        /// Asked of Steam, with the download yet to arrive.
        case getting
        case downloaded
    }

    private enum Limits {
        /// How long a wallpaper asked of Steam shows as on its way. Steam says nothing
        /// when it declines or fails, so a request older than this counts as lost.
        static let requestLifetime: TimeInterval = 15 * 60
    }

    @ObservationIgnored private unowned let workshop: WorkshopLibrary

    private(set) var items: [CatalogItem] = []
    private(set) var phase = Phase.idle
    /// How many wallpapers the whole listing holds.
    private(set) var total = 0
    var selection: Set<String> = []
    /// When each wallpaper was asked of Steam.
    private(set) var requested: [String: Date] = [:]

    var sort = CatalogSort.trending {
        didSet {
            if sort != oldValue {
                reload()
            }
        }
    }

    @ObservationIgnored private var search = ""
    @ObservationIgnored private var page = 0
    @ObservationIgnored private var pageCount = 1
    /// Counts reloads, so a page that arrives after one is dropped.
    @ObservationIgnored private var generation = 0

    init(workshop: WorkshopLibrary) {
        self.workshop = workshop
    }

    var selectedItem: CatalogItem? {
        items.first { selection.contains($0.id) }
    }

    /// Whether the listing is showing the result of a search.
    var isSearching: Bool {
        !search.isEmpty
    }

    // MARK: - Loading

    /// Load the first page, the first time the listing is shown.
    func loadIfNeeded() {
        if phase == .idle {
            loadMore()
        }
    }

    /// Search the Workshop for `text`; empty text shows the sorted listing.
    func search(for text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text != search else { return }
        search = text
        reload()
    }

    /// Load the next page, when there is one. The grid asks as its last tile appears.
    func loadMore() {
        guard phase != .loading, page < pageCount else { return }
        phase = .loading
        let generation = generation
        let query = CatalogQuery(search: search, sort: sort, page: page + 1)
        Task(name: "Load Workshop page \(query.page)") {
            let result = try? await WorkshopCatalog.page(for: query)
            guard generation == self.generation else { return }
            guard let result else {
                phase = .failed
                return
            }
            let known = Set(items.map(\.id))
            items += result.items.filter { !known.contains($0.id) }
            page = result.page
            pageCount = result.pageCount
            total = result.total
            phase = .loaded
        }
    }

    private func reload() {
        generation += 1
        items = []
        selection = []
        page = 0
        pageCount = 1
        total = 0
        phase = .idle
        loadMore()
    }

    // MARK: - Getting

    /// Where `id` stands, given the ids of the wallpapers on this Mac.
    func status(of id: String, downloaded: Set<String>) -> Status {
        if downloaded.contains(id) {
            return .downloaded
        }
        guard let asked = requested[id], asked.timeIntervalSinceNow > -Limits.requestLifetime else {
            return .available
        }
        return .getting
    }

    /// Ask Steam for a wallpaper. Steam downloads it, and the library finds the download.
    func get(_ id: String) {
        guard workshop.subscribe(to: id) else { return }
        requested[id] = .now
    }
}
