import AppKit
import Foundation

/// Build a fully-populated WallpaperSettingsViewModelsXPC using Codable shims.
/// Creates one SettingsItem per video in the library.
func buildSettingsViewModelsXPC() async -> AnyObject? {
    let bundleID = Bundle.main.bundleIdentifier ?? "glass.kagerou.phosphene.extension"
    let library = VideoLibrary.shared
    let groupID = GroupID(id: "video-wallpapers")

    // Always re-scan to pick up changes (deletions, new deployments)
    library.scan()

    let entries = library.entries

    // Right-click menu on the group and every tile. Settings routes the press to
    // invokeContextMenuAction with this identifier; the handler opens
    // phosphene://add-video, which launches the app's video chooser.
    let addVideoMenu = ContextMenu(items: [
        ContextMenuItem(
            id: ContextMenuItemID(id: "add-video"),
            localizedTitle: "Add Video\u{2026}",
            isDestructive: false,
        ),
    ])

    var items = [SettingsItem]()
    var thumbnailURLs = [URL]()

    for entry in entries {
        let videoURL = library.videoURL(for: entry)
        let choiceID = ChoiceID(
            id: entry.id,
            descriptor: ChoiceIDDescriptor(
                provider: ChoiceProviderID(rawValue: bundleID),
                identifier: entry.id,
                files: [videoURL],
                configuration: Data(entry.id.utf8),
            ),
        )

        // Generate thumbnail — skip entry if extraction fails
        guard let thumbnailURL = await library.generateThumbnail(for: entry) else {
            continue
        }
        thumbnailURLs.append(thumbnailURL)

        let choiceDescriptor = ChoiceDescriptor(
            id: choiceID,
            provider: ChoiceProviderID(rawValue: bundleID),
            identifier: entry.id,
            name: entry.name,
            localizedDescription: "Animated video wallpaper",
            thumbnail: .image(url: thumbnailURL),
            isDownloaded: true,
            options: [],
        )

        let item = SettingsItem(
            id: choiceID,
            localizedName: entry.name,
            thumbnail: .image(url: thumbnailURL),
            choice: choiceDescriptor,
            contentBadge: .video,
            showInTopLevel: true,
            sortOrder: 0,
            disposability: .removable,
            contextMenu: addVideoMenu,
        )
        items.append(item)
    }

    if items.count >= 2 {
        items.append(makeShuffleItem(
            bundleID: bundleID,
            thumbnailURLs: thumbnailURLs,
            contextMenu: addVideoMenu,
        ))
    }

    let group = SettingsGroup(
        id: groupID,
        items: items,
        localizedName: "Phosphene \u{2014} Video Wallpapers",
        disposability: .none,
        sortOrder: -100,
        sortID: GroupSortID(id: "com.apple.wallpaper.aerials"),
        allChoiceID: nil,
        shouldHideItemLabels: false,
        contextMenu: addVideoMenu,
        thumbnail: nil,
    )

    let viewModel = SettingsViewModel(
        groups: [group],
        refreshPolicy: .default,
        isModificationDisabled: false,
    )

    let viewModels = SettingsViewModels(
        desktop: viewModel,
        screenSaver: nil,
    )

    return remapToRealXPC(viewModels)
}

/// The sentinel choice identifier for the shuffle tile. Acquires arriving with this
/// configuration mean "rotate through the library" rather than one fixed video.
let shuffleChoiceID = "shuffle-all"

/// Item ids for the shuffle frequency picker. The ids and their interpretation are
/// Phosphene's own; the system only stores and returns the selected id.
enum ShuffleFrequencyID: String, CaseIterable {
    case onWakeup
    case onLogin
    case fiveMinutes
    case fifteenMinutes
    case thirtyMinutes
    case oneHour
    case oneDay

    var localizedName: String {
        switch self {
        case .onWakeup: "On Wake"
        case .onLogin: "On Login"
        case .fiveMinutes: "Every 5 Minutes"
        case .fifteenMinutes: "Every 15 Minutes"
        case .thirtyMinutes: "Every 30 Minutes"
        case .oneHour: "Every Hour"
        case .oneDay: "Every Day"
        }
    }

    /// Rotation period for the timed frequencies; nil for the event-driven ones.
    var interval: TimeInterval? {
        switch self {
        case .onWakeup, .onLogin: nil
        case .fiveMinutes: 5 * 60
        case .fifteenMinutes: 15 * 60
        case .thirtyMinutes: 30 * 60
        case .oneHour: 60 * 60
        case .oneDay: 24 * 60 * 60
        }
    }
}

/// A "Shuffle" choice modeled on Apple's aerial shuffle tiles: a composite
/// shuffleImages thumbnail plus a frequency picker in the choice's settings header.
private func makeShuffleItem(bundleID: String, thumbnailURLs: [URL], contextMenu: ContextMenu) -> SettingsItem {
    let choiceID = ChoiceID(
        id: shuffleChoiceID,
        descriptor: ChoiceIDDescriptor(
            provider: ChoiceProviderID(rawValue: bundleID),
            identifier: shuffleChoiceID,
            files: [],
            configuration: Data(shuffleChoiceID.utf8),
        ),
    )
    let frequencyPicker = MenuPickerOption(
        id: "shuffleFrequency",
        localizedLabel: "Change Video",
        defaultValueID: ShuffleFrequencyID.onWakeup.rawValue,
        accessibilityIdentifier: nil,
        localizedInformativeText: nil,
        items: ShuffleFrequencyID.allCases.map { frequency in
            .item(MenuPickerItem(
                id: frequency.rawValue,
                localizedName: frequency.localizedName,
                accessibilityIdentifier: nil,
                localizedInformativeText: nil,
            ))
        },
    )
    return SettingsItem(
        id: choiceID,
        localizedName: "Shuffle All",
        thumbnail: .shuffleImages(urls: thumbnailURLs),
        choice: ChoiceDescriptor(
            id: choiceID,
            provider: ChoiceProviderID(rawValue: bundleID),
            identifier: shuffleChoiceID,
            name: "Shuffle All",
            localizedDescription: "Rotate through your video wallpapers",
            thumbnail: .shuffleImages(urls: thumbnailURLs),
            isDownloaded: true,
            options: [.picker(frequencyPicker)],
        ),
        contentBadge: .video,
        showInTopLevel: true,
        sortOrder: 1_000,
        disposability: .none,
        contextMenu: contextMenu,
    )
}

/// Fallback: create a WallpaperSettingsViewModelsXPC with empty groups.
func makeEmptyGroupsResponse() -> AnyObject? {
    let emptyViewModels = SettingsViewModels(
        desktop: SettingsViewModel(
            groups: [],
            refreshPolicy: .default,
            isModificationDisabled: false,
        ),
        screenSaver: nil,
    )
    return remapToRealXPC(emptyViewModels)
}

/// Archive via ShimViewModelsXPC, remap class name on unarchive to the real XPC type.
///
/// Secure coding cannot be required here: the whole point is to archive our own
/// `ShimViewModelsXPC` and decode it back as the private `WallpaperSettingsViewModelsXPC`
/// via `setClass(_:forClassName:)`, a substitution secure coding is designed to
/// forbid. This is safe because the archive is never persisted or received over
/// any boundary — it is produced and consumed in-process within this one function
/// from values we just constructed, so there is no untrusted input to defend
/// against. The decoded object is handed straight back to WallpaperAgent.
private func remapToRealXPC(_ viewModels: SettingsViewModels) -> AnyObject? {
    let shimXPC = ShimViewModelsXPC(value: viewModels)

    let data: Data
    do {
        data = try NSKeyedArchiver.archivedData(withRootObject: shimXPC, requiringSecureCoding: false)
    } catch {
        extensionLog("  [Remap] Archive failed: \(error)")
        return nil
    }

    guard let realClass = objc_getClass("WallpaperSettingsViewModelsXPC") as? AnyClass else {
        extensionLog("  [Remap] WallpaperSettingsViewModelsXPC class not found")
        return nil
    }

    guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else {
        extensionLog("  [Remap] Failed to create unarchiver")
        return nil
    }
    unarchiver.requiresSecureCoding = false
    unarchiver.decodingFailurePolicy = .setErrorAndReturn
    unarchiver.setClass(realClass, forClassName: "ShimViewModelsXPC")

    let result = unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey)
    if let error = unarchiver.error {
        extensionLog("  [Remap] Unarchive error: \(error)")
    }
    unarchiver.finishDecoding()

    if result == nil {
        extensionLog("  [Remap] Decoded result is nil")
    }
    return result as AnyObject?
}
