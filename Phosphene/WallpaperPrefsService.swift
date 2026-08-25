import AppKit
import Foundation
import os

/// Reads/writes shared preferences to the extension container and signals via Darwin notification.
///
/// The extension reads the same file on startup and when it receives `glass.kagerou.phosphene.prefsChanged`.
/// The extension writes a separate state file (`phosphene-state.json`) with `isActive`, which this service observes.
@MainActor
@Observable
final class WallpaperPrefsService {
    static let shared = WallpaperPrefsService()

    struct WallpaperSelection: Identifiable, Equatable {
        let id: String // "{displayUUID}" or "{displayUUID}:{spaceUUID}"
        let videoID: String
        let displayUUID: String
        let displayName: String
        let displayID: UInt32
        let spaceUUID: String?
        let spaceName: String?
        var videoName: String?
        var videoURL: URL?
    }

    // MARK: - Prefs (app → extension)

    var userPaused = false {
        didSet { guard userPaused != oldValue else { return }; savePrefs() }
    }

    var alwaysPauseDesktop = false {
        didSet { guard alwaysPauseDesktop != oldValue else { return }; savePrefs() }
    }

    var pauseWhenOccluded = false {
        didSet { guard pauseWhenOccluded != oldValue else { return }; savePrefs() }
    }

    /// Updated by OcclusionMonitor when desktop visibility changes.
    /// True only when every display is fully covered.
    var desktopOccluded = false {
        didSet { guard desktopOccluded != oldValue else { return }; savePrefs() }
    }

    /// Displays whose usable area is fully covered by windows (fullscreen games
    /// included — the layer-aware filter, see OcclusionMonitor). Updated by
    /// OcclusionMonitor; the extension pauses these displays individually.
    var occludedDisplays: Set<UInt32> = [] {
        didSet { guard occludedDisplays != oldValue else { return }; savePrefs() }
    }

    /// Displays owned by a single fullscreen app (native fullscreen Space or
    /// borderless-fullscreen game). The extension pauses these unconditionally —
    /// "Pause When Hidden" only governs `occludedDisplays`.
    var fullscreenDisplays: Set<UInt32> = [] {
        didSet { guard fullscreenDisplays != oldValue else { return }; savePrefs() }
    }

    /// Whether any display or Space has a Phosphene choice as its screensaver (the
    /// store's Idle section). Derived from the wallpaper store, relayed to the
    /// extension so idle presentation plays full-screen instead of pausing (#26).
    private(set) var screenSaverIsOurs = false {
        didSet { guard screenSaverIsOurs != oldValue else { return }; savePrefs() }
    }

    // MARK: - Selections (parsed from wallpaper plist)

    private(set) var selections: [WallpaperSelection] = []
    var systemWallpaperIsOurs: Bool {
        !selections.isEmpty
    }

    #if DEBUG
        /// Injects a fabricated selection so the popover renders its full "playing" state on a
        /// machine where Phosphene isn't the active system wallpaper (see ScreenshotGallery).
        func stageGallerySelection(_ selection: WallpaperSelection) {
            selections = [selection]
            isActive = true
        }
    #endif

    var pausedDisplays: Set<UInt32> = [] {
        didSet { guard pausedDisplays != oldValue else { return }; savePrefs() }
    }

    func togglePause(displayID: UInt32) {
        if pausedDisplays.contains(displayID) {
            pausedDisplays.remove(displayID)
        } else {
            pausedDisplays.insert(displayID)
        }
    }

    /// Incremented on space changes to trigger UI refresh.
    private(set) var spaceChangeCount = 0

    // MARK: - State (extension → app, read-only)

    private(set) var isActive = false
    private(set) var currentVideoID: String?
    private(set) var currentVideoName: String?

    // MARK: - Private

    private static var extensionDocsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/glass.kagerou.phosphene.extension/Data/Documents")
    }

    private static var prefsURL: URL {
        extensionDocsURL.appendingPathComponent("phosphene-prefs.json")
    }

    private static var stateURL: URL {
        extensionDocsURL.appendingPathComponent("phosphene-state.json")
    }

    private struct PrefsFile: Codable {
        var userPaused: Bool
        var alwaysPauseDesktop: Bool
        var pauseWhenOccluded: Bool
        var desktopOccluded: Bool
        var occludedDisplays: Set<UInt32>?
        var fullscreenDisplays: Set<UInt32>?
        var pausedDisplays: Set<UInt32>?
        var screenSaverIsOurs: Bool?

        init(userPaused: Bool, alwaysPauseDesktop: Bool, pauseWhenOccluded: Bool = false, desktopOccluded: Bool = false, occludedDisplays: Set<UInt32>? = nil, fullscreenDisplays: Set<UInt32>? = nil, pausedDisplays: Set<UInt32>? = nil, screenSaverIsOurs: Bool? = nil) {
            self.userPaused = userPaused
            self.alwaysPauseDesktop = alwaysPauseDesktop
            self.pauseWhenOccluded = pauseWhenOccluded
            self.desktopOccluded = desktopOccluded
            self.occludedDisplays = occludedDisplays
            self.fullscreenDisplays = fullscreenDisplays
            self.pausedDisplays = pausedDisplays
            self.screenSaverIsOurs = screenSaverIsOurs
        }
    }

    private struct ContextState: Codable {
        var displayID: UInt32
        var videoID: String?
        var videoName: String?
    }

    private struct StateFile: Codable {
        var isActive: Bool
        var currentVideoID: String?
        var currentVideoName: String?
        var contexts: [ContextState]?
    }

    @ObservationIgnored private var wallpaperStoreMonitor: (any DispatchSourceFileSystemObject)?

    private init() {
        loadPrefs()
        loadState()
        checkSystemWallpaper()
        observeStateChanges()
        observeWallpaperStore()
        observeDisplayChanges()
        observeSpaceChanges()
        observeAgentStuck()
    }

    // MARK: - Spiral recovery (kill the stuck WallpaperAgent)

    /// The sandboxed extension can detect WallpaperAgent's spiral-of-death but can't kill it.
    /// It Darwin-signals us (unsandboxed) to `killall WallpaperAgent`, which is the only thing
    /// that resets the Agent's desynced state — it then relaunches and re-acquires cleanly.
    /// Rate-limited so we never loop on kills.
    private var lastAgentKill: Date = .distantPast

    private func observeAgentStuck() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        unsafe CFNotificationCenterAddObserver(
            center,
            nil,
            { _, _, _, _, _ in
                DispatchQueue.main.async { WallpaperPrefsService.shared.restartStuckAgent() }
            },
            "glass.kagerou.phosphene.agentStuck" as CFString,
            nil,
            .deliverImmediately,
        )
    }

    private func restartStuckAgent() {
        let now = Date()
        guard now.timeIntervalSince(lastAgentKill) > 15 else {
            NSLog("[Phosphene] agentStuck signal ignored (killed agent \(Int(now.timeIntervalSince(lastAgentKill)))s ago)")
            return
        }
        lastAgentKill = now
        killWallpaperAgent(reason: "spiral-of-death detected by extension")
    }

    /// Manual restart from the menu bar — user-initiated, so no cooldown.
    func restartWallpaperAgent() {
        lastAgentKill = Date()
        killWallpaperAgent(reason: "manual restart from menu")
    }

    private func killWallpaperAgent(reason: String) {
        NSLog("[Phosphene] killall WallpaperAgent — \(reason)")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        task.arguments = ["WallpaperAgent"]
        try? task.run()
    }

    // MARK: - Public

    func togglePause() {
        userPaused.toggle()
    }

    /// URL to the currently-playing video file in the extension container, if known.
    var currentVideoURL: URL? {
        guard let videoID = currentVideoID else { return nil }
        let entries = VideoDeploymentService.listEntries()
        guard let entry = entries.first(where: { $0.id == videoID }) else { return nil }
        return VideoDeploymentService.videoURL(for: entry)
    }

    // MARK: - Prefs Persistence

    private func loadPrefs() {
        let data: Data
        do {
            data = try Data(contentsOf: Self.prefsURL)
        } catch {
            return // File doesn't exist yet — normal on first launch
        }
        do {
            let prefs = try JSONDecoder().decode(PrefsFile.self, from: data)
            userPaused = prefs.userPaused
            alwaysPauseDesktop = prefs.alwaysPauseDesktop
            pauseWhenOccluded = prefs.pauseWhenOccluded
            desktopOccluded = prefs.desktopOccluded
            occludedDisplays = prefs.occludedDisplays ?? []
            fullscreenDisplays = prefs.fullscreenDisplays ?? []
            pausedDisplays = prefs.pausedDisplays ?? []
        } catch {
            Log.general.error("Failed to decode prefs file: \(error)")
        }
    }

    private func savePrefs() {
        let prefs = PrefsFile(
            userPaused: userPaused,
            alwaysPauseDesktop: alwaysPauseDesktop,
            pauseWhenOccluded: pauseWhenOccluded,
            desktopOccluded: desktopOccluded,
            occludedDisplays: occludedDisplays.isEmpty ? nil : occludedDisplays,
            fullscreenDisplays: fullscreenDisplays.isEmpty ? nil : fullscreenDisplays,
            pausedDisplays: pausedDisplays.isEmpty ? nil : pausedDisplays,
            screenSaverIsOurs: screenSaverIsOurs,
        )
        guard let data = try? JSONEncoder().encode(prefs) else { return }
        try? data.write(to: Self.prefsURL, options: .atomic)

        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(
            center,
            CFNotificationName("glass.kagerou.phosphene.prefsChanged" as CFString),
            nil,
            nil,
            true,
        )
    }

    // MARK: - State Observation

    private func loadState() {
        let data: Data
        do {
            data = try Data(contentsOf: Self.stateURL)
        } catch {
            return // File doesn't exist yet — normal on first launch
        }
        do {
            let state = try JSONDecoder().decode(StateFile.self, from: data)
            isActive = state.isActive
            currentVideoID = state.currentVideoID
            currentVideoName = state.currentVideoName
        } catch {
            Log.general.error("Failed to decode extension state file: \(error)")
        }
    }

    private func observeStateChanges() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        unsafe CFNotificationCenterAddObserver(
            center,
            nil,
            { _, _, _, _, _ in
                DispatchQueue.main.async {
                    WallpaperPrefsService.shared.loadState()
                }
            },
            "glass.kagerou.phosphene.stateChanged" as CFString,
            nil,
            .deliverImmediately,
        )
    }

    // MARK: - System Wallpaper Detection

    private static let wallpaperStoreURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")

    private static let spacesConfigURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Preferences/com.apple.spaces.plist")

    private static let extensionBundleID = "glass.kagerou.phosphene.extension"

    private func checkSystemWallpaper() {
        guard let data = try? Data(contentsOf: Self.wallpaperStoreURL),
              let plist = try? unsafe PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            selections = []
            screenSaverIsOurs = false
            return
        }

        screenSaverIsOurs = Self.idleSelectionIsOurs(plist)

        let displayMap = resolveDisplayMap()
        let spaceMap = resolveSpaceMap()
        let entries = VideoDeploymentService.listEntries()
        var newSelections: [WallpaperSelection] = []

        // Check Displays → {uuid} → Desktop → Content → Choices (all-spaces)
        if let displays = plist["Displays"] as? [String: Any] {
            for (displayUUID, value) in displays {
                guard let display = value as? [String: Any] else { continue }
                guard let videoID = extractOurVideoID(from: display) else { continue }
                guard let info = displayMap[displayUUID] else { continue }
                let entry = entries.first { $0.id == videoID }
                newSelections.append(WallpaperSelection(
                    id: displayUUID,
                    videoID: videoID,
                    displayUUID: displayUUID,
                    displayName: info.name,
                    displayID: info.displayID,
                    spaceUUID: nil,
                    spaceName: nil,
                    videoName: entry?.name,
                    videoURL: entry.map { VideoDeploymentService.videoURL(for: $0) },
                ))
            }
        }

        // Check Spaces → {spaceUUID} → Displays → {displayUUID} → Desktop → ...
        if let spaces = plist["Spaces"] as? [String: Any] {
            for (spaceUUID, spaceValue) in spaces {
                guard let space = spaceValue as? [String: Any] else { continue }
                let spaceName = spaceMap[spaceUUID]

                if let perDisplays = space["Displays"] as? [String: Any] {
                    for (displayUUID, displayValue) in perDisplays {
                        guard let display = displayValue as? [String: Any] else { continue }
                        guard let videoID = extractOurVideoID(from: display) else { continue }
                        guard let info = displayMap[displayUUID] else { continue }
                        guard spaceName != nil else { continue }
                        let entry = entries.first { $0.id == videoID }
                        newSelections.append(WallpaperSelection(
                            id: "\(displayUUID):\(spaceUUID)",
                            videoID: videoID,
                            displayUUID: displayUUID,
                            displayName: info.name,
                            displayID: info.displayID,
                            spaceUUID: spaceUUID,
                            spaceName: spaceName,
                            videoName: entry?.name,
                            videoURL: entry.map { VideoDeploymentService.videoURL(for: $0) },
                        ))
                    }
                }
            }
        }

        // Deduplicate: per-space-per-display wins over all-spaces for the same display
        var coveredDisplays = Set<String>()
        var perSpacePerDisplay: [WallpaperSelection] = []
        var allSpaces: [WallpaperSelection] = []

        for sel in newSelections {
            if sel.spaceUUID != nil {
                perSpacePerDisplay.append(sel)
                coveredDisplays.insert(sel.displayUUID)
            } else {
                allSpaces.append(sel)
            }
        }

        var result = perSpacePerDisplay
        for sel in allSpaces where !coveredDisplays.contains(sel.displayUUID) {
            result.append(sel)
        }

        selections = result.sorted { $0.displayName < $1.displayName }
    }

    /// Whether any Idle (screensaver) selection in the store belongs to Phosphene —
    /// checks the SystemDefault, per-display, per-Space, and per-Space-per-display
    /// records.
    private static func idleSelectionIsOurs(_ plist: [String: Any]) -> Bool {
        func idleIsOurs(_ dict: [String: Any]) -> Bool {
            guard let idle = dict["Idle"] as? [String: Any],
                  let content = idle["Content"] as? [String: Any],
                  let choices = content["Choices"] as? [[String: Any]] else { return false }
            return choices.contains { ($0["Provider"] as? String) == extensionBundleID }
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

    private func extractOurVideoID(from dict: [String: Any]) -> String? {
        guard let desktop = dict["Desktop"] as? [String: Any],
              let content = desktop["Content"] as? [String: Any],
              let choices = content["Choices"] as? [[String: Any]] else {
            return nil
        }
        for choice in choices {
            guard (choice["Provider"] as? String) == Self.extensionBundleID else { continue }
            if let config = choice["Configuration"] as? Data, !config.isEmpty {
                return String(data: config, encoding: .utf8)
            }
            if let config = choice["Configuration"] as? String, !config.isEmpty {
                return config
            }
        }
        return nil
    }

    // MARK: - Display Resolution

    private func resolveDisplayMap() -> [String: (displayID: UInt32, name: String)] {
        var map: [String: (displayID: UInt32, name: String)] = [:]

        if let configClass = NSClassFromString("NSCGSDisplayConfiguration") as? NSObject.Type,
           let config = unsafe configClass.perform(NSSelectorFromString("currentConfiguration"))?.takeUnretainedValue() as? NSObject,
           let displays = config.value(forKey: "uniqueDisplays") as? [NSObject] {
            for display in displays {
                guard let uuid = display.value(forKey: "UUID") as? NSUUID else { continue }
                let uuidString = uuid.uuidString
                let displayID = (display.value(forKey: "displayID") as? UInt32) ?? 0
                let screenName = NSScreen.screens.first(where: {
                    ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32) == displayID
                })?.localizedName ?? "Display"
                map[uuidString] = (displayID: displayID, name: screenName)
            }
        }

        if map.isEmpty {
            for screen in NSScreen.screens {
                guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 else { continue }
                map["fallback-\(screenNumber)"] = (displayID: screenNumber, name: screen.localizedName)
            }
        }

        return map
    }

    // MARK: - Space Resolution

    private func resolveSpaceMap() -> [String: String] {
        guard let data = try? Data(contentsOf: Self.spacesConfigURL),
              let plist = try? unsafe PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let config = plist["SpacesDisplayConfiguration"] as? [String: Any],
              let mgmt = config["Management Data"] as? [String: Any],
              let monitors = mgmt["Monitors"] as? [[String: Any]] else {
            return [:]
        }

        var map: [String: String] = [:]
        for monitor in monitors {
            guard let spaces = monitor["Spaces"] as? [[String: Any]] else { continue }
            for (index, space) in spaces.enumerated() {
                if let uuid = space["uuid"] as? String {
                    map[uuid] = "Space \(index + 1)"
                }
            }
        }
        return map
    }

    private func observeWallpaperStore() {
        let dirURL = Self.wallpaperStoreURL.deletingLastPathComponent()
        let fd = unsafe open(dirURL.path, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: .write,
            queue: .main,
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.checkSystemWallpaper()
            }
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        wallpaperStoreMonitor = source
    }

    // MARK: - Display Change Observer

    @ObservationIgnored private var displayReconfigToken: (any NSObjectProtocol)?

    private func observeDisplayChanges() {
        displayReconfigToken = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main,
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.checkSystemWallpaper()
            }
        }
    }

    // MARK: - Space Change Observer

    private func observeSpaceChanges() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main,
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.spaceChangeCount += 1
                self?.checkSystemWallpaper()
            }
        }
    }
}
