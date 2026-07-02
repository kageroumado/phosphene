import Foundation
import QuartzCore

/// Diagnostic: replace the video pipeline with a pure Core-Animation color sweep so the
/// desktop↔lock reveal can be characterized visually. A `CABasicAnimation` runs on the
/// render server (WindowServer) independently of our AVSampleBufferDisplayLayer / control
/// timebase, so its behavior DURING the reveal isolates what the compositor does to our
/// hosted context:
///   • sweep keeps moving smoothly  → the black is video-frame-delivery specific (the
///     AVSBDL has no frame for "now"); the context/compositing itself is fine.
///   • sweep FREEZES mid-travel     → the compositor pauses our layer for the transition.
///   • sweep JUMPS / snaps to start  → a reset (our layer/animation is being re-added).
///   • area goes BLACK               → the surface is being cleared to black, i.e. the
///     problem is the context, not the video — a much deeper issue.
///
/// Toggle by adding/removing `~Documents/COLOR_DIAG` in the extension container and
/// relaunching the Agent (`killall WallpaperAgent`) — no rebuild, mirrors `Bisect`.
enum ColorDiag {
    static var enabled: Bool {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/COLOR_DIAG")
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// Displays that already have the sweep installed. Touched ONLY on `Lifecycle.queue`.
    nonisolated(unsafe) static var installed: Set<DisplayKey> = []
}

/// Install the color-sweep layer onto the display's root layer (idempotent per display).
/// Base fill is solid green; a magenta bar sweeps left→right→left forever. Must run on
/// `Lifecycle.queue`.
func colorDiagInstall(rootLayer: CALayer, for key: DisplayKey) {
    guard !ColorDiag.installed.contains(key) else { return }
    ColorDiag.installed.insert(key)

    let bounds = rootLayer.bounds

    CATransaction.begin()
    CATransaction.setDisableActions(true)

    // Solid base color so any true-black (surface cleared) is unmistakable against it.
    rootLayer.contents = nil
    rootLayer.backgroundColor = CGColor(red: 0.0, green: 0.55, blue: 0.25, alpha: 1.0) // green

    // Remove any prior sweep (stale renderer/still sublayers too) so only the bar shows.
    rootLayer.sublayers?.forEach { $0.removeFromSuperlayer() }

    let fill = CALayer()
    fill.name = "colorDiag.fill"
    fill.anchorPoint = CGPoint(x: 0.0, y: 0.5) // grow rightward from the left edge
    fill.position = CGPoint(x: 0.0, y: bounds.midY)
    fill.bounds = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height)
    fill.backgroundColor = CGColor(red: 0.9, green: 0.1, blue: 0.6, alpha: 1.0) // magenta
    rootLayer.addSublayer(fill)

    CATransaction.commit()

    // Sweep the bar's width 0 → full → 0, linearly, forever. A steady linear travel makes
    // freezes, jumps, and skips obvious to the eye during the reveal.
    let sweep = CABasicAnimation(keyPath: "bounds.size.width")
    sweep.fromValue = 0.0
    sweep.toValue = bounds.width
    sweep.duration = 2.5
    sweep.autoreverses = true
    sweep.repeatCount = .infinity
    sweep.timingFunction = CAMediaTimingFunction(name: .linear)
    sweep.isRemovedOnCompletion = false
    fill.add(sweep, forKey: "colorDiag.sweep")

    CATransaction.flush()
    extensionLog("  [colorDiag] installed sweep on display \(key.displayID) (\(Int(bounds.width))x\(Int(bounds.height)))")
}
