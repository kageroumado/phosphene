import AppKit
import Foundation

/// Build a fully-populated WallpaperSettingsViewModelsXPC using Codable shims.
/// Publishes one SettingsItem per library choice.
func buildSettingsViewModelsXPC() async -> AnyObject? {
    let bundleID = Bundle.main.bundleIdentifier ?? "glass.kagerou.phosphene.extension"
    let library = VideoLibrary.shared
    let groupID = GroupID(id: "video-wallpapers")

    // Always re-scan to pick up changes (deletions, new deployments)
    library.scan()

    let choices = library.choices

    // Right-click menu on the group and every tile. Settings routes presses to
    // invokeContextMenuAction with the item's identifier; the handler opens the
    // matching phosphene:// URL in the companion app.
    let addVideoMenu = ContextMenu(items: [
        ContextMenuItem(
            id: ContextMenuItemID(id: "add-video"),
            localizedTitle: String(localized: "Add Video…"),
            isDestructive: false,
        ),
        ContextMenuItem(
            id: ContextMenuItemID(id: "manage-library"),
            localizedTitle: String(localized: "Manage Library…"),
            isDestructive: false,
        ),
    ])

    var items = [SettingsItem]()
    var thumbnailURLs = [URL]()

    for (entry, record) in choices {
        guard let (item, thumbnail) = await makeVideoItem(entry: entry, record: record, bundleID: bundleID, contextMenu: addVideoMenu) else { continue }
        thumbnailURLs.append(thumbnail)
        items.append(item)
    }

    if items.count >= 2 {
        items.append(makeShuffleItem(
            bundleID: bundleID,
            thumbnailURLs: thumbnailURLs,
            contextMenu: addVideoMenu,
        ))
    }

    // Never serve an empty group: the host can cache it until an OS update or reinstall (issue #27).
    if items.isEmpty, PrefsSource.showAddVideoPlaceholder, let placeholder = makeAddVideoItem(bundleID: bundleID, contextMenu: addVideoMenu) {
        items.append(placeholder)
    }

    let group = SettingsGroup(
        id: groupID,
        items: items,
        localizedName: String(localized: "Phosphene — Video Wallpapers"),
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

    // The same groups serve both pickers: since the Sonoma unified model the
    // screensaver is the wallpaper surface entering idle presentation, so any video
    // choice is screensaver-capable (#26).
    let viewModels = SettingsViewModels(
        desktop: viewModel,
        screenSaver: viewModel,
    )

    return remapToRealXPC(viewModels)
}

private func makeVideoItem(entry: VideoEntry, record: AppearancePair?, bundleID: String, contextMenu: ContextMenu) async -> (SettingsItem, URL)? {
    let library = VideoLibrary.shared
    let pair = record.flatMap { PairRendition($0, library: library)?.pair }
    let name = record?.name ?? entry.name
    let files = library.choiceFiles(for: entry, pair: record)
    let choiceID = ChoiceID(
        id: entry.id,
        descriptor: ChoiceIDDescriptor(
            provider: ChoiceProviderID(rawValue: bundleID),
            identifier: entry.id,
            files: files,
            configuration: Data(entry.id.utf8),
        ),
    )

    // Generate thumbnail — skip entry if extraction fails
    guard var thumbnailURL = await library.generateThumbnail(for: entry) else {
        return nil
    }
    if let pair, let other = library.entry(for: pair.counterpart),
       let otherURL = await library.generateThumbnail(for: other) {
        thumbnailURL = pairThumbnail(pair, owner: thumbnailURL, counterpart: otherURL) ?? thumbnailURL
    }

    let choiceDescriptor = ChoiceDescriptor(
        id: choiceID,
        provider: ChoiceProviderID(rawValue: bundleID),
        identifier: entry.id,
        name: name,
        localizedDescription: pair == nil ? String(localized: "Animated video wallpaper") : "",
        thumbnail: .image(url: thumbnailURL),
        isDownloaded: true,
        options: pair == nil ? [] : [appearancePicker(name: name)],
    )

    let item = SettingsItem(
        id: choiceID,
        localizedName: name,
        thumbnail: .image(url: thumbnailURL),
        choice: choiceDescriptor,
        contentBadge: pair == nil ? .video : .dynamic,
        showInTopLevel: true,
        sortOrder: 0,
        // Purge routes to removeDownload(for:). A removable tile requires a choice request.
        disposability: .purgeable,
        contextMenu: contextMenu,
    )
    return (item, thumbnailURL)
}

private func appearancePicker(name: String) -> WallpaperOption {
    .picker(MenuPickerOption(
        id: PairAppearanceMode.optionID,
        localizedLabel: name,
        defaultValueID: PairAppearanceMode.automatic.rawValue,
        items: PairAppearanceMode.allCases.map { mode in
            let title = switch mode {
            case .automatic: String(localized: "Automatic")
            case .light: String(localized: "Light")
            case .dark: String(localized: "Dark")
            }
            return .item(MenuPickerItem(id: mode.rawValue, localizedName: title, isDownloaded: true))
        },
    ))
}

private func pairThumbnail(_ pair: AppearancePair, owner: URL, counterpart: URL) -> URL? {
    let light = pair.swapped ? counterpart : owner
    let dark = pair.swapped ? owner : counterpart
    guard let a = FileIdentity(of: light), let b = FileIdentity(of: dark) else { return nil }
    let url = URL.cachesDirectory.appendingPathComponent(
        "pair-\(pair.light)-\(a.inode)-\(a.modified.timeIntervalSinceReferenceDate)-\(pair.dark)-\(b.inode)-\(b.modified.timeIntervalSinceReferenceDate).jpg",
    )
    if FileManager.default.fileExists(atPath: url.path) {
        return url
    }
    guard let lightSource = CGImageSourceCreateWithURL(light as CFURL, nil),
          let darkSource = CGImageSourceCreateWithURL(dark as CFURL, nil),
          let left = CGImageSourceCreateImageAtIndex(lightSource, 0, nil),
          let right = CGImageSourceCreateImageAtIndex(darkSource, 0, nil),
          let context = CGContext(
              data: nil,
              width: left.width,
              height: left.height,
              bitsPerComponent: 8,
              bytesPerRow: 0,
              space: CGColorSpace(name: CGColorSpace.sRGB)!,
              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue,
          )
    else { return nil }
    let frame = CGRect(x: 0, y: 0, width: left.width, height: left.height)
    context.draw(left, in: frame)
    context.clip(to: CGRect(x: frame.midX, y: 0, width: frame.width - frame.midX, height: frame.height))
    context.draw(right, in: frame)
    guard let image = context.makeImage(),
          let jpeg = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else { return nil }
    do {
        try jpeg.write(to: url, options: .atomic)
        return url
    } catch {
        extensionLog("[Settings] Pair thumbnail write failed: \(error)")
        return nil
    }
}

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
        case .onWakeup: String(localized: "On Wake")
        case .onLogin: String(localized: "On Login")
        case .fiveMinutes: String(localized: "Every 5 Minutes")
        case .fifteenMinutes: String(localized: "Every 15 Minutes")
        case .thirtyMinutes: String(localized: "Every 30 Minutes")
        case .oneHour: String(localized: "Every Hour")
        case .oneDay: String(localized: "Every Day")
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
        localizedLabel: String(localized: "Change Video"),
        defaultValueID: ShuffleFrequencyID.onWakeup.rawValue,
        accessibilityIdentifier: nil,
        localizedInformativeText: nil,
        items: ShuffleFrequencyID.allCases.map { frequency in
            .item(MenuPickerItem(
                id: frequency.rawValue,
                localizedName: frequency.localizedName,
                accessibilityIdentifier: nil,
                localizedInformativeText: nil,
                isDownloaded: true,
            ))
        },
    )
    return SettingsItem(
        id: choiceID,
        localizedName: String(localized: "Shuffle All"),
        thumbnail: .shuffleImages(urls: thumbnailURLs),
        choice: ChoiceDescriptor(
            id: choiceID,
            provider: ChoiceProviderID(rawValue: bundleID),
            identifier: shuffleChoiceID,
            name: String(localized: "Shuffle All"),
            localizedDescription: String(localized: "Rotate through your video wallpapers"),
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

let addVideoPlaceholderChoiceID = "add-video-placeholder"

/// The tile shown while the library is empty. Selecting it renders the acquire
/// path's gradient fallback (it has no video file); its context menu — and its
/// description — route the user to adding a video.
private func makeAddVideoItem(bundleID: String, contextMenu: ContextMenu) -> SettingsItem? {
    guard let thumbnailURL = placeholderThumbnailURL() else { return nil }
    let id = addVideoPlaceholderChoiceID
    let choiceID = ChoiceID(
        id: id,
        descriptor: ChoiceIDDescriptor(
            provider: ChoiceProviderID(rawValue: bundleID),
            identifier: id,
            files: [],
            configuration: Data(id.utf8),
        ),
    )
    return SettingsItem(
        id: choiceID,
        localizedName: String(localized: "Add Video…"),
        thumbnail: .image(url: thumbnailURL),
        choice: ChoiceDescriptor(
            id: choiceID,
            provider: ChoiceProviderID(rawValue: bundleID),
            identifier: id,
            name: String(localized: "Add Video…"),
            localizedDescription: String(localized: "Right-click to add a video"),
            thumbnail: .image(url: thumbnailURL),
            isDownloaded: true,
            options: [],
        ),
        contentBadge: .none,
        showInTopLevel: true,
        sortOrder: 0,
        disposability: .none,
        contextMenu: contextMenu,
    )
}

/// The placeholder tile's thumbnail: the same gradient the renderer falls back to
/// for a choice with no video file, plus a centered plus badge. Drawn once into
/// the container Documents directory and reused.
private func placeholderThumbnailURL() -> URL? {
    let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Documents/add-video-tile.png")
    if FileManager.default.fileExists(atPath: url.path) {
        return url
    }

    let size = NSSize(width: 480, height: 270)
    let image = NSImage(size: size, flipped: false) { rect in
        let gradient = NSGradient(colors: [
            NSColor(red: 0.2, green: 0.0, blue: 0.5, alpha: 1.0),
            NSColor(red: 0.0, green: 0.3, blue: 0.7, alpha: 1.0),
            NSColor(red: 0.0, green: 0.6, blue: 0.4, alpha: 1.0),
        ])
        gradient?.draw(in: rect, angle: 45)

        let symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 72, weight: .regular)
            .applying(.init(paletteColors: [.white]))
        if let plus = NSImage(systemSymbolName: "plus.circle.fill", accessibilityDescription: "Add")?
            .withSymbolConfiguration(symbolConfiguration) {
            let plusSize = NSSize(width: 80, height: 80)
            let origin = NSPoint(x: rect.midX - plusSize.width / 2, y: rect.midY - plusSize.height / 2)
            plus.draw(in: NSRect(origin: origin, size: plusSize))
        }
        return true
    }

    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:])
    else { return nil }
    do {
        try png.write(to: url)
        return url
    } catch {
        extensionLog("  [Settings] Placeholder thumbnail write failed: \(error)")
        return nil
    }
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
