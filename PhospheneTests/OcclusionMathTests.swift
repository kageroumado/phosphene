import CoreGraphics
import Foundation
import Testing

/// Geometry of the two occlusion tiers, on a synthetic 2560×1440 display with a
/// 24pt menu bar (visible frame starts below it). The window-list filtering
/// (regular apps only, chrome layers out) happens upstream in OcclusionMonitor;
/// these windows are already past it.
@MainActor
struct OcclusionMathTests {
    private let full = CGRect(x: 0, y: 0, width: 2_560, height: 1_440)
    private let visible = CGRect(x: 0, y: 24, width: 2_560, height: 1_416)

    private func window(_ rect: CGRect, layer: Int = 0) -> OcclusionMath.Window {
        OcclusionMath.Window(rect: rect, layer: layer)
    }

    // MARK: - Fullscreen-app tier

    @Test
    func `native fullscreen window owns the display`() {
        #expect(OcclusionMath.hasFullscreenApp(full: full, visible: visible, windows: [window(full)]))
    }

    /// A maximized ordinary window fills the visible frame but not the menu bar
    /// region — that's the occlusion tier's business, never the fullscreen tier's.
    @Test
    func `maximized layer zero window does not own the display`() {
        #expect(!OcclusionMath.hasFullscreenApp(full: full, visible: visible, windows: [window(visible)]))
    }

    /// Wine parks borderless games just above the menu bar (Genshin: layer 26);
    /// at an elevated layer, covering the visible frame is enough.
    @Test
    func `elevated borderless game owns the display`() {
        #expect(OcclusionMath.hasFullscreenApp(full: full, visible: visible, windows: [window(visible, layer: 26)]))
    }

    @Test
    func `elevated window below threshold does not own the display`() {
        let ninetyPercent = CGRect(x: 0, y: 24, width: 2_560 * 0.9, height: 1_416)
        #expect(!OcclusionMath.hasFullscreenApp(full: full, visible: visible, windows: [window(ninetyPercent, layer: 26)]))
    }

    /// Ownership means ONE window covering the display — two half-screen windows
    /// never make a fullscreen app, whatever they add up to.
    @Test
    func `two halves do not own the display`() {
        let left = CGRect(x: 0, y: 0, width: 1_280, height: 1_440)
        let right = CGRect(x: 1_280, y: 0, width: 1_280, height: 1_440)
        #expect(!OcclusionMath.hasFullscreenApp(full: full, visible: visible, windows: [window(left, layer: 26), window(right, layer: 26)]))
    }

    @Test
    func `no windows no owner`() {
        #expect(!OcclusionMath.hasFullscreenApp(full: full, visible: visible, windows: []))
    }

    // MARK: - Occlusion tier (union coverage)

    @Test
    func `full cover occludes`() {
        #expect(OcclusionMath.isOccluded(visible, by: [window(full)]))
    }

    @Test
    func `ninety percent does not occlude`() {
        let ninety = CGRect(x: 0, y: 24, width: 2_560 * 0.9, height: 1_416)
        #expect(!OcclusionMath.isOccluded(visible, by: [window(ninety)]))
    }

    @Test
    func `adjacent windows union to occlude`() {
        let left = CGRect(x: 0, y: 0, width: 1_300, height: 1_440)
        let right = CGRect(x: 1_290, y: 0, width: 1_280, height: 1_440)
        #expect(OcclusionMath.isOccluded(visible, by: [window(left), window(right)]))
    }

    /// The grid is a union: two copies of the same half-screen window cover half,
    /// not the sum of their areas.
    @Test
    func `overlapping windows are not double counted`() {
        let half = CGRect(x: 0, y: 0, width: 1_280, height: 1_440)
        #expect(!OcclusionMath.isOccluded(visible, by: [window(half), window(half), window(half)]))
    }

    @Test
    func `window larger than the screen clips and occludes`() {
        let vast = CGRect(x: -500, y: -500, width: 4_000, height: 3_000)
        #expect(OcclusionMath.isOccluded(visible, by: [window(vast)]))
    }

    @Test
    func `empty screen rect does not occlude`() {
        #expect(!OcclusionMath.isOccluded(.zero, by: [window(full)]))
    }
}
