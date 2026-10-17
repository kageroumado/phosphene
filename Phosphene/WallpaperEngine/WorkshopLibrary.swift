import AppKit
import Foundation
import os

/// The Wallpaper Engine section of the library: where downloads are, which ones
/// are staged, and the queue that turns them into videos.
@MainActor
@Observable
final class WorkshopLibrary {
    /// Where an item stands; whether it is staged for the next batch is separate
    /// (``staged``), since a made video can be staged to be made again.
    nonisolated enum ItemStatus: Equatable, Sendable {
        case available
        case queued
        case rendering(progress: Double, phase: String)
        case made(entryID: String)
        /// Made, but the author has updated the wallpaper since.
        case outdated(entryID: String)
        case failed(String)
        case unsupported(String)

        var isUnsupported: Bool {
            if case .unsupported = self {
                return true
            }
            return false
        }

        /// The reason behind a failure, a refusal or a stale video, for tooltips.
        var explanation: String? {
            switch self {
            case let .unsupported(reason), let .failed(reason): reason
            case .outdated: String(localized: "Updated on the Workshop since its video was made")
            default: nil
            }
        }
    }

    private(set) var sources: [WorkshopSource] = []
    private(set) var items: [WorkshopItem] = []
    private(set) var assessments: [String: WorkshopAssessment] = [:]
    private(set) var records: [String: (entryID: String, record: WorkshopRecord)] = [:]
    private(set) var isScanning = false
    private(set) var hasScanned = false
    /// Items chosen for the next "Make Videos".
    var staged: Set<String> = []

    private(set) var queue: [String] = []
    private(set) var current: String?
    private(set) var progress: Double = 0
    private(set) var phase = ""
    private(set) var failures: [String: String] = [:]

    var settings: WEBakeSettings {
        didSet { save(settings) }
    }

    private(set) var manualFolders: [URL]

    @ObservationIgnored private var watchers: [any DispatchSourceFileSystemObject] = []
    @ObservationIgnored private var watchedFolders: Set<String> = []
    @ObservationIgnored private var rescanPending = false
    @ObservationIgnored private var currentBake: WEBakeHost?
    @ObservationIgnored private var queueTask: Task<Void, Never>?

    private enum Keys {
        static let settings = "workshopBakeSettings"
        static let folders = "workshopFolders"
    }

    init() {
        let defaults = UserDefaults.standard
        settings = (defaults.data(forKey: Keys.settings)
            .flatMap { try? JSONDecoder().decode(WEBakeSettings.self, from: $0) } ?? .standard).normalized
        manualFolders = (defaults.stringArray(forKey: Keys.folders) ?? []).map { URL(fileURLWithPath: $0) }
        Task.detached(name: "Sweep Wallpaper Engine scratch") { Self.sweepScratch() }
    }

    var isSevofluraneInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: WorkshopDiscovery.sevofluraneBundleID) != nil
    }

    /// Open the Wallpaper Engine Workshop: in Steam when an app handles `steam://`
    /// links (Sevoflurane does), otherwise on the web.
    func openWorkshop() {
        let steam = WorkshopDiscovery.workshopURL
        let handled = NSWorkspace.shared.urlForApplication(toOpen: steam) != nil
        NSWorkspace.shared.open(handled ? steam : WorkshopDiscovery.workshopWebURL)
    }

    /// Scratch and output files a bake that never returned (a crash mid-render)
    /// left in the temporary folder. A day old is past any bake still running.
    private nonisolated static func sweepScratch() {
        let manager = FileManager.default
        let cutoff = Date.now.addingTimeInterval(-86_400)
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]
        for url in (try? manager.contentsOfDirectory(at: manager.temporaryDirectory, includingPropertiesForKeys: Array(keys))) ?? []
            where url.lastPathComponent.hasPrefix("phosphene-we-") || url.lastPathComponent.hasPrefix("wallpaper-engine-") {
            guard let modified = try? url.resourceValues(forKeys: keys).contentModificationDate, modified < cutoff else { continue }
            try? manager.removeItem(at: url)
        }
    }

    func item(_ id: String) -> WorkshopItem? {
        items.first { $0.id == id }
    }

    func status(of item: WorkshopItem) -> ItemStatus {
        if current == item.id {
            return .rendering(progress: progress, phase: phase)
        }
        if queue.contains(item.id) {
            return .queued
        }
        if let assessment = assessments[item.id], case let .unsupported(reason) = assessment {
            return .unsupported(reason)
        }
        if let failure = failures[item.id] {
            return .failed(failure)
        }
        if let made = records[item.id] {
            return made.record.sourceModified < item.modified.addingTimeInterval(-1)
                ? .outdated(entryID: made.entryID) : .made(entryID: made.entryID)
        }
        return .available
    }

    // MARK: - Scanning

    /// Find sources and items off the main thread, then publish them.
    func refresh() {
        guard !isScanning else {
            rescanPending = true
            return
        }
        isScanning = true
        let folders = manualFolders
        var known: [String: (modified: Date, assessment: WorkshopAssessment)] = [:]
        for item in items {
            if let assessment = assessments[item.id] {
                known[item.id] = (item.modified, assessment)
            }
        }
        Task {
            let (sources, items, assessments) = await Self.scan(folders: folders, known: known)
            self.sources = sources
            self.items = items
            self.assessments = assessments
            records = VideoDeploymentService.workshopRecords()
            staged = staged.filter { id in assessments[id]?.isRenderable ?? false }
            isScanning = false
            hasScanned = true
            watch(sources)
            if rescanPending {
                rescanPending = false
                refresh()
            }
        }
    }

    /// Sources, their items, and each item's assessment; an item unchanged since
    /// `known` keeps its assessment rather than having its scene parsed again.
    @concurrent
    private nonisolated static func scan(
        folders: [URL], known: [String: (modified: Date, assessment: WorkshopAssessment)],
    ) async -> ([WorkshopSource], [WorkshopItem], [String: WorkshopAssessment]) {
        let sources = WorkshopDiscovery.findSources(manualFolders: folders)
        var items: [WorkshopItem] = []
        var seen = Set<String>()
        // A wallpaper downloaded into two libraries shows once, from the library that
        // has Wallpaper Engine's assets if either does.
        for source in sources.sorted(by: { ($0.assets != nil ? 0 : 1) < ($1.assets != nil ? 0 : 1) }) {
            for item in WorkshopDiscovery.items(in: source) where !seen.contains(item.id) {
                seen.insert(item.id)
                items.append(item)
            }
        }
        items.sort { $0.modified > $1.modified }
        var assessments: [String: WorkshopAssessment] = [:]
        for item in items {
            if let previous = known[item.id], previous.modified == item.modified {
                assessments[item.id] = previous.assessment
            } else {
                assessments[item.id] = WorkshopDiscovery.assess(item)
            }
        }
        return (sources, items, assessments)
    }

    /// Rescan when Steam adds or removes a download.
    private func watch(_ sources: [WorkshopSource]) {
        let folders = Set(sources.map(\.id))
        guard folders != watchedFolders else { return }
        watchedFolders = folders
        for watcher in watchers {
            watcher.cancel()
        }
        watchers = sources.compactMap { source in
            let descriptor = unsafe open(source.contentFolder.path, O_EVTONLY)
            guard descriptor >= 0 else { return nil }
            let watcher = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main,
            )
            watcher.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.scheduleRescan() }
            }
            watcher.setCancelHandler { close(descriptor) }
            watcher.resume()
            return watcher
        }
    }

    @ObservationIgnored private var rescanWork: DispatchWorkItem?

    /// Steam writes a download in several steps; wait for it to settle.
    private func scheduleRescan() {
        rescanWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.refresh() }
        }
        rescanWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    // MARK: - Folders

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "Choose a Steam folder, or a folder of Wallpaper Engine wallpapers.")
        panel.prompt = String(localized: "Add Folder")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard !manualFolders.contains(url) else { return }
        manualFolders.append(url)
        UserDefaults.standard.set(manualFolders.map(\.path), forKey: Keys.folders)
        refresh()
    }

    func removeFolder(_ source: WorkshopSource) {
        manualFolders.removeAll { WorkshopDiscovery.manualSource($0).id == source.id }
        UserDefaults.standard.set(manualFolders.map(\.path), forKey: Keys.folders)
        refresh()
    }

    // MARK: - Making videos

    /// Queue `ids` (default: the staged items) and start working through the queue.
    func makeVideos(_ ids: [String]? = nil) {
        let ids = ids ?? items.map(\.id).filter { staged.contains($0) }
        for id in ids where !queue.contains(id) && current != id {
            queue.append(id)
            failures[id] = nil
        }
        staged.subtract(ids)
        guard queueTask == nil else { return }
        queueTask = Task { await drainQueue() }
    }

    func cancelAll() {
        queue.removeAll()
        currentBake?.cancel()
    }

    private func drainQueue() async {
        while !queue.isEmpty {
            let id = queue.removeFirst()
            guard let item = item(id) else { continue }
            current = id
            progress = 0
            phase = ""
            do {
                try await make(item)
            } catch is CancellationError {
                Log.video.info("Stopped making a video of \(item.title)")
            } catch {
                failures[id] = error.localizedDescription
                Log.video.error("Video of \(item.title) failed: \(error.localizedDescription)")
            }
            current = nil
        }
        records = VideoDeploymentService.workshopRecords()
        queueTask = nil
    }

    /// Make the item's video in the temporary folder, then add it to the library, or
    /// swap it into the entry made earlier so a wallpaper already chosen in System
    /// Settings keeps playing the new version.
    private func make(_ item: WorkshopItem) async throws {
        // One file name per item: the library refuses a second file of the same name.
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("wallpaper-engine-\(item.fileStem).\(item.kind == .video ? item.mainFile?.pathExtension ?? "mp4" : "mov")")
        defer { try? FileManager.default.removeItem(at: output) }
        let record: WorkshopRecord
        switch item.kind {
        case .video:
            guard let source = item.mainFile else { throw WEError.missing(item.file) }
            phase = String(localized: "Adding")
            try await Self.copy(source, to: output)
            record = WorkshopRecord(
                publishedFileID: item.id, sourceModified: item.modified, renderedAt: .now, settings: nil,
                loopDuration: 0, seamless: true, omissions: [],
            )
        default:
            let settings = settings
            let host = WEBakeHost(request: WEBakeRequest(
                folder: item.folder, assets: item.assets, settings: settings, output: output,
            ))
            currentBake = host
            defer { currentBake = nil }
            let result = try await host.run { [weak self] fraction, phase in
                self?.progress = fraction
                self?.phase = phase
            }
            record = WorkshopRecord(
                publishedFileID: item.id, sourceModified: item.modified, renderedAt: .now, settings: settings,
                loopDuration: result.duration, seamless: result.seamless, omissions: result.omissions,
            )
        }

        let entryID: String? = if let existing = records[item.id]?.entryID,
                                  await VideoDeploymentService.replaceVideo(entryID: existing, with: output) {
            existing
        } else {
            await VideoDeploymentService.deployVideo(url: output, name: item.title.isEmpty ? nil : item.title)
        }
        guard let entryID else { throw WEError.malformed("the video could not be added to the library") }
        VideoDeploymentService.writeWorkshopRecord(record, entryID: entryID)
        records = VideoDeploymentService.workshopRecords()
    }

    @concurrent
    private nonisolated static func copy(_ source: URL, to destination: URL) async throws {
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: source, to: destination)
    }

    private func save(_ settings: WEBakeSettings) {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: Keys.settings)
        }
    }
}
