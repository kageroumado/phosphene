import AppKit
import CoreGraphics
import os

/// Monitors, per display, whether the desktop is fully occluded by windows.
///
/// Uses `CGWindowListCopyWindowInfo` to enumerate on-screen windows and a coarse
/// grid rasterization to compute the union of their coverage area, avoiding
/// double-counting from overlapping windows. Each display is judged on its own:
/// a fullscreen game on one display pauses that display's wallpaper while the
/// others keep playing.
///
/// The usable screen area (excluding dock and menu bar) is used as the reference,
/// since windows behind the dock/menu bar don't meaningfully reveal the desktop.
///
/// Combines event-driven checks (app activate/deactivate, space changes) with
/// a low-frequency poll (every 10s) to catch window moves/resizes.
///
/// This lives in the main app (not the extension) because the sandboxed extension
/// can't access `CGWindowList`. Results are communicated via `WallpaperPrefsService`.
@MainActor
@Observable
final class OcclusionMonitor {
    /// Display IDs whose usable area is ≥95% covered by windows.
    private(set) var occludedDisplays: Set<UInt32> = []
    /// Display IDs owned by a single fullscreen app — a native fullscreen Space,
    /// or a borderless-fullscreen game. These pause unconditionally: the wallpaper
    /// is invisible (or reduced to the menu bar sliver) and the app wants the
    /// hardware. "Pause When Hidden" only governs `occludedDisplays`.
    private(set) var fullscreenDisplays: Set<UInt32> = []
    /// Every display is occluded (the pre-per-display global signal; still
    /// written to prefs so the popover's status line can say "Desktop Hidden").
    private(set) var isDesktopOccluded = false

    private var activateObserver: (any NSObjectProtocol)?
    private var spaceObserver: (any NSObjectProtocol)?
    private var deactivateObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var scheduler: NSBackgroundActivityScheduler?

    func startMonitoring() {
        guard activateObserver == nil else {
            checkOcclusion()
            return
        }

        let workspace = NSWorkspace.shared
        let center = workspace.notificationCenter

        activateObserver = center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main,
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.checkOcclusion()
            }
        }

        deactivateObserver = center.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification,
            object: nil, queue: .main,
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.checkOcclusion()
            }
        }

        spaceObserver = center.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil, queue: .main,
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.checkOcclusion()
            }
        }

        // Poll to catch window move/resize (no notification for those)
        let activity = NSBackgroundActivityScheduler(identifier: "glass.kagerou.phosphene.occlusionPoll")
        activity.repeats = true
        activity.interval = 10
        activity.tolerance = 5
        activity.qualityOfService = .utility
        activity.schedule { [weak self] completion in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.checkOcclusion()
                }
                completion(.finished)
            }
        }
        scheduler = activity

        checkOcclusion()
    }

    private func checkOcclusion() {
        let (occluded, fullscreen, all) = computeOcclusion()
        let allOccluded = !all.isEmpty && occluded == all
        guard occluded != occludedDisplays
            || fullscreen != fullscreenDisplays
            || allOccluded != isDesktopOccluded
        else { return }
        occludedDisplays = occluded
        fullscreenDisplays = fullscreen
        isDesktopOccluded = allOccluded
        let prefsService = WallpaperPrefsService.shared
        prefsService.occludedDisplays = occluded
        prefsService.fullscreenDisplays = fullscreen
        prefsService.desktopOccluded = allOccluded
        Log.general.info("Occlusion changed: occluded \(occluded.sorted()), fullscreen \(fullscreen.sorted()) (all: \(allOccluded))")
    }

    // MARK: - Occlusion Calculation

    /// Windows at or above this level are transient system chrome (popup menus,
    /// Notification Center overlays, our own popover) and never count as occluding.
    /// Everything from 0 up to it does: ordinary windows sit at layer 0, and
    /// borderless fullscreen game windows land just above the menu bar — Wine
    /// puts Genshin's at 26, invisible to a layer==0 filter (see
    /// GAME-INTERFERENCE-FINDINGS.md).
    private static let chromeLevelFloor = Int(CGWindowLevelForKey(.popUpMenuWindow))

    /// Only windows of regular applications (Dock-visible, cmd-tabbable — Wine
    /// games included) count as covering. System chrome lives in the same layer
    /// band as borderless games but its owners are agents, never `.regular`, and
    /// much of it is display-sized transparent canvases reported at full alpha:
    /// the Dock's window (layer 20), its desktop-reveal overlay (18), Notification
    /// Center's sidebar canvas (21). Counting those marks displays permanently —
    /// or, for the reveal overlay, exactly while the user admires the wallpaper.
    private static func isRegularApp(_ pid: pid_t, cache: inout [pid_t: Bool]) -> Bool {
        if let cached = cache[pid] { return cached }
        let regular = NSRunningApplication(processIdentifier: pid)?.activationPolicy == .regular
        cache[pid] = regular
        return regular
    }

    /// Rasterize every display and return (occluded, fullscreen-app, all) display IDs.
    private func computeOcclusion() -> (occluded: Set<UInt32>, fullscreen: Set<UInt32>, all: Set<UInt32>) {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.excludeDesktopElements, .optionOnScreenOnly], kCGNullWindowID,
        ) as? [[CFString: Any]] else {
            return ([], [], [])
        }

        var policyCache = [pid_t: Bool]()
        let occludingWindows = windowList.compactMap { window -> OcclusionMath.Window? in
            guard let layer = window[kCGWindowLayer] as? Int,
                  layer >= 0, layer < Self.chromeLevelFloor,
                  let ownerPID = window[kCGWindowOwnerPID] as? pid_t,
                  Self.isRegularApp(ownerPID, cache: &policyCache),
                  let bounds = window[kCGWindowBounds] as? [String: CGFloat],
                  let x = bounds["X"], let y = bounds["Y"],
                  let w = bounds["Width"], let h = bounds["Height"],
                  w > 0, h > 0
            else { return nil }
            return OcclusionMath.Window(rect: CGRect(x: x, y: y, width: w, height: h), layer: layer)
        }

        var occluded = Set<UInt32>()
        var fullscreen = Set<UInt32>()
        var all = Set<UInt32>()

        for screen in NSScreen.screens {
            guard let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            else { continue }

            // visibleFrame excludes the dock and menu bar regions
            let visibleFrame = screen.visibleFrame
            guard visibleFrame.width > 0, visibleFrame.height > 0 else { continue }
            all.insert(displayID)

            // Convert to CG coordinates (top-left origin).
            // NSScreen.frame uses bottom-left; CGWindowList uses top-left.
            let mainHeight = NSScreen.screens.first?.frame.height ?? visibleFrame.height
            let cgVisible = CGRect(
                x: visibleFrame.origin.x,
                y: mainHeight - visibleFrame.origin.y - visibleFrame.height,
                width: visibleFrame.width,
                height: visibleFrame.height,
            )
            let frame = screen.frame
            let cgFull = CGRect(
                x: frame.origin.x,
                y: mainHeight - frame.origin.y - frame.height,
                width: frame.width,
                height: frame.height,
            )

            if OcclusionMath.hasFullscreenApp(full: cgFull, visible: cgVisible, windows: occludingWindows) {
                fullscreen.insert(displayID)
            }
            if OcclusionMath.isOccluded(cgVisible, by: occludingWindows) {
                occluded.insert(displayID)
            }
        }

        return (occluded, fullscreen, all)
    }
}
