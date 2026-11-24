import Foundation
import Testing

/// The Steam Workshop listing: the browse URL for each kind of query, and reading a page
/// out of the JSON Steam embeds in the listing's HTML.
struct WorkshopCatalogTests {
    // MARK: - URL

    private func items(_ url: URL) -> [String: [String]] {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        return (components?.queryItems ?? []).reduce(into: [:]) { result, item in
            result[item.name, default: []].append(item.value ?? "")
        }
    }

    @Test
    func `trending page 1 is the filtered listing`() {
        let url = WorkshopCatalog.url(for: CatalogQuery())
        #expect(url.absoluteString == "https://steamcommunity.com/workshop/browse/?appid=431960&section=readytouseitems"
            + "&browsesort=trend&requiredtags%5B%5D=Everyone&excludedtags%5B%5D=Web&excludedtags%5B%5D=Application&p=1")
    }

    @Test(arguments: [
        (CatalogSort.trending, "trend"),
        (.mostSubscribed, "totaluniquesubscribers"),
        (.newest, "mostrecent"),
    ])
    func `each sort maps to its browsesort`(sort: CatalogSort, expected: String) {
        let query = items(WorkshopCatalog.url(for: CatalogQuery(sort: sort)))
        #expect(query["browsesort"] == [expected])
        #expect(query["searchtext"] == nil)
        #expect(query["requiredtags[]"] == ["Everyone"])
        #expect(query["excludedtags[]"] == ["Web", "Application"])
    }

    @Test
    func `a search ignores the sort and encodes its text`() {
        let url = WorkshopCatalog.url(for: CatalogQuery(search: " C++ & rain ", sort: .newest))
        let query = items(url)
        #expect(query["browsesort"] == ["textsearch"])
        #expect(query["searchtext"] == ["C++ & rain"])
        #expect(url.absoluteString.contains("&searchtext=C%2B%2B%20%26%20rain&"))
    }

    @Test
    func `a CJK search is percent-encoded UTF-8`() {
        let url = WorkshopCatalog.url(for: CatalogQuery(search: "雨の夜"))
        #expect(items(url)["searchtext"] == ["雨の夜"])
        #expect(url.absoluteString.contains("searchtext=%E9%9B%A8%E3%81%AE%E5%A4%9C"))
    }

    @Test
    func `a blank search browses by sort`() {
        #expect(items(WorkshopCatalog.url(for: CatalogQuery(search: "  ", sort: .newest)))["browsesort"] == ["mostrecent"])
    }

    @Test(arguments: [(7, "7"), (0, "1"), (-3, "1")])
    func `the page number is at least 1`(page: Int, expected: String) {
        #expect(items(WorkshopCatalog.url(for: CatalogQuery(page: page)))["p"] == [expected])
    }

    @Test
    func `accept language follows the preferred languages`() {
        #expect(WorkshopCatalog.acceptLanguage(for: ["fr-FR", "ja-JP", "en"]) == "fr-FR, ja-JP;q=0.9, en;q=0.8")
        #expect(WorkshopCatalog.acceptLanguage(for: []) == "en")
    }

    // MARK: - Parsing

    @Test
    func `a listing page reads into items`() throws {
        let page = try WorkshopCatalog.parse(Data(Self.listing.utf8))
        #expect(page.page == 2)
        #expect(page.pageCount == 1_000)
        #expect(page.total == 2_597_421)
        #expect(page.items.map(\.id) == ["3844704085", "3845223430", "3841859550"])

        let first = try #require(page.items.first)
        #expect(first.title == "鸣潮 绮丽幻梦·西格莉卡 by b站 炑月烟火")
        #expect(first.kind == .video)
        #expect(first.fileSize == 46_646_108)
        #expect(first.subscriptions == 933)
        #expect(first.updated == Date(timeIntervalSince1970: 1_795_434_621))
        #expect(first.tags == ["Video", "Game", "Wallpaper", "Other resolution", "Everyone"])
        #expect(first.preview?.absoluteString
            == "https://images.steamusercontent.com/ugc/11130907140747170949/DB87B68B9EBD8437CDA939761D8F4E80D43E142A/")
        #expect(first.pageURL.absoluteString == "https://steamcommunity.com/sharedfiles/filedetails/?id=3844704085")

        #expect(page.items[1].title == "ulquiorra & orihime ♥")
        #expect(page.items[1].kind == .scene)
        #expect(page.items[2].subscriptions == 1_094)
    }

    @Test
    func `the script is found whatever its attribute order`() throws {
        let html = Self.listing.replacingOccurrences(
            of: #"<script type="application/json" id="valve-ssr-data" nonce="d0dd45c5-3435-4b65-9687-e77782a47472">"#,
            with: #"<script nonce='x' ID='valve-ssr-data' data-extra="1" type="application/json">"#,
        )
        #expect(try WorkshopCatalog.parse(Data(html.utf8)).items.count == 3)
    }

    @Test
    func `numbers read from either strings or numbers`() throws {
        let result = """
        {"publishedfileid": 42, "title": "t", "file_size": 1234, "subscriptions": "56",
         "time_updated": "1700000000", "preview_url": "", "tags": [{"tag": "Application"}]}
        """
        let page = try WorkshopCatalog.parse(Self.page(results: "[\(result)]", numbers: #""3", "9", 250"#))
        let item = try #require(page.items.first)
        #expect(item.id == "42")
        #expect(item.fileSize == 1_234)
        #expect(item.subscriptions == 56)
        #expect(item.updated == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(item.preview == nil)
        #expect(item.kind == .application)
        #expect(page.page == 3)
        #expect(page.pageCount == 9)
        #expect(page.total == 250)
    }

    @Test
    func `an item without a type tag or id`() throws {
        let results = #"[{"publishedfileid": "7", "tags": [{"tag": "Anime"}]}, {"title": "no id"}]"#
        let page = try WorkshopCatalog.parse(Self.page(results: results))
        #expect(page.items.map(\.id) == ["7"])
        #expect(page.items.first?.kind == .unknown)
        #expect(page.items.first?.title == "")
    }

    @Test
    func `a page without the script is unreadable`() {
        #expect(throws: WorkshopCatalog.Failure.unreadable) {
            try WorkshopCatalog.parse(Data("<html><script id=\"other\">{}</script></html>".utf8))
        }
    }

    @Test
    func `broken JSON is unreadable`() {
        let html = #"<script type="application/json" id="valve-ssr-data">{"renderContext": {"queryData": "{"#
            + "</script>"
        #expect(throws: WorkshopCatalog.Failure.unreadable) {
            try WorkshopCatalog.parse(Data(html.utf8))
        }
    }

    @Test
    func `a page without the browse query is unreadable`() {
        #expect(throws: WorkshopCatalog.Failure.unreadable) {
            try WorkshopCatalog.parse(Self.page(results: "[]", queryKey: "workshop_access"))
        }
    }

    // MARK: - Fetching

    @Test
    func `a non-200 status throws http`() async {
        await #expect(throws: WorkshopCatalog.Failure.http(429)) {
            try await WorkshopCatalog.page(for: CatalogQuery()) { request in
                (Data(), HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: nil)!)
            }
        }
    }

    @Test
    func `a fetch sends the language and reads the page`() async throws {
        let page = try await WorkshopCatalog.page(for: CatalogQuery(page: 2)) { request in
            #expect(request.value(forHTTPHeaderField: "Accept-Language")?.isEmpty == false)
            #expect(request.url?.absoluteString.hasSuffix("&p=2") == true)
            return (Data(Self.listing.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        #expect(page.items.count == 3)
    }

    // MARK: - Fixtures

    /// A page with the given `results` array, page numbers and query key, wrapped the way
    /// Steam wraps it: `queryData` is a JSON string inside the script's JSON.
    private static func page(results: String, numbers: String = "1, 1, 1", queryKey: String = "workshop_browse") throws -> Data {
        let parts = numbers.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let queryData = """
        {"mutations": [], "queries": [{"state": {"data": {"current_page": \(parts[0]), "total_pages": \(parts[1]),
        "total_count": \(parts[2]), "results": \(results)}}, "queryKey": ["\(queryKey)", {"appid": 431960}, 1]}]}
        """
        let outer = try JSONSerialization.data(withJSONObject: ["renderContext": ["queryData": queryData]])
        return Data(#"<html><script type="application/json" id="valve-ssr-data" nonce="n">"#.utf8)
            + outer + Data("</script></html>".utf8)
    }

    // swiftlint:disable line_length
    /// Page 2 of the trending listing, filtered to Everyone without Web and Application,
    /// cut to three items with the unrelated queries and fields removed.
    private nonisolated static let listing = #"""
    <html><head><title>Steam Workshop::Wallpaper Engine</title></head><body><div id="root"></div>
    <script type="application/json" id="valve-ssr-data" nonce="d0dd45c5-3435-4b65-9687-e77782a47472">{"route":{"path":"/workshop/browse/"},"renderContext":{"localizationSettings":{"languages":[{"strLanguage":"english","strISOCode":"en"}]},"queryData":"{\"mutations\":[],\"queries\":[{\"state\":{\"data\":{\"eresult\":1,\"current_page\":2,\"total_pages\":1000,\"total_count\":2597421,\"results\":[{\"publishedfileid\":\"3844704085\",\"creator\":\"76561198612466080\",\"consumer_appid\":431960,\"preview_url\":\"https://images.steamusercontent.com/ugc/11130907140747170949/DB87B68B9EBD8437CDA939761D8F4E80D43E142A/\",\"title\":\"鸣潮 绮丽幻梦·西格莉卡 by b站 炑月烟火\",\"short_description\":\"关注b站 炑月烟火 谢谢喵~\",\"time_created\":1795434621,\"time_updated\":1795434621,\"file_size\":\"46646108\",\"tags\":[{\"tag\":\"Video\",\"display_name\":\"Video\"},{\"tag\":\"Game\",\"display_name\":\"Game\"},{\"tag\":\"Wallpaper\",\"display_name\":\"Wallpaper\"},{\"tag\":\"Other resolution\",\"display_name\":\"Other resolution\"},{\"tag\":\"Everyone\",\"display_name\":\"Everyone\"}],\"subscriptions\":933,\"favorited\":83,\"views\":53},{\"publishedfileid\":\"3845223430\",\"creator\":\"76561199129632747\",\"consumer_appid\":431960,\"preview_url\":\"https://images.steamusercontent.com/ugc/17122995815022189984/A0C5A2E2231C0C3156FACF1070E0C618B1DEFF82/\",\"title\":\"ulquiorra \u0026 orihime ♥\",\"short_description\":\"\",\"time_created\":1795523760,\"time_updated\":1795523760,\"file_size\":\"5821026\",\"tags\":[{\"tag\":\"Scene\",\"display_name\":\"Scene\"},{\"tag\":\"Anime\",\"display_name\":\"Anime\"},{\"tag\":\"Wallpaper\",\"display_name\":\"Wallpaper\"},{\"tag\":\"1920 x 1080\",\"display_name\":\"1920 x 1080\"},{\"tag\":\"Everyone\",\"display_name\":\"Everyone\"}],\"subscriptions\":20,\"favorited\":3,\"views\":3},{\"publishedfileid\":\"3841859550\",\"creator\":\"76561198203181554\",\"consumer_appid\":431960,\"preview_url\":\"https://images.steamusercontent.com/ugc/12902336045629370686/F19D00E07616ACE6612E999008CBFEC77720A14A/\",\"title\":\"White Sakura 4K HD- warrefear\",\"short_description\":\"\",\"time_created\":1794996759,\"time_updated\":1794996759,\"file_size\":\"6238663\",\"tags\":[{\"tag\":\"Scene\",\"display_name\":\"Scene\"},{\"tag\":\"Relaxing\",\"display_name\":\"Relaxing\"},{\"tag\":\"Wallpaper\",\"display_name\":\"Wallpaper\"},{\"tag\":\"Customizable\",\"display_name\":\"Customizable\"},{\"tag\":\"3840 x 2160\",\"display_name\":\"3840 x 2160\"},{\"tag\":\"Everyone\",\"display_name\":\"Everyone\"}],\"subscriptions\":1094,\"favorited\":42,\"views\":68}]},\"status\":\"success\"},\"queryKey\":[\"workshop_browse\",{\"admin_view\":false,\"appid\":431960,\"browse_sort\":\"trend\",\"childpublishedfileid\":\"\",\"excluded_tags\":[\"Web\",\"Application\"],\"num_per_page\":30,\"page\":2,\"required_apps_preset\":0,\"required_tags\":[\"Everyone\"],\"search_text\":\"\",\"search_text_target\":0,\"section\":\"readytouseitems\",\"trend_days\":7},1]}]}"}}</script>
    </body></html>
    """#
    // swiftlint:enable line_length
}
