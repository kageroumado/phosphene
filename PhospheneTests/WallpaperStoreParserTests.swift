import Foundation
import Testing

/// Tests for the wallpaper-store parser — the logic behind whether the popover
/// shows a "playing" preview or the empty state. The field bugs lived in the
/// store's schema variance: macOS 26's collapsed `linked` records and the global
/// `AllSpacesAndDisplays`/`SystemDefault` fallback that backs "Show on all Spaces"
/// (issue #31), neither of which the original per-display/per-Space parse handled.
struct WallpaperStoreParserTests {
    typealias Parser = WallpaperStoreParser
    typealias DisplayInfo = WallpaperStoreParser.DisplayInfo

    private static let ours = "glass.kagerou.phosphene.extension"
    private static let foreign = "com.apple.wallpaper.choice.sequoia"

    private static let displayA = "AAAAAAAA-0000-0000-0000-000000000001"
    private static let displayB = "BBBBBBBB-0000-0000-0000-000000000002"

    // MARK: - Fixture builders

    /// A wallpaper choice; `videoID` becomes the `Configuration` payload, encoded
    /// the way macOS stores it (UTF-8 `Data`).
    private func choice(provider: String, videoID: String? = nil) -> [String: Any] {
        var choice: [String: Any] = ["Provider": provider]
        if let videoID {
            choice["Configuration"] = Data(videoID.utf8)
        }
        return choice
    }

    /// The pre-macOS-26 record shape: a `Desktop` sub-record with its own choices.
    private func desktopRecord(_ choices: [[String: Any]]) -> [String: Any] {
        ["Desktop": ["Content": ["Choices": choices]]]
    }

    /// A macOS 26 `linked` record: Desktop and Idle collapsed under `Linked`.
    private func linkedRecord(_ choices: [[String: Any]]) -> [String: Any] {
        ["Type": "linked", "Linked": ["Content": ["Choices": choices]]]
    }

    /// A record carrying a separate `Idle` (screensaver) sub-record.
    private func idleRecord(_ choices: [[String: Any]]) -> [String: Any] {
        ["Idle": ["Content": ["Choices": choices]]]
    }

    private var displayMapAB: [String: DisplayInfo] {
        [
            Self.displayA: DisplayInfo(displayID: 1, name: "Display A"),
            Self.displayB: DisplayInfo(displayID: 2, name: "Display B"),
        ]
    }

    private func parse(
        _ plist: [String: Any],
        displayMap: [String: DisplayInfo]? = nil,
        spaceMap: [String: String] = [:],
    ) -> [Parser.ParsedSelection] {
        Parser.parseSelections(
            plist: plist,
            displayMap: displayMap ?? displayMapAB,
            spaceMap: spaceMap,
            provider: Self.ours,
        )
    }

    // MARK: - Per-display desktop records

    @Test
    func `individual schema desktop record is parsed`() {
        let plist: [String: Any] = ["Displays": [Self.displayA: desktopRecord([choice(provider: Self.ours, videoID: "vid-A")])]]
        let result = parse(plist)
        #expect(result.count == 1)
        #expect(result.first?.videoID == "vid-A")
        #expect(result.first?.displayUUID == Self.displayA)
        #expect(result.first?.spaceUUID == nil)
    }

    /// The macOS 26 regression that emptied the popover (issue #31): the desktop
    /// choice lives under `Linked`, not `Desktop`.
    @Test
    func `linked schema desktop record is parsed`() {
        let plist: [String: Any] = ["Displays": [Self.displayA: linkedRecord([choice(provider: Self.ours, videoID: "vid-A")])]]
        let result = parse(plist)
        #expect(result.count == 1)
        #expect(result.first?.videoID == "vid-A")
    }

    @Test
    func `foreign provider is ignored`() {
        let plist: [String: Any] = ["Displays": [Self.displayA: desktopRecord([choice(provider: Self.foreign, videoID: "sequoia")])]]
        #expect(parse(plist).isEmpty)
    }

    @Test
    func `string configuration is accepted`() {
        let plist: [String: Any] = ["Displays": [Self.displayA: desktopRecord([["Provider": Self.ours, "Configuration": "vid-str"]])]]
        #expect(parse(plist).first?.videoID == "vid-str")
    }

    @Test
    func `display not in map is skipped`() {
        let unknown = "CCCCCCCC-0000-0000-0000-000000000003"
        let plist: [String: Any] = ["Displays": [unknown: desktopRecord([choice(provider: Self.ours, videoID: "vid")])]]
        #expect(parse(plist).isEmpty)
    }

    // MARK: - Global fallback (Show on all Spaces)

    @Test
    func `global system default fallback covers every display`() {
        let plist: [String: Any] = ["SystemDefault": desktopRecord([choice(provider: Self.ours, videoID: "vid-global")])]
        let result = parse(plist)
        #expect(result.count == 2)
        #expect(result.allSatisfy { $0.videoID == "vid-global" })
        #expect(Set(result.map(\.displayUUID)) == [Self.displayA, Self.displayB])
    }

    /// The reporter's exact configuration: "Show on all Spaces" on macOS 26, so a
    /// `linked` global record — the two fixes have to compose.
    @Test
    func `global linked system default fallback covers every display`() {
        let plist: [String: Any] = ["SystemDefault": linkedRecord([choice(provider: Self.ours, videoID: "vid-global")])]
        #expect(parse(plist).count == 2)
    }

    @Test
    func `all spaces and displays takes precedence over system default`() {
        let plist: [String: Any] = [
            "AllSpacesAndDisplays": desktopRecord([choice(provider: Self.ours, videoID: "vid-all")]),
            "SystemDefault": desktopRecord([choice(provider: Self.ours, videoID: "vid-default")]),
        ]
        #expect(parse(plist).allSatisfy { $0.videoID == "vid-all" })
    }

    @Test
    func `per display record is not overridden by global fallback`() {
        let plist: [String: Any] = [
            "Displays": [Self.displayA: desktopRecord([choice(provider: Self.ours, videoID: "vid-A")])],
            "SystemDefault": desktopRecord([choice(provider: Self.ours, videoID: "vid-global")]),
        ]
        let result = parse(plist)
        #expect(result.count == 2)
        #expect(result.first { $0.displayUUID == Self.displayA }?.videoID == "vid-A")
        #expect(result.first { $0.displayUUID == Self.displayB }?.videoID == "vid-global")
    }

    /// A display the user deliberately set to another provider's wallpaper keeps
    /// it — the global fallback fills only the displays with no record of their own,
    /// so it must not repaint an explicit foreign choice as ours.
    @Test
    func `foreign per display record is not overridden by global fallback`() {
        let plist: [String: Any] = [
            "Displays": [Self.displayA: desktopRecord([choice(provider: Self.foreign, videoID: "sequoia")])],
            "SystemDefault": desktopRecord([choice(provider: Self.ours, videoID: "vid-global")]),
        ]
        let result = parse(plist)
        #expect(result.count == 1)
        #expect(result.first?.displayUUID == Self.displayB)
        #expect(result.first?.videoID == "vid-global")
    }

    @Test
    func `foreign global record produces no selections`() {
        let plist: [String: Any] = ["SystemDefault": desktopRecord([choice(provider: Self.foreign, videoID: "sequoia")])]
        #expect(parse(plist).isEmpty)
    }

    // MARK: - Per-Space records

    @Test
    func `per space per display wins over all spaces`() {
        let space = "SPACE-001"
        let plist: [String: Any] = [
            "Displays": [Self.displayA: desktopRecord([choice(provider: Self.ours, videoID: "vid-all")])],
            "Spaces": [space: ["Displays": [Self.displayA: desktopRecord([choice(provider: Self.ours, videoID: "vid-space")])]]],
        ]
        let result = parse(plist, displayMap: [Self.displayA: DisplayInfo(displayID: 1, name: "Display A")], spaceMap: [space: "Space 1"])
        #expect(result.count == 1)
        #expect(result.first?.videoID == "vid-space")
        #expect(result.first?.spaceUUID == space)
        #expect(result.first?.spaceName == "Space 1")
    }

    @Test
    func `per space record without A known name is skipped`() {
        let plist: [String: Any] = ["Spaces": ["SPACE-unknown": ["Displays": [Self.displayA: desktopRecord([choice(provider: Self.ours, videoID: "vid")])]]]]
        #expect(parse(plist, spaceMap: [:]).isEmpty)
    }

    // MARK: - Shape and ordering

    @Test
    func `selections are sorted by display name`() {
        let displayMap = [
            Self.displayA: DisplayInfo(displayID: 1, name: "Zeta"),
            Self.displayB: DisplayInfo(displayID: 2, name: "Alpha"),
        ]
        let plist: [String: Any] = ["SystemDefault": desktopRecord([choice(provider: Self.ours, videoID: "vid")])]
        #expect(parse(plist, displayMap: displayMap).map(\.displayName) == ["Alpha", "Zeta"])
    }

    @Test
    func `empty plist yields no selections`() {
        #expect(parse([:]).isEmpty)
    }

    // MARK: - Idle (screensaver) detection

    @Test
    func `idle detects our screensaver in individual record`() {
        let plist: [String: Any] = ["SystemDefault": idleRecord([choice(provider: Self.ours)])]
        #expect(Parser.idleSelectionIsOurs(plist, provider: Self.ours))
    }

    @Test
    func `idle detects our screensaver in linked record`() {
        let plist: [String: Any] = ["Displays": [Self.displayA: linkedRecord([choice(provider: Self.ours, videoID: "vid")])]]
        #expect(Parser.idleSelectionIsOurs(plist, provider: Self.ours))
    }

    @Test
    func `idle detects our screensaver per space per display`() {
        let plist: [String: Any] = ["Spaces": ["SPACE-001": ["Displays": [Self.displayA: idleRecord([choice(provider: Self.ours)])]]]]
        #expect(Parser.idleSelectionIsOurs(plist, provider: Self.ours))
    }

    @Test
    func `idle ignores foreign screensaver`() {
        let plist: [String: Any] = ["SystemDefault": idleRecord([choice(provider: Self.foreign)])]
        #expect(!Parser.idleSelectionIsOurs(plist, provider: Self.ours))
    }

    @Test
    func `idle false when no screensaver record`() {
        #expect(!Parser.idleSelectionIsOurs([:], provider: Self.ours))
    }
}
