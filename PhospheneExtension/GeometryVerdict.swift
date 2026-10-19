import CoreGraphics

/// A surface's layout (points and backing scale) against what its display reports.
/// Pure, compiled into the test target.
nonisolated enum GeometryVerdict: Equatable {
    /// Points and scale match the display.
    case matches
    /// The same pixels split differently into points and scale. The layout is corrected
    /// in place: the hosting layer covers the same pixels either way.
    case reframe(size: CGSize, scale: CGFloat)
    /// A different pixel count: the display changed mode or was swapped, and the agent
    /// re-acquires with the new destination (issue #21), so the layout is left alone.
    case differentPixels

    static func decide(
        laidOutSize: CGSize,
        laidOutScale: CGFloat,
        displaySize: CGSize,
        displayScale: CGFloat,
    ) -> GeometryVerdict {
        if laidOutSize == displaySize, laidOutScale == displayScale {
            return .matches
        }
        let laidOutPixels = CGSize(width: laidOutSize.width * laidOutScale, height: laidOutSize.height * laidOutScale)
        let displayPixels = CGSize(width: displaySize.width * displayScale, height: displaySize.height * displayScale)
        guard samePixels(laidOutPixels, displayPixels) else {
            return .differentPixels
        }
        return .reframe(size: displaySize, scale: displayScale)
    }

    /// Pixel counts are products of points and a scale, so compare to the pixel.
    private static func samePixels(_ a: CGSize, _ b: CGSize) -> Bool {
        abs(a.width - b.width) < 1 && abs(a.height - b.height) < 1
    }
}
