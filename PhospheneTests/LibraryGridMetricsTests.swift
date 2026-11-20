import CoreGraphics
import Testing

/// The grid's column arithmetic: tiles keep their size, the leftover width goes evenly
/// into the gaps, and the outer columns sit flush with the padding.
struct LibraryGridMetricsTests {
    private let padding = LibraryGridMetrics.padding

    @Test(arguments: [
        (width: 900.0, tile: 180.0),
        (width: 1_000.0, tile: 120.0),
        (width: 777.0, tile: 264.0),
        (width: 1_400.0, tile: 320.0),
    ])
    func `tiles are evenly spaced and flush with the padding`(width: Double, tile: Double) {
        let columns = LibraryGridMetrics.columns(in: width, tileWidth: tile)
        #expect(columns > 1)
        let gap = LibraryGridMetrics.gap(in: width, tileWidth: tile)
        #expect(gap >= LibraryGridMetrics.spacing)
        let origins = (0 ..< columns).map {
            LibraryGridMetrics.tileOrigin(column: $0, columns: columns, width: width, tileWidth: tile)
        }
        #expect(abs(origins[0] - padding) < 0.001)
        #expect(abs(origins[columns - 1] + tile - (width - padding)) < 0.001)
        for (left, right) in zip(origins, origins.dropFirst()) {
            #expect(abs(right - left - tile - gap) < 0.001)
        }
    }

    @Test
    func `a column is added once it fits at the smallest gap`() {
        let tile: CGFloat = 180
        let fitsThree = padding * 2 + tile * 3 + LibraryGridMetrics.spacing * 2
        #expect(LibraryGridMetrics.columns(in: fitsThree, tileWidth: tile) == 3)
        #expect(LibraryGridMetrics.columns(in: fitsThree - 1, tileWidth: tile) == 2)
        #expect(LibraryGridMetrics.gap(in: fitsThree, tileWidth: tile) == LibraryGridMetrics.spacing)
    }

    @Test
    func `a single column sits against the leading padding`() {
        let width: CGFloat = 400
        let tile: CGFloat = 320
        #expect(LibraryGridMetrics.columns(in: width, tileWidth: tile) == 1)
        #expect(LibraryGridMetrics.gap(in: width, tileWidth: tile) == 0)
        #expect(LibraryGridMetrics.tileOrigin(column: 0, columns: 1, width: width, tileWidth: tile) == padding)
    }

    @Test
    func `a grid narrower than one tile still has one column`() {
        #expect(LibraryGridMetrics.columns(in: 100, tileWidth: 320) == 1)
    }
}
