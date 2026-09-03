import Foundation

/// Pure parsing of macOS's wallpaper store (`com.apple.wallpaper/Store/Index.plist`)
/// into the provider-owned selections the popover renders. Lifted out of
/// WallpaperPrefsService so the store's schema quirks — macOS 26's collapsed
/// `linked` records and the global `AllSpacesAndDisplays`/`SystemDefault` fallback
/// that backs "Show on all Spaces" — are testable without a live store or AppKit.
enum WallpaperStoreParser {
    /// The display metadata the parser needs, keyed by the store's display UUID.
    struct DisplayInfo: Equatable {
        let displayID: UInt32
        let name: String

        init(displayID: UInt32, name: String) {
            self.displayID = displayID
            self.name = name
        }
    }

    /// A provider-owned selection resolved from the store. The library video's
    /// display name and on-disk URL are layered on by the caller, so they live
    /// on the caller's richer selection type rather than here.
    struct ParsedSelection: Equatable {
        let id: String
        let videoID: String
        let displayUUID: String
        let displayName: String
        let displayID: UInt32
        let spaceUUID: String?
        let spaceName: String?
    }

    /// The provider-owned selections for every display, deduplicated so a
    /// per-Space-per-display choice wins over an all-Spaces one, which in turn
    /// wins over the global fallback, and sorted by display name.
    static func parseSelections(
        plist: [String: Any],
        displayMap: [String: DisplayInfo],
        spaceMap: [String: String],
        provider: String,
    ) -> [ParsedSelection] {
        var allSpacesSelections: [ParsedSelection] = []
        var perSpaceSelections: [ParsedSelection] = []

        // Displays → {uuid} → Desktop → Content → Choices — one choice for every
        // Space on that display.
        if let displays = plist["Displays"] as? [String: Any] {
            for (displayUUID, value) in displays {
                guard let display = value as? [String: Any],
                      let videoID = videoID(in: display, provider: provider),
                      let info = displayMap[displayUUID] else { continue }
                allSpacesSelections.append(ParsedSelection(
                    id: displayUUID,
                    videoID: videoID,
                    displayUUID: displayUUID,
                    displayName: info.name,
                    displayID: info.displayID,
                    spaceUUID: nil,
                    spaceName: nil,
                ))
            }
        }

        // Spaces → {spaceUUID} → Displays → {displayUUID} → Desktop → ... — a choice
        // scoped to one Space on one display.
        if let spaces = plist["Spaces"] as? [String: Any] {
            for (spaceUUID, spaceValue) in spaces {
                guard let space = spaceValue as? [String: Any],
                      let spaceName = spaceMap[spaceUUID],
                      let perDisplays = space["Displays"] as? [String: Any] else { continue }
                for (displayUUID, displayValue) in perDisplays {
                    guard let display = displayValue as? [String: Any],
                          let videoID = videoID(in: display, provider: provider),
                          let info = displayMap[displayUUID] else { continue }
                    perSpaceSelections.append(ParsedSelection(
                        id: "\(displayUUID):\(spaceUUID)",
                        videoID: videoID,
                        displayUUID: displayUUID,
                        displayName: info.name,
                        displayID: info.displayID,
                        spaceUUID: spaceUUID,
                        spaceName: spaceName,
                    ))
                }
            }
        }

        // Per-space-per-display wins over all-spaces for the same display.
        var coveredDisplays = Set(perSpaceSelections.map(\.displayUUID))
        var result = perSpaceSelections
        for sel in allSpacesSelections where !coveredDisplays.contains(sel.displayUUID) {
            result.append(sel)
            coveredDisplays.insert(sel.displayUUID)
        }

        // Global fallback: "Show on all Spaces" with no per-display or per-Space
        // override lands in the top-level `AllSpacesAndDisplays` (or `SystemDefault`)
        // record, and applies to every display without its own selection.
        let globalVideoID = (plist["AllSpacesAndDisplays"] as? [String: Any]).flatMap { videoID(in: $0, provider: provider) }
            ?? (plist["SystemDefault"] as? [String: Any]).flatMap { videoID(in: $0, provider: provider) }
        if let globalVideoID {
            for (displayUUID, info) in displayMap where !coveredDisplays.contains(displayUUID) {
                result.append(ParsedSelection(
                    id: displayUUID,
                    videoID: globalVideoID,
                    displayUUID: displayUUID,
                    displayName: info.name,
                    displayID: info.displayID,
                    spaceUUID: nil,
                    spaceName: nil,
                ))
            }
        }

        return result.sorted { $0.displayName < $1.displayName }
    }

    /// The video ID (a choice's `Configuration` payload) for the first desktop
    /// choice owned by `provider` in a record, or nil.
    static func videoID(in dict: [String: Any], provider: String) -> String? {
        guard let choices = desktopChoices(in: dict) else { return nil }
        for choice in choices {
            guard (choice["Provider"] as? String) == provider else { continue }
            if let config = choice["Configuration"] as? Data, !config.isEmpty {
                return String(data: config, encoding: .utf8)
            }
            if let config = choice["Configuration"] as? String, !config.isEmpty {
                return config
            }
        }
        return nil
    }

    /// Whether any Idle (screensaver) record anywhere in the store is owned by
    /// `provider` — checks the SystemDefault, per-display, per-Space, and
    /// per-Space-per-display records.
    static func idleSelectionIsOurs(_ plist: [String: Any], provider: String) -> Bool {
        func idleIsOurs(_ dict: [String: Any]) -> Bool {
            (idleChoices(in: dict) ?? []).contains { ($0["Provider"] as? String) == provider }
        }
        if let systemDefault = plist["SystemDefault"] as? [String: Any], idleIsOurs(systemDefault) {
            return true
        }
        if let displays = plist["Displays"] as? [String: Any] {
            for value in displays.values {
                if let display = value as? [String: Any], idleIsOurs(display) { return true }
            }
        }
        if let spaces = plist["Spaces"] as? [String: Any] {
            for spaceValue in spaces.values {
                guard let space = spaceValue as? [String: Any] else { continue }
                if idleIsOurs(space) { return true }
                for displayValue in (space["Displays"] as? [String: Any])?.values ?? [String: Any]().values {
                    if let display = displayValue as? [String: Any], idleIsOurs(display) { return true }
                }
            }
        }
        return false
    }

    /// The desktop choices in a record. macOS 26 collapses a record's Desktop and
    /// Idle into one `Linked` sub-record (`Type == "linked"`) when both point at the
    /// same choice, so a missing `Desktop` falls back to `Linked`.
    private static func desktopChoices(in dict: [String: Any]) -> [[String: Any]]? {
        let content = (dict["Desktop"] as? [String: Any])?["Content"] as? [String: Any]
            ?? (dict["Linked"] as? [String: Any])?["Content"] as? [String: Any]
        return content?["Choices"] as? [[String: Any]]
    }

    /// The idle (screensaver) choices in a record. Under the `linked` schema Idle
    /// mirrors Desktop under `Linked`, so a `linked` record reads its choices there.
    private static func idleChoices(in dict: [String: Any]) -> [[String: Any]]? {
        let content = (dict["Idle"] as? [String: Any])?["Content"] as? [String: Any]
            ?? ((dict["Type"] as? String) == "linked"
                ? (dict["Linked"] as? [String: Any])?["Content"] as? [String: Any]
                : nil)
        return content?["Choices"] as? [[String: Any]]
    }
}
