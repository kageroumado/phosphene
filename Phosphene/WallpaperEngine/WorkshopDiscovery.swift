import Foundation

/// A place Wallpaper Engine wallpapers are downloaded to: the Steam library of a
/// Windows Steam in a Wine bottle, Steam for Mac, or a folder the user chose.
nonisolated struct WorkshopSource: Identifiable, Hashable {
    enum Kind: String, Codable {
        case sevoflurane
        case crossover
        case whisky
        case steam
        case folder
    }

    /// The content folder's path.
    var id: String {
        contentFolder.path
    }

    let kind: Kind
    let label: String
    /// `steamapps/workshop/content/431960`, or the chosen folder.
    let contentFolder: URL
    /// Wallpaper Engine's `assets` folder in the same library: the base shaders and
    /// textures scenes are drawn with.
    let assets: URL?
}

nonisolated enum WorkshopKind: String, Codable {
    case video
    case scene
    case web
    case application
    case unknown

    var name: String {
        switch self {
        case .video: String(localized: "Video")
        case .scene: String(localized: "Scene")
        case .web: String(localized: "Web")
        case .application: String(localized: "Application")
        case .unknown: String(localized: "Unknown")
        }
    }
}

nonisolated struct WorkshopItem: Identifiable, Hashable {
    /// The folder's name: the Workshop file id under Steam, anything in an added folder.
    let id: String
    let folder: URL
    let title: String
    let kind: WorkshopKind
    /// The entry file as `project.json` names it.
    let file: String
    /// The entry file, when it lies inside the folder.
    let mainFile: URL?
    let preview: URL?
    let contentRating: String?
    /// Latest change to the download; a newer one than a video was made from means
    /// the author updated the wallpaper.
    let modified: Date
    let sizeOnDisk: Int64
    let sourceID: String
    let assets: URL?

    /// The item's page in Steam, for items Steam downloaded.
    var workshopPageURL: URL? {
        guard !id.isEmpty, id.allSatisfy(\.isNumber) else { return nil }
        return URL(string: "steam://url/CommunityFilePage/\(id)")
    }

    /// The id as a file name stem: Workshop ids are digits; an added folder's name
    /// keeps its letters and digits.
    var fileStem: String {
        let stem = id.filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        return stem.isEmpty ? "wallpaper" : String(stem.prefix(64))
    }
}

/// Whether Phosphene can make a video of an item, judged without rendering.
nonisolated enum WorkshopAssessment: Hashable {
    /// Renders with everything it shows.
    case ready
    /// Renders, leaving these out.
    case partial([String])
    /// Cannot become a video, for this reason.
    case unsupported(String)

    var isRenderable: Bool {
        if case .unsupported = self {
            return false
        }
        return true
    }
}

/// What a library entry made from a Workshop item records about it.
nonisolated struct WorkshopRecord: Codable {
    let publishedFileID: String
    let sourceModified: Date
    let renderedAt: Date
    /// `nil` for a video item, which is added as it is.
    let settings: WEBakeSettings?
    let loopDuration: Double
    let seamless: Bool
    let omissions: [String]
}

nonisolated enum WorkshopDiscovery {
    static let appID = "431960"
    static let workshopURL = URL(string: "steam://url/SteamWorkshopPage/431960")!
    static let workshopWebURL = URL(string: "https://steamcommunity.com/app/431960/workshop/")!
    static let sevofluraneBundleID = "glass.kagerou.sevoflurane"
    static let sevofluraneURL = URL(string: "https://kagerou.glass/sevoflurane/?from=phosphene")!

    // MARK: - Sources

    /// Every Steam library that holds Wallpaper Engine or its downloads, then the
    /// folders the user added.
    static func findSources(manualFolders: [URL]) -> [WorkshopSource] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var sources: [WorkshopSource] = []
        let bottleRoots: [(WorkshopSource.Kind, String, URL)] = [
            (.sevoflurane, "Sevoflurane", home.appendingPathComponent("Library/Application Support/Sevoflurane/Bottles")),
            (.crossover, "CrossOver", home.appendingPathComponent("Library/Application Support/CrossOver/Bottles")),
            (.whisky, "Whisky", home.appendingPathComponent("Library/Containers/com.isaacmarovitz.Whisky/Bottles")),
        ]
        for (kind, name, root) in bottleRoots {
            for bottle in subdirectories(of: root) {
                let bottleName = bottle.lastPathComponent
                let label = bottleName == "Steam" ? name : "\(name) · \(bottleName)"
                for program in ["drive_c/Program Files (x86)/Steam", "drive_c/Program Files/Steam"] {
                    let steam = bottle.appendingPathComponent(program)
                    guard isDirectory(steam.appendingPathComponent("steamapps")) else { continue }
                    for library in libraryRoots(steam: steam, bottle: bottle) {
                        if let source = source(library: library, kind: kind, label: label, primary: steam) {
                            sources.append(source)
                        }
                    }
                }
            }
        }
        let macSteam = home.appendingPathComponent("Library/Application Support/Steam")
        for library in libraryRoots(steam: macSteam, bottle: nil) {
            if let source = source(library: library, kind: .steam, label: "Steam", primary: macSteam) {
                sources.append(source)
            }
        }
        for folder in manualFolders {
            let source = manualSource(folder)
            if !sources.contains(where: { $0.id == source.id }) {
                sources.append(source)
            }
        }
        return sources
    }

    private static func source(
        library: URL, kind: WorkshopSource.Kind, label: String, primary: URL,
    ) -> WorkshopSource? {
        let steamapps = library.appendingPathComponent("steamapps")
        let content = steamapps.appendingPathComponent("workshop/content/\(appID)")
        let assets = steamapps.appendingPathComponent("common/wallpaper_engine/assets")
        let hasContent = isDirectory(content)
        let hasAssets = isDirectory(assets)
        guard hasContent || hasAssets else { return nil }
        let suffix = library.standardizedFileURL == primary.standardizedFileURL ? "" : " · \(library.lastPathComponent)"
        return WorkshopSource(
            kind: kind, label: label + suffix, contentFolder: content, assets: hasAssets ? assets : nil,
        )
    }

    /// The Steam folder plus every library `libraryfolders.vdf` lists. Windows paths
    /// in a bottle resolve through its `dosdevices` drive links.
    private static func libraryRoots(steam: URL, bottle: URL?) -> [URL] {
        var roots = [steam]
        let vdf = steam.appendingPathComponent("steamapps/libraryfolders.vdf")
        guard let text = try? String(contentsOf: vdf, encoding: .utf8) else {
            return isDirectory(steam) ? roots : []
        }
        for match in text.matches(of: /"path"\s+"([^"]+)"/) {
            let raw = String(match.output.1).replacingOccurrences(of: "\\\\", with: "\\")
            var url: URL?
            if let bottle, raw.count >= 2, raw.dropFirst().first == ":" {
                let drive = raw.prefix(1).lowercased()
                let rest = raw.dropFirst(2).replacingOccurrences(of: "\\", with: "/")
                let device = bottle.appendingPathComponent("dosdevices/\(drive):").resolvingSymlinksInPath()
                let base = isDirectory(device) ? device : (drive == "c" ? bottle.appendingPathComponent("drive_c") : nil)
                url = base.map { $0.appendingPathComponent(String(rest.drop { $0 == "/" })) }
            } else if raw.hasPrefix("/") {
                url = URL(fileURLWithPath: raw)
            }
            if let url, isDirectory(url),
               !roots.contains(where: { $0.resolvingSymlinksInPath() == url.resolvingSymlinksInPath() }) {
                roots.append(url)
            }
        }
        return roots
    }

    /// A user-chosen folder: a Steam folder, its `steamapps`, the Workshop content
    /// folder, or any folder of wallpaper folders.
    static func manualSource(_ folder: URL) -> WorkshopSource {
        var content = folder
        let candidates = [
            folder.appendingPathComponent("steamapps/workshop/content/\(appID)"),
            folder.appendingPathComponent("workshop/content/\(appID)"),
            folder.appendingPathComponent("content/\(appID)"),
            folder.appendingPathComponent(appID),
        ]
        if let found = candidates.first(where: isDirectory) {
            content = found
        }
        var assets: URL?
        var level = content
        for _ in 0 ..< 6 {
            for relative in ["steamapps/common/wallpaper_engine/assets", "common/wallpaper_engine/assets"] {
                let url = level.appendingPathComponent(relative)
                if isDirectory(url) {
                    assets = url
                }
            }
            if assets != nil {
                break
            }
            level.deleteLastPathComponent()
        }
        return WorkshopSource(kind: .folder, label: folder.lastPathComponent, contentFolder: content, assets: assets)
    }

    // MARK: - Items

    static func items(in source: WorkshopSource) -> [WorkshopItem] {
        let folders = FileManager.default.fileExists(
            atPath: source.contentFolder.appendingPathComponent("project.json").path,
        ) ? [source.contentFolder] : subdirectories(of: source.contentFolder)
        return folders.compactMap { item(at: $0, source: source) }
    }

    /// Files counted toward an item's size and date; a download is a few hundred at most.
    private static let maxFilesPerItem = 20_000

    private static func item(at folder: URL, source: WorkshopSource) -> WorkshopItem? {
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("project.json").path) else {
            return nil
        }
        let project = WEProject(folder: folder)
        let fileExtension = (project.file as NSString).pathExtension.lowercased()
        var kind = WorkshopKind(rawValue: project.type) ?? .unknown
        if kind == .unknown {
            if ["mp4", "webm", "mov", "m4v"].contains(fileExtension) {
                kind = .video
            } else if FileManager.default.fileExists(atPath: folder.appendingPathComponent("scene.pkg").path) {
                kind = .scene
            }
        }
        let (modified, size) = footprint(of: folder)
        return WorkshopItem(
            id: folder.lastPathComponent,
            folder: folder,
            title: project.title,
            kind: kind,
            file: project.file,
            mainFile: project.mainFile,
            preview: project.preview,
            contentRating: project.contentRating,
            modified: modified,
            sizeOnDisk: size,
            sourceID: source.id,
            assets: source.assets,
        )
    }

    /// The newest file date and the total size of the regular files under `folder`.
    private static func footprint(of folder: URL) -> (modified: Date, size: Int64) {
        var modified = Date.distantPast
        var size: Int64 = 0
        var counted = 0
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles],
        ) else { return (modified, size) }
        for case let url as URL in enumerator {
            counted += 1
            guard counted <= maxFilesPerItem else { break }
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            size += Int64(values.fileSize ?? 0)
            if let date = values.contentModificationDate, date > modified {
                modified = date
            }
        }
        return (modified, size)
    }

    // MARK: - Assessment

    static func assess(_ item: WorkshopItem) -> WorkshopAssessment {
        switch item.kind {
        case .video:
            let fileExtension = (item.file as NSString).pathExtension.lowercased()
            guard let mainFile = item.mainFile, FileManager.default.fileExists(atPath: mainFile.path) else {
                return .unsupported(String(localized: "The download isn’t complete."))
            }
            return ["mp4", "mov", "m4v"].contains(fileExtension)
                ? .ready : .unsupported(String(localized: "WebM videos aren’t supported yet."))
        case .scene:
            guard let assets = item.assets else {
                return .unsupported(String(
                    localized: "Scenes need Wallpaper Engine’s own files. Install Wallpaper Engine in the same Steam.",
                ))
            }
            guard GL.shared != nil else { return .unsupported(String(localized: "Scenes need OpenGL.")) }
            do {
                let project = WEProject(folder: item.folder)
                let files = try WEFileSystem(folder: item.folder, assets: assets)
                let scene = try WEScene(files: files, sceneFile: project.file, properties: project.propertyValues)
                if let blocker = scene.blockers.first {
                    return .unsupported(String(localized: "Uses \(blocker), which Phosphene can’t draw yet."))
                }
                let omissions = scene.skipped.keys.sorted().map(describe)
                return omissions.isEmpty ? .ready : .partial(omissions)
            } catch {
                return .unsupported(error.localizedDescription)
            }
        case .web:
            return .unsupported(String(localized: "Web wallpapers aren’t supported yet."))
        case .application:
            return .unsupported(String(localized: "Application wallpapers are Windows programs."))
        case .unknown:
            return .unsupported(String(localized: "Phosphene doesn’t recognize this wallpaper’s type."))
        }
    }

    private static func describe(_ feature: String) -> String {
        switch feature {
        case "sound": String(localized: "sound")
        case "text": String(localized: "text and clocks")
        case "particles": String(localized: "some particles")
        case "3D models": String(localized: "3D models")
        default: feature
        }
    }

    // MARK: - Files

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private static func subdirectories(of url: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles],
        )) ?? []).filter(isDirectory)
    }
}
