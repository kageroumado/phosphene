import Foundation

struct SettingsViewModels: Codable {
    var desktop: SettingsViewModel?
    var screenSaver: SettingsViewModel?
}

struct SettingsViewModel: Codable {
    var groups: [SettingsGroup]
    var refreshPolicy: RefreshPolicy
    var isModificationDisabled: Bool
}

struct SettingsGroup: Codable {
    var id: GroupID
    var items: [SettingsItem]
    var localizedName: String
    var disposability: Disposability
    var sortOrder: Int
    var sortID: GroupSortID?
    var allChoiceID: ChoiceID?
    var shouldHideItemLabels: Bool?
    var contextMenu: ContextMenu?
    var thumbnail: Data?
}

/// Real type: WallpaperTypes.WallpaperDisposability with cases: none, removable, purgeable
enum Disposability: Codable {
    case none
    case removable
    case purgeable

    private enum CodingKeys: String, CodingKey {
        case none
        case removable
        case purgeable
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .none:
            _ = container.nestedContainer(keyedBy: EmptyCodingKeys.self, forKey: .none)
        case .removable:
            _ = container.nestedContainer(keyedBy: EmptyCodingKeys.self, forKey: .removable)
        case .purgeable:
            _ = container.nestedContainer(keyedBy: EmptyCodingKeys.self, forKey: .purgeable)
        }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.none) { self = .none } else if container.contains(.removable) { self = .removable } else if container.contains(.purgeable) { self = .purgeable } else { self = .none }
    }
}

/// ID types use keyed container with "id" property
struct GroupID: Codable {
    var id: String
}

struct GroupSortID: Codable {
    var id: String
}

struct ChoiceID: Codable {
    var id: String
    var descriptor: ChoiceIDDescriptor
}

/// Nested descriptor inside WallpaperChoiceID — contains provider info
struct ChoiceIDDescriptor: Codable {
    var provider: ChoiceProviderID
    var identifier: String
    var files: [URL]
    var configuration: Data
}

struct SettingsItem: Codable {
    var id: ChoiceID
    var localizedName: String
    var thumbnail: Thumbnail
    var choice: ChoiceDescriptor
    var contentBadge: ContentBadge
    var showInTopLevel: Bool
    var sortOrder: Int
    var disposability: Disposability
    var contextMenu: ContextMenu?
}

/// WallpaperSettingsItem.ContentBadge — cases: none, video, dynamic
enum ContentBadge: Codable {
    case none
    case video
    case dynamic

    private enum CodingKeys: String, CodingKey {
        case none
        case video
        case dynamic
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .none:
            _ = container.nestedContainer(keyedBy: EmptyCodingKeys.self, forKey: .none)
        case .video:
            _ = container.nestedContainer(keyedBy: EmptyCodingKeys.self, forKey: .video)
        case .dynamic:
            _ = container.nestedContainer(keyedBy: EmptyCodingKeys.self, forKey: .dynamic)
        }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.none) { self = .none } else if container.contains(.video) { self = .video } else if container.contains(.dynamic) { self = .dynamic } else { self = .none }
    }
}

/// WallpaperThumbnail — enum with cases: image, solidColor, customButton, shuffleColors, shuffleImages, currentColorOption.
/// shuffleImages renders the composite shuffle tile (stacked thumbnails + rotate badge).
enum Thumbnail: Codable {
    case image(url: URL)
    case shuffleImages(urls: [URL])
    case customButton(CustomButton)

    private enum CodingKeys: String, CodingKey {
        case image
        case shuffleImages
        case customButton
    }

    private enum ImageCodingKeys: String, CodingKey {
        case url
    }

    private enum ShuffleImagesCodingKeys: String, CodingKey {
        case urls
    }

    /// Unlabeled associated values use `_0`, `_1`, etc. as keys in Swift's auto-synthesized Codable
    private enum CustomButtonCodingKeys: String, CodingKey {
        case _0
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .image(url):
            var nested = container.nestedContainer(keyedBy: ImageCodingKeys.self, forKey: .image)
            try nested.encode(url, forKey: .url)
        case let .shuffleImages(urls):
            var nested = container.nestedContainer(keyedBy: ShuffleImagesCodingKeys.self, forKey: .shuffleImages)
            try nested.encode(urls, forKey: .urls)
        case let .customButton(button):
            var nested = container.nestedContainer(keyedBy: CustomButtonCodingKeys.self, forKey: .customButton)
            try nested.encode(button, forKey: ._0)
        }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.image) {
            let nested = try container.nestedContainer(keyedBy: ImageCodingKeys.self, forKey: .image)
            let url = try nested.decode(URL.self, forKey: .url)
            self = .image(url: url)
        } else if container.contains(.shuffleImages) {
            let nested = try container.nestedContainer(keyedBy: ShuffleImagesCodingKeys.self, forKey: .shuffleImages)
            let urls = try nested.decode([URL].self, forKey: .urls)
            self = .shuffleImages(urls: urls)
        } else if container.contains(.customButton) {
            let nested = try container.nestedContainer(keyedBy: CustomButtonCodingKeys.self, forKey: .customButton)
            let button = try nested.decode(CustomButton.self, forKey: ._0)
            self = .customButton(button)
        } else {
            self = .image(url: URL(fileURLWithPath: "/"))
        }
    }
}

/// WallpaperTypes.CustomButton — enum with cases: addPhotoButton, addColorButton, shuffleColorsButton
enum CustomButton: Codable {
    case addPhotoButton
    case addColorButton
    case shuffleColorsButton

    private enum CodingKeys: String, CodingKey {
        case addPhotoButton
        case addColorButton
        case shuffleColorsButton
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .addPhotoButton:
            _ = container.nestedContainer(keyedBy: EmptyCodingKeys.self, forKey: .addPhotoButton)
        case .addColorButton:
            _ = container.nestedContainer(keyedBy: EmptyCodingKeys.self, forKey: .addColorButton)
        case .shuffleColorsButton:
            _ = container.nestedContainer(keyedBy: EmptyCodingKeys.self, forKey: .shuffleColorsButton)
        }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.addPhotoButton) { self = .addPhotoButton } else if container.contains(.addColorButton) { self = .addColorButton } else if container.contains(.shuffleColorsButton) { self = .shuffleColorsButton } else { self = .addPhotoButton }
    }
}

struct ChoiceDescriptor: Codable {
    var id: ChoiceID
    var provider: ChoiceProviderID
    var identifier: String
    var name: String?
    var localizedDescription: String
    var thumbnail: Thumbnail
    var isDownloaded: Bool
    var options: [WallpaperOption]
}

/// Real type: WallpaperTypes.WallpaperOptionEnum — the per-choice settings controls
/// shown in the wallpaper header when the choice is selected. Cases: picker, color,
/// toggle, group, button; payloads use the synthesized `_0` key. Only picker is
/// modeled here.
enum WallpaperOption: Codable {
    case picker(MenuPickerOption)

    private enum CodingKeys: String, CodingKey {
        case picker
    }

    private enum PayloadCodingKeys: String, CodingKey {
        case _0
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .picker(option):
            var nested = container.nestedContainer(keyedBy: PayloadCodingKeys.self, forKey: .picker)
            try nested.encode(option, forKey: ._0)
        }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let nested = try container.nestedContainer(keyedBy: PayloadCodingKeys.self, forKey: .picker)
        self = try .picker(nested.decode(MenuPickerOption.self, forKey: ._0))
    }
}

/// Real type: WallpaperTypes.MenuPickerOption — a labeled popup in the choice's
/// settings header. The system stores the selected item id per choice and hands it
/// back to the extension; item ids and their meaning are the provider's own.
struct MenuPickerOption: Codable {
    var id: String
    var localizedLabel: String
    var defaultValueID: String
    var accessibilityIdentifier: String?
    var localizedInformativeText: String?
    var items: [MenuPickerItemEnum]
}

/// Real type: WallpaperTypes.MenuPickerItemEnum — cases: item, divider (payload `_0`).
enum MenuPickerItemEnum: Codable {
    case item(MenuPickerItem)
    case divider(MenuPickerDivider)

    private enum CodingKeys: String, CodingKey {
        case item
        case divider
    }

    private enum PayloadCodingKeys: String, CodingKey {
        case _0
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .item(item):
            var nested = container.nestedContainer(keyedBy: PayloadCodingKeys.self, forKey: .item)
            try nested.encode(item, forKey: ._0)
        case let .divider(divider):
            var nested = container.nestedContainer(keyedBy: PayloadCodingKeys.self, forKey: .divider)
            try nested.encode(divider, forKey: ._0)
        }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.item) {
            let nested = try container.nestedContainer(keyedBy: PayloadCodingKeys.self, forKey: .item)
            self = try .item(nested.decode(MenuPickerItem.self, forKey: ._0))
        } else {
            let nested = try container.nestedContainer(keyedBy: PayloadCodingKeys.self, forKey: .divider)
            self = try .divider(nested.decode(MenuPickerDivider.self, forKey: ._0))
        }
    }
}

struct MenuPickerItem: Codable {
    var id: String
    var localizedName: String
    var accessibilityIdentifier: String?
    var localizedInformativeText: String?
}

struct MenuPickerDivider: Codable {
    var id: String
}

/// Encodes as a plain string (singleValueContainer)
struct ChoiceProviderID: Codable {
    var rawValue: String

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.rawValue = try container.decode(String.self)
    }
}

enum RefreshPolicy: Codable {
    case `default`

    private enum CodingKeys: String, CodingKey {
        case `default`
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .default:
            _ = container.nestedContainer(keyedBy: EmptyCodingKeys.self, forKey: .default)
        }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.default) {
            self = .default
        } else {
            self = .default
        }
    }
}

/// Real type: WallpaperTypes.ContextMenu { items: [ContextMenuItem] }
struct ContextMenu: Codable {
    var items: [ContextMenuItem]
}

/// Real type: WallpaperTypes.ContextMenuItem { id: ContextMenuItem.ID, localizedTitle: String, isDestructive: Bool }
struct ContextMenuItem: Codable {
    var id: ContextMenuItemID
    var localizedTitle: String
    var isDestructive: Bool
}

struct ContextMenuItemID: Codable {
    var id: String
}

enum EmptyCodingKeys: CodingKey {}

/// NSObject wrapper that encodes SettingsViewModels using the same key as the real XPC type
@objc(ShimViewModelsXPC)
class ShimViewModelsXPC: NSObject, NSSecureCoding {
    static let supportsSecureCoding = true
    let value: SettingsViewModels

    init(value: SettingsViewModels) {
        self.value = value
        super.init()
    }

    required init?(coder _: NSCoder) {
        fatalError("decode not needed")
    }

    func encode(with coder: NSCoder) {
        guard let archiver = coder as? NSKeyedArchiver else {
            extensionLog("  [ShimXPC] encode error: coder is not NSKeyedArchiver")
            return
        }
        do {
            try archiver.encodeEncodable(value, forKey: "WallpaperSettingsViewModels")
        } catch {
            extensionLog("  [ShimXPC] encode error: \(error)")
        }
    }
}
