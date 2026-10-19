import CoreGraphics
import Testing

/// A surface's layout against its display, one case per way the two can disagree.
struct GeometryVerdictTests {
    private let display = CGSize(width: 2_560, height: 1_440)

    @Test
    func `matching layout is left alone`() {
        let verdict = GeometryVerdict.decide(laidOutSize: display, laidOutScale: 2, displaySize: display, displayScale: 2)
        #expect(verdict == .matches)
    }

    @Test
    func `pixel size handed as points is reframed`() {
        let verdict = GeometryVerdict.decide(
            laidOutSize: CGSize(width: 5_120, height: 2_880), laidOutScale: 1,
            displaySize: display, displayScale: 2,
        )
        #expect(verdict == .reframe(size: display, scale: 2))
    }

    @Test
    func `quarter points at double scale is reframed`() {
        let verdict = GeometryVerdict.decide(
            laidOutSize: CGSize(width: 1_280, height: 720), laidOutScale: 4,
            displaySize: display, displayScale: 2,
        )
        #expect(verdict == .reframe(size: display, scale: 2))
    }

    @Test
    func `different mode waits for the agent`() {
        let verdict = GeometryVerdict.decide(
            laidOutSize: CGSize(width: 1_920, height: 1_080), laidOutScale: 2,
            displaySize: display, displayScale: 2,
        )
        #expect(verdict == .differentPixels)
    }

    @Test
    func `scale only difference is A different mode`() {
        let verdict = GeometryVerdict.decide(laidOutSize: display, laidOutScale: 1, displaySize: display, displayScale: 2)
        #expect(verdict == .differentPixels)
    }
}
