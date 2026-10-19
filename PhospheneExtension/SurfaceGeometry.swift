import CoreGraphics
import Foundation
import QuartzCore

/// What CoreGraphics reports for a display: its size in points and its backing scale.
nonisolated struct DisplayGeometry: Equatable {
    let size: CGSize
    let scale: CGFloat

    /// Nil while the display is absent or still configuring (zero bounds).
    init?(displayID: UInt32) {
        let bounds = CGDisplayBounds(displayID)
        let pixelsWide = CGDisplayPixelsWide(displayID)
        guard bounds.width > 0, bounds.height > 0, pixelsWide > 0 else { return nil }
        size = bounds.size
        scale = CGFloat(pixelsWide) / bounds.width
    }
}

/// Lay out a surface's root and video layers for a destination, inside one
/// action-free flushed transaction, like the acquire path's own layer mutations.
func layOutSurface(_ surface: HostedSurface, destSize: CGSize, scaleFactor: CGFloat) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    surface.rootLayer.frame = CGRect(origin: .zero, size: destSize)
    surface.rootLayer.contentsScale = scaleFactor
    CATransaction.commit()
    CATransaction.flush()
    surface.renderer?.resize(to: destSize, scale: scaleFactor)
}

/// Re-frame a live desktop surface whose layout disagrees with its display about points
/// and scale while covering the same pixels. The agent computes a destination from the
/// display state it sees at acquire, and at login that state can still be settling; it
/// never re-sends a destination for a surface it keeps hosting, so a layout taken from
/// an unsettled state stays until something else re-acquires. Returns true when it
/// re-framed. Previews are skipped: Settings re-acquires them on every change.
@discardableResult
func reconcileSurfaceGeometry(for key: SurfaceKey, because reason: String) -> Bool {
    let registry = SurfaceRegistry.shared
    guard let surface = registry.surface(for: key), !surface.isPreview,
          let displayID = surface.displayID,
          let display = DisplayGeometry(displayID: displayID)
    else { return false }
    let laidOut = "\(surface.destSize) @\(surface.scaleFactor)x"
    let verdict = GeometryVerdict.decide(
        laidOutSize: surface.destSize, laidOutScale: surface.scaleFactor,
        displaySize: display.size, displayScale: display.scale,
    )
    switch verdict {
    case .matches:
        return false
    case .differentPixels:
        extensionLog("  [geometry] \(reason): \(key) laid out at \(laidOut), display \(displayID) is \(display.size) @\(display.scale)x — different pixel count, left for the agent to re-acquire")
        return false
    case let .reframe(size, scale):
        guard let resized = registry.updateGeometryIfChanged(destSize: size, scaleFactor: scale, for: key) else { return false }
        layOutSurface(resized, destSize: size, scaleFactor: scale)
        extensionLog("  [geometry] \(reason): \(key) laid out at \(laidOut), display \(displayID) is \(size) @\(scale)x — re-framed")
        return true
    }
}

/// Re-checks every live surface against its display once a reconfiguration has settled.
/// The callback fires once per display per phase and a login-time reconfiguration comes
/// in bursts, so the pass runs on `Lifecycle.queue` a second after the last one.
enum DisplayReconfiguration {
    private static let settleDelay: TimeInterval = 1.0
    /// The pass waiting for the burst to end. Touched only on `Lifecycle.queue`.
    private nonisolated(unsafe) static var pendingPass: DispatchWorkItem?

    static func start() {
        let callback: CGDisplayReconfigurationCallBack = { displayID, flags, _ in
            if flags.contains(.beginConfigurationFlag) {
                return
            }
            DisplayReconfiguration.schedule(displayID: displayID, flags: flags)
        }
        let error = CGDisplayRegisterReconfigurationCallback(callback, nil)
        if error != .success {
            extensionLog("[Geometry] CGDisplayRegisterReconfigurationCallback failed: \(error.rawValue)")
        }
    }

    private static func schedule(displayID: CGDirectDisplayID, flags: CGDisplayChangeSummaryFlags) {
        traceLog("  [geometry] display \(displayID) reconfigured (flags 0x\(String(flags.rawValue, radix: 16)))")
        let pass = DispatchWorkItem {
            for key in SurfaceRegistry.shared.surfaceKeys {
                reconcileSurfaceGeometry(for: key, because: "display reconfigured")
            }
        }
        Lifecycle.queue.async {
            pendingPass?.cancel()
            pendingPass = pass
            Lifecycle.queue.asyncAfter(deadline: .now() + settleDelay, execute: pass)
        }
    }
}
