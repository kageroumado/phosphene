import AppKit
import Foundation

/// A place in the library window's sidebar.
enum LibrarySection: Hashable, RawRepresentable {
    /// The defaults key the library window keeps its section in; set it before
    /// opening the window to open at that section.
    static let storageKey = "librarySection"

    case allVideos
    case inUse
    /// Every Wallpaper Engine wallpaper found on this Mac.
    case workshopAll
    /// The wallpapers that can become a video and have no current one.
    case workshopReady
    /// One Steam library or added folder, by ``WorkshopSource/id``.
    case workshopSource(String)
    /// The Steam Workshop's listing of Wallpaper Engine wallpapers.
    case catalog

    init?(rawValue: String) {
        switch rawValue {
        case "all": self = .allVideos
        case "inUse": self = .inUse
        case "workshop": self = .workshopAll
        case "workshop.ready": self = .workshopReady
        case "workshop.catalog": self = .catalog
        default:
            guard rawValue.hasPrefix("source:") else { return nil }
            self = .workshopSource(String(rawValue.dropFirst("source:".count)))
        }
    }

    var rawValue: String {
        switch self {
        case .allVideos: "all"
        case .inUse: "inUse"
        case .workshopAll: "workshop"
        case .workshopReady: "workshop.ready"
        case let .workshopSource(id): "source:\(id)"
        case .catalog: "workshop.catalog"
        }
    }

    /// What a section lists.
    enum Content {
        /// The library's videos.
        case videos
        /// Wallpaper Engine wallpapers on this Mac.
        case downloads
        /// Wallpapers on the Steam Workshop.
        case catalog
    }

    var content: Content {
        switch self {
        case .allVideos, .inUse: .videos
        case .workshopAll, .workshopReady, .workshopSource: .downloads
        case .catalog: .catalog
        }
    }
}

enum LibraryViewMode: String {
    case icons
    case list
}

/// Icon sizes for the grid, the width of one thumbnail in points. A thumbnail is drawn
/// at exactly this width, so the largest size stays within the 640-pixel thumbnails the
/// library keeps (320 points at 2x).
enum LibraryIconSize {
    static let range: ClosedRange<Double> = 120 ... 320
    static let standard: Double = 180
    static let step: Double = 40

    static func clamped(_ size: Double) -> Double {
        min(range.upperBound, max(range.lowerBound, size))
    }
}

/// One library video, flattened for sorting in a table.
nonisolated struct VideoRow: Identifiable, Sendable {
    let entry: VideoDeploymentService.EntryInfo
    let isInUse: Bool
    let fileSize: Int64

    var id: String {
        entry.id
    }

    var name: String {
        entry.name
    }

    var pixelCount: Int {
        Int(entry.resolution.width * entry.resolution.height)
    }

    var fps: Double {
        entry.fps
    }

    var duration: Double {
        entry.duration
    }

    var dateAdded: Date {
        entry.dateAdded
    }

    var resolutionLabel: String {
        switch (Int(entry.resolution.width), Int(entry.resolution.height)) {
        case (0, _): "—"
        case (3_840, 2_160): "4K"
        case (2_560, 1_440): "1440p"
        case (1_920, 1_080): "1080p"
        case let (width, height): "\(width) × \(height)"
        }
    }
}

/// One Wallpaper Engine download, flattened for sorting in a table.
nonisolated struct WorkshopRow: Identifiable, Sendable {
    let item: WorkshopItem
    let status: WorkshopLibrary.ItemStatus
    let sourceLabel: String
    /// The library video made from the download, once there is one.
    let video: VideoDeploymentService.EntryInfo?

    var id: String {
        item.id
    }

    var title: String {
        item.title
    }

    var kindName: String {
        item.kind.name
    }

    var statusName: String {
        switch status {
        case .available: String(localized: "Not Made")
        case .queued: String(localized: "Waiting")
        case let .rendering(progress, _):
            String(localized: "Making \(progress.formatted(.percent.precision(.fractionLength(0))))")
        case .made: String(localized: "Made")
        case .outdated: String(localized: "Outdated")
        case .failed: String(localized: "Failed")
        case .unsupported: String(localized: "Unsupported")
        }
    }

    /// Orders rows the way a person scans them: what needs doing first.
    var statusRank: Int {
        switch status {
        case .rendering: 0
        case .queued: 1
        case .outdated: 2
        case .failed: 3
        case .available: 4
        case .made: 5
        case .unsupported: 6
        }
    }

    var size: Int64 {
        item.sizeOnDisk
    }

    var modified: Date {
        item.modified
    }
}

/// What one grid tile draws: a library video or a Wallpaper Engine download.
nonisolated struct LibraryTileModel: Identifiable, Equatable {
    enum Badge: Equatable {
        case inUse
        case made
        case outdated
        case failed
        case unsupported
        case waiting
        /// Asked of Steam, with the download yet to arrive.
        case getting
        /// A Workshop wallpaper that is on this Mac.
        case downloaded
        /// Work on the item, with its completed fraction.
        case working(label: String, progress: Double)
    }

    /// How the image fills the tile.
    enum ImageFit: Equatable {
        /// Cropped to fill: a video's thumbnail, made at the video's aspect ratio.
        case fill
        /// Fit at no more than one image pixel per screen pixel: a Workshop preview.
        case actualSize
        /// Scaled to fit the tile, small images enlarged: the Workshop listing, whose
        /// previews are squares of a few hundred pixels.
        case fit
    }

    let id: String
    let title: String
    let image: URL?
    let imageFit: ImageFit
    /// The file a tile plays while the pointer rests on it.
    let video: URL?
    let placeholderSymbol: String
    let isDimmed: Bool
    let badge: Badge?
    let help: String
}

/// Finder's click rules for a grid: a click selects one item, ⌘-click toggles one,
/// ⇧-click extends from the last clicked item.
enum GridSelection {
    static func click(
        _ id: String, in ordered: [String], selection: inout Set<String>, anchor: inout String?,
    ) {
        let modifiers = NSEvent.modifierFlags
        if modifiers.contains(.command) {
            if selection.contains(id) {
                selection.remove(id)
            } else {
                selection.insert(id)
            }
            anchor = id
        } else if modifiers.contains(.shift), let anchor,
                  let start = ordered.firstIndex(of: anchor), let end = ordered.firstIndex(of: id) {
            selection.formUnion(ordered[min(start, end) ... max(start, end)])
        } else {
            selection = [id]
            anchor = id
        }
    }
}
