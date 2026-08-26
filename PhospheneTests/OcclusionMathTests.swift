import CoreGraphics
import Foundation
import Testing

/// Geometry of the two occlusion tiers, on a synthetic 2560×1440 display with a
/// 24pt menu bar (visible frame starts below it). The window-list filtering
/// (regular apps only, chrome layers out) happens upstream in OcclusionMonitor;
/// these windows are already past it.
@MainActor
struct OcclusionMathTests {
    private let full = CGRect(x: 0, y: 0, width: 2560, height: 1440)
    private let visible = CGRect(x: 0, y: 24, width: 2560, height: 1416)

    private func window(_ rect: CGRect, layer: Int = 0) -> OcclusionMath.Window {
        OcclusionMath.Window(rect: rect, layer: layer)
    }

    // MARK: - Fullscreen-app tier

    @Test func nativeFullscreenWindowOwnsTheDisplay() {
        #expect(OcclusionMath.hasFullscreenApp(full: full, visible: visible, windows: [window(full)]))
    }

    /// A maximized ordinary window fills the visible frame but not the menu bar
    /// region — that's the occlusion tier's business, never the fullscreen tier's.
    @Test func maximizedLayerZeroWindowDoesNotOwnTheDisplay() {
        #expect(!OcclusionMath.hasFullscreenApp(full: full, visible: visible, windows: [window(visible)]))
    }

    /// Wine parks borderless games just above the menu bar (Genshin: layer 26);
    /// at an elevated layer, covering the visible frame is enough.
    @Test func elevatedBorderlessGameOwnsTheDisplay() {
        #expect(OcclusionMath.hasFullscreenApp(full: full, visible: visible, windows: [window(visible, layer: 26)]))
    }

    @Test func elevatedWindowBelowThresholdDoesNotOwnTheDisplay() {
        let ninetyPercent = CGRect(x: 0, y: 24, width: 2560 * 0.9, height: 1416)
        #expect(!OcclusionMath.hasFullscreenApp(full: full, visible: visible, windows: [window(ninetyPercent, layer: 26)]))
    }

    /// Ownership means ONE window covering the display — two half-screen windows
    /// never make a fullscreen app, whatever they add up to.
    @Test func twoHalvesDoNotOwnTheDisplay() {
        let left = CGRect(x: 0, y: 0, width: 1280, height: 1440)
        let right = CGRect(x: 1280, y: 0, width: 1280, height: 1440)
        #expect(!OcclusionMath.hasFullscreenApp(full: full, visible: visible, windows: [window(left, layer: 26), window(right, layer: 26)]))
    }

    @Test func noWindowsNoOwner() {
        #expect(!OcclusionMath.hasFullscreenApp(full: full, visible: visible, windows: []))
    }

    // MARK: - Occlusion tier (union coverage)

    @Test func fullCoverOccludes() {
        #expect(OcclusionMath.isOccluded(visible, by: [window(full)]))
    }

    @Test func ninetyPercentDoesNotOcclude() {
        let ninety = CGRect(x: 0, y: 24, width: 2560 * 0.9, height: 1416)
        #expect(!OcclusionMath.isOccluded(visible, by: [window(ninety)]))
    }

    @Test func adjacentWindowsUnionToOcclude() {
        let left = CGRect(x: 0, y: 0, width: 1300, height: 1440)
        let right = CGRect(x: 1290, y: 0, width: 1280, height: 1440)
        #expect(OcclusionMath.isOccluded(visible, by: [window(left), window(right)]))
    }

    /// The grid is a union: two copies of the same half-screen window cover half,
    /// not the sum of their areas.
    @Test func overlappingWindowsAreNotDoubleCounted() {
        let half = CGRect(x: 0, y: 0, width: 1280, height: 1440)
        #expect(!OcclusionMath.isOccluded(visible, by: [window(half), window(half), window(half)]))
    }

    @Test func windowLargerThanTheScreenClipsAndOccludes() {
        let vast = CGRect(x: -500, y: -500, width: 4000, height: 3000)
        #expect(OcclusionMath.isOccluded(visible, by: [window(vast)]))
    }

    @Test func emptyScreenRectDoesNotOcclude() {
        #expect(!OcclusionMath.isOccluded(.zero, by: [window(full)]))
    }
}
