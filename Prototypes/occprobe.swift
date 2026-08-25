import AppKit
import CoreGraphics

// Replicates Phosphene OcclusionMonitor's math, but reports PER DISPLAY,
// and lists the biggest layer-0 windows so we can see how Genshin's
// borderless window presents to CGWindowList.

guard let windowList = CGWindowListCopyWindowInfo(
    [.excludeDesktopElements, .optionOnScreenOnly], kCGNullWindowID
) as? [[CFString: Any]] else {
    print("CGWindowList failed"); exit(1)
}

let normal = windowList.filter { ($0[kCGWindowLayer] as? Int) == 0 }

print("== layer-0 windows (area >= 500000 px), CG top-left coords ==")
for w in normal {
    guard let b = w[kCGWindowBounds] as? [String: CGFloat],
          let x = b["X"], let y = b["Y"], let wd = b["Width"], let h = b["Height"],
          wd * h >= 500_000 else { continue }
    let owner = w[kCGWindowOwnerName] as? String ?? "?"
    let name = w[kCGWindowName] as? String ?? ""
    print(String(format: "  %@ | %@ | x=%.0f y=%.0f %ldx%ld", owner, name, x, y, Int(wd), Int(h)))
}

let cell: CGFloat = 8
let mainHeight = NSScreen.screens.first?.frame.height ?? 0

print("\n== per-display coverage (Phosphene grid math, >=95% = occluded) ==")
for screen in NSScreen.screens {
    let vf = screen.visibleFrame
    guard vf.width > 0, vf.height > 0 else { continue }
    let did = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    let cg = CGRect(x: vf.origin.x, y: mainHeight - vf.origin.y - vf.height,
                    width: vf.width, height: vf.height)
    let cols = Int(ceil(cg.width / cell)), rows = Int(ceil(cg.height / cell))
    var grid = [Bool](repeating: false, count: cols * rows)
    var covered = 0
    for w in normal {
        guard let b = w[kCGWindowBounds] as? [String: CGFloat],
              let x = b["X"], let y = b["Y"], let wd = b["Width"], let h = b["Height"],
              wd > 0, h > 0 else { continue }
        let clipped = CGRect(x: x, y: y, width: wd, height: h).intersection(cg)
        guard !clipped.isNull else { continue }
        let minC = max(0, Int(floor((clipped.minX - cg.minX) / cell)))
        let maxC = min(cols - 1, Int(floor((clipped.maxX - cg.minX - 0.01) / cell)))
        let minR = max(0, Int(floor((clipped.minY - cg.minY) / cell)))
        let maxR = min(rows - 1, Int(floor((clipped.maxY - cg.minY - 0.01) / cell)))
        guard minC <= maxC, minR <= maxR else { continue }
        for r in minR ... maxR {
            for c in minC ... maxC where !grid[r * cols + c] {
                grid[r * cols + c] = true; covered += 1
            }
        }
    }
    let pct = 100.0 * Double(covered) / Double(cols * rows)
    print(String(format: "  displayID %u  frame %.0fx%.0f  coverage %.1f%%  occluded=%@",
                 did, vf.width, vf.height, pct, pct >= 95 ? "YES" : "no"))
}
