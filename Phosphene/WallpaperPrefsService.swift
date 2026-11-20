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

    /// Seconds between two agent kills that the app starts on its own.
    private static let agentKillCooldown: TimeInterval = 15

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
        guard Self.extensionStampedRecovery(before: now) else {
            NSLog("[Phosphene] agentStuck signal ignored (no fresh recovery stamp from the extension)")
            return
        }
        guard now.timeIntervalSince(lastAgentKill) > Self.agentKillCooldown else {
            NSLog("[Phosphene] agentStuck signal ignored (killed agent \(Int(now.timeIntervalSince(lastAgentKill)))s ago)")
            return
        }
        lastAgentKill = now
        killWallpaperAgent(reason: "spiral-of-death detected by extension")
    }

    /// Seconds a recovery stamp stays good for; the extension writes it immediately before signaling.
    private static let recoveryStampWindow: TimeInterval = 10

    /// Whether the extension itself asked for this restart. A Darwin notification names no sender
    /// and any process on the Mac can post one, so the notification alone proves nothing. The
    /// extension writes the time to `phosphene-last-recovery` in its container just before it
    /// signals, and macOS lets only this team's code write there.
    private static func extensionStampedRecovery(before now: Date) -> Bool {
        let stampURL = extensionDocsURL.appendingPathComponent("phosphene-last-recovery")
        guard let data = try? Data(contentsOf: stampURL),
              let text = String(data: data, encoding: .utf8),
              let stamp = Double(text.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return false }
        return (-1 ... recoveryStampWindow).contains(now.timeIntervalSince1970 - stamp)
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

        screenSaverIsOurs = WallpaperStoreParser.idleSelectionIsOurs(plist, provider: Self.extensionBundleID)

        let displayMap = resolveDisplayMap().mapValues {
            WallpaperStoreParser.DisplayInfo(displayID: $0.displayID, name: $0.name)
        }
        let entries = VideoDeploymentService.listEntries()
        let parsed = WallpaperStoreParser.parseSelections(
            plist: plist,
            displayMap: displayMap,
            spaceMap: resolveSpaceMap(displayMap: displayMap),
            provider: Self.extensionBundleID,
        )

        // Layer the library video's display name and on-disk URL onto each parsed
        // selection; the parser resolves everything the store itself knows.
        selections = parsed.map { sel in
            let entry = entries.first { $0.id == sel.videoID }
            return WallpaperSelection(
                id: sel.id,
                videoID: sel.videoID,
                displayUUID: sel.displayUUID,
                displayName: sel.displayName,
                displayID: sel.displayID,
                spaceUUID: sel.spaceUUID,
                spaceName: sel.spaceName,
                videoName: entry?.name,
                videoURL: entry.map { VideoDeploymentService.videoURL(for: $0) },
            )
        }
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
                })?.localizedName ?? String(localized: "Display")
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

    private func resolveSpaceMap(
        displayMap: [String: WallpaperStoreParser.DisplayInfo],
    ) -> [String: WallpaperStoreParser.SpaceInfo] {
        guard let data = try? Data(contentsOf: Self.spacesConfigURL),
              let plist = try? unsafe PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let config = plist["SpacesDisplayConfiguration"] as? [String: Any],
              let mgmt = config["Management Data"] as? [String: Any],
              let monitors = mgmt["Monitors"] as? [[String: Any]] else {
            return [:]
        }

        // Each monitor record is keyed by its display's UUID, except the primary
        // display's, which is "Main". When Spaces span every display, "Main" is the
        // only record holding Spaces and its Spaces belong to all displays.
        let separateSpaces = monitors.contains { monitor in
            (monitor["Display Identifier"] as? String) != "Main"
                && !((monitor["Spaces"] as? [[String: Any]]) ?? []).isEmpty
        }
        let mainDisplayID = CGMainDisplayID()
        let mainDisplayUUID = displayMap.first { $0.value.displayID == mainDisplayID }?.key

        var map: [String: WallpaperStoreParser.SpaceInfo] = [:]
        for monitor in monitors {
            guard let spaces = monitor["Spaces"] as? [[String: Any]] else { continue }
            let identifier = monitor["Display Identifier"] as? String
            let owner = identifier == "Main" ? (separateSpaces ? mainDisplayUUID : nil) : identifier?.uppercased()
            for (index, space) in spaces.enumerated() {
                if let uuid = space["uuid"] as? String {
                    map[uuid] = WallpaperStoreParser.SpaceInfo(
                        name: String(localized: "Space \(index + 1)"),
                        displayUUID: owner,
                    )
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
    @ObservationIgnored private var knownDisplayIDs: Set<UInt32> = WallpaperPrefsService.connectedDisplayIDs()
    @ObservationIgnored private var displaySetRestart: DispatchWorkItem?

    private static func connectedDisplayIDs() -> Set<UInt32> {
        Set(NSScreen.screens.compactMap {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        })
    }

    private func observeDisplayChanges() {
        displayReconfigToken = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main,
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.checkSystemWallpaper()
                self?.restartAgentIfDisplaySetChanged()
            }
        }
    }

    /// When a display is connected or disconnected (a laptop lid closing on an external
    /// monitor, a dock unplugged), WallpaperAgent keeps the surfaces it already has and
    /// does not re-read the per-display choices in the wallpaper store, so a display can
    /// keep showing another display's video until the agent restarts. Restart it once the
    /// reconfiguration has settled, only when the connected set actually changed and a
    /// Phosphene video is in use. (`selections` covers connected displays only, so after a
    /// lid closes it can no longer show that another display had a different video.)
    /// A restart that falls inside the agent-kill cooldown waits for the cooldown to end.
    private func restartAgentIfDisplaySetChanged() {
        let current = Self.connectedDisplayIDs()
        guard current != knownDisplayIDs else { return }
        knownDisplayIDs = current
        scheduleDisplaySetRestart(after: 2.5)
    }

    /// Schedules the one pending display-set restart, replacing any earlier one.
    private func scheduleDisplaySetRestart(after delay: TimeInterval) {
        displaySetRestart?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.selections.isEmpty else { return }
                let wait = Self.agentKillCooldown - Date().timeIntervalSince(self.lastAgentKill)
                guard wait <= 0 else {
                    NSLog("[Phosphene] display-set restart deferred \(Int(wait.rounded(.up)))s (agent killed recently)")
                    self.scheduleDisplaySetRestart(after: wait)
                    return
                }
                self.lastAgentKill = Date()
                self.killWallpaperAgent(reason: "connected displays changed")
            }
        }
        displaySetRestart = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
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
