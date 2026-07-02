import AppKit
import CoreGraphics
import os

/// Monitors whether the desktop is fully occluded by windows.
///
/// Uses `CGWindowListCopyWindowInfo` to enumerate on-screen windows and a coarse
/// grid rasterization to compute the union of their coverage area, avoiding
/// double-counting from overlapping windows.
///
/// The usable screen area (excluding dock and menu bar) is used as the reference,
/// since windows behind the dock/menu bar don't meaningfully reveal the desktop.
///
/// Combines event-driven checks (app activate/deactivate, space changes) with
/// a low-frequency poll (every 3s) to catch window moves/resizes.
///
/// This lives in the main app (not the extension) because the sandboxed extension
/// can't access `CGWindowList`. Results are communicated via `WallpaperPrefsService`.
@MainActor
@Observable
final class OcclusionMonitor {
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

    func stopMonitoring() {
        let center = NSWorkspace.shared.notificationCenter
        if let observer = activateObserver {
            center.removeObserver(observer)
            activateObserver = nil
        }
        if let observer = deactivateObserver {
            center.removeObserver(observer)
            deactivateObserver = nil
        }
        if let observer = spaceObserver {
            center.removeObserver(observer)
            spaceObserver = nil
        }
        scheduler?.invalidate()
        scheduler = nil

        if isDesktopOccluded {
            isDesktopOccluded = false
            WallpaperPrefsService.shared.desktopOccluded = false
        }
    }

    private func checkOcclusion() {
        let occluded = computeDesktopOcclusion()
        guard occluded != isDesktopOccluded else { return }
        isDesktopOccluded = occluded
        WallpaperPrefsService.shared.desktopOccluded = occluded
        Log.general.info("Desktop occlusion changed: \(occluded)")
    }

    // MARK: - Occlusion Calculation

    /// Grid cell size in points. 8pt gives good precision without excessive memory.
    private static let cellSize: CGFloat = 8

    private func computeDesktopOcclusion() -> Bool {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.excludeDesktopElements, .optionOnScreenOnly], kCGNullWindowID,
        ) as? [[CFString: Any]] else {
            return false
        }

        // Filter to normal windows (layer 0) — excludes dock, menu bar, system UI
        let normalWindows = windowList.filter { window in
            guard let layer = window[kCGWindowLayer] as? Int else { return false }
            return layer == 0
        }

        for screen in NSScreen.screens {
            // visibleFrame excludes the dock and menu bar regions
            let visibleFrame = screen.visibleFrame
            guard visibleFrame.width > 0, visibleFrame.height > 0 else { continue }

            // Convert visibleFrame to CG coordinates (top-left origin).
            // NSScreen.frame uses bottom-left; CGWindowList uses top-left.
            let mainHeight = NSScreen.screens.first?.frame.height ?? visibleFrame.height
            let cgVisible = CGRect(
                x: visibleFrame.origin.x,
                y: mainHeight - visibleFrame.origin.y - visibleFrame.height,
                width: visibleFrame.width,
                height: visibleFrame.height,
            )

            if !isScreenOccluded(cgVisible, by: normalWindows) {
                return false
            }
        }

        return true
    }

    /// Rasterize the screen area into a coarse grid and mark cells covered by windows.
    /// Returns true if >= 95% of cells are covered.
    private func isScreenOccluded(_ screenRect: CGRect, by windows: [[CFString: Any]]) -> Bool {
        let cell = Self.cellSize
        let cols = Int(ceil(screenRect.width / cell))
        let rows = Int(ceil(screenRect.height / cell))
        let totalCells = cols * rows
        guard totalCells > 0 else { return false }

        // Bit grid: true = covered
        var grid = [Bool](repeating: false, count: totalCells)
        var coveredCount = 0

        for window in windows {
            guard let boundsDict = window[kCGWindowBounds] as? [String: CGFloat],
                  let x = boundsDict["X"],
                  let y = boundsDict["Y"],
                  let w = boundsDict["Width"],
                  let h = boundsDict["Height"],
                  w > 0, h > 0 else { continue }

            let windowRect = CGRect(x: x, y: y, width: w, height: h)
            let clipped = windowRect.intersection(screenRect)
            guard !clipped.isNull else { continue }

            // Convert to grid coordinates
            let minCol = max(0, Int(floor((clipped.minX - screenRect.minX) / cell)))
            let maxCol = min(cols - 1, Int(floor((clipped.maxX - screenRect.minX - 0.01) / cell)))
            let minRow = max(0, Int(floor((clipped.minY - screenRect.minY) / cell)))
            let maxRow = min(rows - 1, Int(floor((clipped.maxY - screenRect.minY - 0.01) / cell)))

            guard minCol <= maxCol, minRow <= maxRow else { continue }

            for row in minRow ... maxRow {
                let base = row * cols
                for col in minCol ... maxCol {
                    let idx = base + col
                    if !grid[idx] {
                        grid[idx] = true
                        coveredCount += 1
                    }
                }
            }

            // Early exit: already fully covered
            if coveredCount == totalCells { return true }
        }

        let coverage = Double(coveredCount) / Double(totalCells)
        return coverage >= 0.95
    }
}
