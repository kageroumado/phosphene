import Foundation

/// One wallpaper listed on the Steam Workshop.
nonisolated struct CatalogItem: Identifiable, Hashable, Sendable {
    /// Steam's `publishedfileid`.
    let id: String
    let title: String
    /// The author's preview image or animation.
    let preview: URL?
    /// The wallpaper type named by its Scene, Video, Web or Application tag.
    let kind: WorkshopKind
    /// The download size in bytes.
    let fileSize: Int64
    /// The number of current subscribers.
    let subscriptions: Int
    let updated: Date
    /// Steam's canonical `tag` values, in the listing's order.
    let tags: [String]

    /// The item's page on the Steam Community site.
    var pageURL: URL {
        WorkshopCatalog.detailsPage.appending(queryItems: [URLQueryItem(name: "id", value: id)])
    }
}

/// The orders the Workshop listing can be browsed in.
nonisolated enum CatalogSort: String, CaseIterable, Sendable {
    /// Most popular over the last week.
    case trending
    /// Most subscribers of all time.
    case mostSubscribed
    /// Most recently published.
    case newest
}

/// One request for a page of the Workshop listing.
nonisolated struct CatalogQuery: Hashable, Sendable {
    /// Text to search titles and descriptions for; blank browses by `sort`.
    var search = ""
    /// The listing order, used when `search` is blank.
    var sort = CatalogSort.trending
    /// The 1-based page number.
    var page = 1
}

/// One page of the Workshop listing.
nonisolated struct CatalogPage: Sendable {
    let items: [CatalogItem]
    /// The 1-based number of this page.
    let page: Int
    /// The number of pages Steam serves for the query, which it caps at 1,000.
    let pageCount: Int
    /// The number of items matching the query.
    let total: Int
}

/// Reads the public Steam Workshop listing for Wallpaper Engine, logged out and without
/// an API key, from the JSON that Steam embeds in the listing's HTML.
nonisolated enum WorkshopCatalog {
    /// Why a page could not be read.
    enum Failure: Error, Equatable {
        /// Steam answered with this HTTP status instead of 200.
        case http(Int)
        /// The response holds no listing data in the expected shape.
        case unreadable
    }

    private enum Constants {
        static let browsePage = "https://steamcommunity.com/workshop/browse/"
        static let wallpaperEngineAppID = "431960"
        /// The tab of finished wallpapers, as opposed to collections, merchandise or guides.
        static let section = "readytouseitems"
        /// Keeps the listing to wallpapers their authors rated Everyone; without it the
        /// listing mixes in Questionable and Mature items.
        static let requiredRating = "Everyone"
        /// Leaves out Web wallpapers, which Phosphene cannot turn into video.
        static let excludedWeb = "Web"
        /// Leaves out Application wallpapers, which Phosphene cannot turn into video.
        static let excludedApplication = "Application"
        static let requestTimeout: TimeInterval = 20
        static let languageLimit = 6
        /// The characters left as they are in a query value; everything else is
        /// percent-encoded, including `+`, which Steam reads as a space.
        static let queryValueAllowed = CharacterSet(charactersIn: "-._~")
            .union(CharacterSet(charactersIn: "a" ... "z"))
            .union(CharacterSet(charactersIn: "A" ... "Z"))
            .union(CharacterSet(charactersIn: "0" ... "9"))
    }

    /// The key of the cached query that holds the listing.
    fileprivate static let browseQueryKey = "workshop_browse"

    static let detailsPage = URL(string: "https://steamcommunity.com/sharedfiles/filedetails/")!

    /// A session that keeps cookies and cache in memory only and sends no cookies.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = Constants.requestTimeout
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        return URLSession(configuration: configuration)
    }()

    /// The listing URL for a query: a text search when `search` has text, otherwise
    /// the listing in `query.sort` order.
    static func url(for query: CatalogQuery) -> URL {
        let search = query.search.trimmingCharacters(in: .whitespacesAndNewlines)
        var items: [(String, String)] = [
            ("appid", Constants.wallpaperEngineAppID),
            ("section", Constants.section),
        ]
        if search.isEmpty {
            items.append(("browsesort", query.sort.browseSort))
        } else {
            items.append(("browsesort", "textsearch"))
            items.append(("searchtext", search))
        }
        items += [
            ("requiredtags[]", Constants.requiredRating),
            ("excludedtags[]", Constants.excludedWeb),
            ("excludedtags[]", Constants.excludedApplication),
            ("p", String(max(query.page, 1))),
        ]
        var components = URLComponents(string: Constants.browsePage)!
        components.percentEncodedQueryItems = items.map { name, value in
            URLQueryItem(name: encode(name), value: encode(value))
        }
        return components.url!
    }

    /// Reads one listing page out of the HTML Steam serves for it.
    static func parse(_ html: Data) throws(Failure) -> CatalogPage {
        guard let json = embeddedJSON(in: html) else { throw .unreadable }
        let browse: BrowseData
        do {
            let decoder = JSONDecoder()
            let envelope = try decoder.decode(Envelope.self, from: json)
            let queries = try decoder.decode(QueryData.self, from: Data(envelope.renderContext.queryData.utf8))
            guard let found = queries.queries.lazy.compactMap(\.browse).first else { throw Failure.unreadable }
            browse = found
        } catch {
            throw .unreadable
        }
        let items = browse.results.compactMap(\.item)
        let page = max(browse.currentPage ?? 1, 1)
        return CatalogPage(
            items: items,
            page: page,
            pageCount: browse.totalPages ?? page,
            total: browse.totalCount ?? items.count,
        )
    }

    /// Fetches and reads one listing page.
    ///
    /// - Throws: `Failure.http` for a status other than 200, `Failure.unreadable` for a
    ///   page without listing data, and URLSession's own errors as they are.
    @concurrent
    static func page(
        for query: CatalogQuery,
        load: (@Sendable (URLRequest) async throws -> (Data, URLResponse))? = nil,
    ) async throws -> CatalogPage {
        var request = URLRequest(url: url(for: query), timeoutInterval: Constants.requestTimeout)
        request.setValue(acceptLanguage(for: Locale.preferredLanguages), forHTTPHeaderField: "Accept-Language")
        let (data, response) = if let load {
            try await load(request)
        } else {
            try await session.data(for: request)
        }
        guard let http = response as? HTTPURLResponse else { throw Failure.unreadable }
        guard http.statusCode == 200 else { throw Failure.http(http.statusCode) }
        return try parse(data)
    }

    /// An `Accept-Language` value listing `languages` in order with falling weights.
    static func acceptLanguage(for languages: [String]) -> String {
        let chosen = languages.prefix(Constants.languageLimit)
        guard !chosen.isEmpty else { return "en" }
        return chosen.enumerated().map { index, language in
            index == 0 ? language : "\(language);q=0.\(10 - index)"
        }.joined(separator: ", ")
    }

    private static func encode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: Constants.queryValueAllowed) ?? text
    }

    // MARK: - Finding the embedded JSON

    /// The contents of the `<script id="valve-ssr-data">` element, whatever the order of
    /// its attributes.
    private static func embeddedJSON(in html: Data) -> Data? {
        let text = String(decoding: html, as: UTF8.self)
        var searchStart = text.startIndex
        while let open = text.range(of: "<script", options: .caseInsensitive, range: searchStart ..< text.endIndex) {
            guard let tagEnd = text.range(of: ">", range: open.upperBound ..< text.endIndex) else { return nil }
            let attributes = text[open.upperBound ..< tagEnd.lowerBound]
            searchStart = tagEnd.upperBound
            guard hasScriptID(attributes) else { continue }
            guard let close = text.range(of: "</script", options: .caseInsensitive, range: tagEnd.upperBound ..< text.endIndex)
            else { return nil }
            return Data(text[tagEnd.upperBound ..< close.lowerBound].utf8)
        }
        return nil
    }

    private static func hasScriptID(_ attributes: Substring) -> Bool {
        attributes.contains(/(?:^|\s)id\s*=\s*(?:"valve-ssr-data"|'valve-ssr-data'|valve-ssr-data(?=[\s\/]|$))/
            .ignoresCase())
    }
}

private nonisolated extension CatalogSort {
    /// The value of the listing's `browsesort` parameter.
    var browseSort: String {
        switch self {
        case .trending: "trend"
        case .mostSubscribed: "totaluniquesubscribers"
        case .newest: "mostrecent"
        }
    }
}

// MARK: - Steam's JSON

/// The page's server-rendered state; `queryData` is itself a JSON document in a string.
private nonisolated struct Envelope: Decodable {
    struct RenderContext: Decodable {
        let queryData: String
    }

    let renderContext: RenderContext
}

private nonisolated struct QueryData: Decodable {
    let queries: [CachedQuery]
}

/// One cached query of the page. Only the `workshop_browse` query's data is decoded; the
/// others hold unrelated shapes.
private nonisolated struct CachedQuery: Decodable {
    let browse: BrowseData?

    private enum CodingKeys: String, CodingKey {
        case queryKey
        case state
    }

    private struct State: Decodable {
        let data: BrowseData
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var key = try container.nestedUnkeyedContainer(forKey: .queryKey)
        guard (try? key.decode(String.self)) == WorkshopCatalog.browseQueryKey else {
            browse = nil
            return
        }
        browse = try container.decode(State.self, forKey: .state).data
    }
}

private nonisolated struct BrowseData: Decodable {
    let currentPage: Int?
    let totalPages: Int?
    let totalCount: Int?
    let results: [Result]

    private enum CodingKeys: String, CodingKey {
        case currentPage = "current_page"
        case totalPages = "total_pages"
        case totalCount = "total_count"
        case results
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        currentPage = container.lenient(.currentPage).map { Int(clamping: $0) }
        totalPages = container.lenient(.totalPages).map { Int(clamping: $0) }
        totalCount = container.lenient(.totalCount).map { Int(clamping: $0) }
        results = try container.decode([Result].self, forKey: .results)
    }

    /// One listed item; `item` is nil when the entry lacks a usable id.
    struct Result: Decodable {
        let item: CatalogItem?

        private enum CodingKeys: String, CodingKey {
            case publishedfileid
            case title
            case previewURL = "preview_url"
            case fileSize = "file_size"
            case subscriptions
            case timeUpdated = "time_updated"
            case tags
        }

        private struct Tag: Decodable {
            let tag: String
        }

        init(from decoder: any Decoder) throws {
            guard let container = try? decoder.container(keyedBy: CodingKeys.self),
                  let id = container.lenient(.publishedfileid).map({ String($0) }), id != "0"
            else {
                item = nil
                return
            }
            let tags = ((try? container.decodeIfPresent([Tag?].self, forKey: .tags)) ?? nil)?
                .compactMap { $0?.tag } ?? []
            let preview = (try? container.decodeIfPresent(String.self, forKey: .previewURL))?
                .flatMap { $0.isEmpty ? nil : URL(string: $0) }
            item = CatalogItem(
                id: id,
                title: (try? container.decodeIfPresent(String.self, forKey: .title)) ?? "",
                preview: preview,
                kind: WorkshopKind(catalogTags: tags),
                fileSize: max(container.lenient(.fileSize) ?? 0, 0),
                subscriptions: Int(clamping: max(container.lenient(.subscriptions) ?? 0, 0)),
                updated: Date(timeIntervalSince1970: TimeInterval(container.lenient(.timeUpdated) ?? 0)),
                tags: tags,
            )
        }
    }
}

private nonisolated extension WorkshopKind {
    /// The kind named by the first of the Scene, Video, Web and Application tags.
    init(catalogTags tags: [String]) {
        self = tags.lazy.compactMap { tag -> WorkshopKind? in
            switch tag {
            case "Scene": .scene
            case "Video": .video
            case "Web": .web
            case "Application": .application
            default: nil
            }
        }.first ?? .unknown
    }
}

private nonisolated extension KeyedDecodingContainer {
    /// A whole number stored as a JSON number or as a string holding one, since Steam
    /// writes some 64-bit fields as strings and the choice varies between fields.
    func lenient(_ key: Key) -> Int64? {
        if let number = try? decodeIfPresent(Int64.self, forKey: key) {
            return number
        }
        if let text = try? decodeIfPresent(String.self, forKey: key) {
            return Int64(text.trimmingCharacters(in: .whitespaces))
        }
        if let number = try? decodeIfPresent(Double.self, forKey: key), number.isFinite {
            return Int64(clamping: number)
        }
        return nil
    }
}

private nonisolated extension Int64 {
    init(clamping value: Double) {
        if value >= Double(Int64.max) {
            self = .max
        } else if value <= Double(Int64.min) {
            self = .min
        } else {
            self = Int64(value)
        }
    }
}
