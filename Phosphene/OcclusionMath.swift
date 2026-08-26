import CoreGraphics
import Foundation

/// The pure geometry of occlusion detection — separated from `OcclusionMonitor`'s
/// window-list plumbing so the thresholds and coverage math can be tested. All
/// rects are CG coordinates (top-left origin); callers pre-filter the window list
/// (regular applications only, layers below the chrome floor).
enum OcclusionMath {
    struct Window: Equatable {
        let rect: CGRect
        let layer: Int

        init(rect: CGRect, layer: Int) {
            self.rect = rect
            self.layer = layer
        }
    }

    /// Grid cell size in points. 8pt gives good precision without excessive memory.
    static let cellSize: CGFloat = 8

    /// A single window owning (nearly) the whole display marks it as running a
    /// fullscreen app:
    ///
    /// - At layer 0 covering ≥99% of the FULL frame, menu bar region included —
    ///   a native fullscreen Space, or a borderless window sized to the display.
    /// - At an elevated layer covering ≥95% of the visible frame — borderless
    ///   fullscreen games: Wine parks them just above the menu bar (Genshin: 26),
    ///   and ordinary app windows never sit at elevated layers, so a maximized
    ///   browser can't trip this.
    static func hasFullscreenApp(full: CGRect, visible: CGRect, windows: [Window]) -> Bool {
        let fullArea = full.width * full.height
        let visibleArea = visible.width * visible.height
        for window in windows {
            if window.layer == 0 {
                let overlap = window.rect.intersection(full)
                if overlap.width * overlap.height >= fullArea * 0.99 { return true }
            } else {
                let overlap = window.rect.intersection(visible)
                if overlap.width * overlap.height >= visibleArea * 0.95 { return true }
            }
        }
        return false
    }

    /// Rasterize the screen area into a coarse grid and mark cells covered by
    /// windows — the union, so overlapping windows aren't double-counted.
    /// Returns true if ≥95% of cells are covered.
    static func isOccluded(_ screenRect: CGRect, by windows: [Window]) -> Bool {
        let cell = cellSize
        let cols = Int(ceil(screenRect.width / cell))
        let rows = Int(ceil(screenRect.height / cell))
        let totalCells = cols * rows
        guard totalCells > 0 else { return false }

        // Bit grid: true = covered
        var grid = [Bool](repeating: false, count: totalCells)
        var coveredCount = 0

        for window in windows {
            let clipped = window.rect.intersection(screenRect)
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
