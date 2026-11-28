import AppKit
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import QuartzCore

struct ExternalWallpaperToneMap {
    private struct Configuration: Equatable {
        let mode: HDRMode
        let headroom: Float
    }

    private var configuration: Configuration?

    @MainActor
    static func headroom(for displayID: CGDirectDisplayID?) -> Float? {
        guard let displayID, CGDisplayIsActive(displayID) != 0,
              CGDisplayIsBuiltin(displayID) == 0, CGDisplayIsInMirrorSet(displayID) == 0,
              let screen = NSScreen.screens.first(where: { $0.cgDirectDisplayID == displayID }) else { return nil }

        let current = Float(screen.maximumExtendedDynamicRangeColorComponentValue)
        return current.isFinite && current > 1 ? current : nil
    }

    /// Filter the composited scene once, including spare video and transition layers.
    /// Keep the current filter while the replacement track is being classified.
    @discardableResult
    mutating func apply(to root: CALayer, mode: HDRMode, headroom: Float?, isHDR: Bool?) -> Bool {
        let next: Configuration? = if mode != .automatic, isHDR ?? (configuration != nil),
                                      let headroom, headroom.isFinite, headroom > 1 {
            Configuration(mode: mode, headroom: headroom)
        } else {
            nil
        }
        guard next != configuration else { return false }
        configuration = next

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let next {
            let filter = CIFilter.systemToneMap()
            filter.displayHeadroom = next.headroom
            filter.preferredDynamicRange = switch next.mode {
            case .automatic: nil
            case .standard: .standard
            case .constrainedHigh: .constrainedHigh
            case .high: .high
            }
            root.filters = [filter]
        } else {
            root.filters = nil
        }
        CATransaction.commit()
        CATransaction.flush()
        return true
    }
}
