import CoreGraphics

/// The grid's metrics and the arithmetic that follows from them.
///
/// Tiles keep the icon size. The grid fits as many columns as the width holds at
/// ``spacing`` apart, then spreads the width left over evenly across the gaps between
/// columns, so the first and last columns sit flush with the padding, as in Finder's
/// icon view. The grid divides its width into equal cells and places each tile in its
/// cell at ``placement(ofColumn:columns:)``, which lands every tile where
/// ``tileOrigin(column:columns:width:tileWidth:)`` says.
nonisolated enum LibraryGridMetrics {
    /// The smallest gap between columns.
    static let spacing: CGFloat = 20
    static let rowSpacing: CGFloat = 20
    static let padding: CGFloat = 20

    /// How many tiles of `tileWidth` fit across `width`, at least ``spacing`` apart.
    static func columns(in width: CGFloat, tileWidth: CGFloat) -> Int {
        let usable = width - padding * 2
        return max(1, Int((usable + spacing) / (tileWidth + spacing)))
    }

    /// The gap between neighboring columns once the leftover width is spread across the
    /// gaps; zero for a single column.
    static func gap(in width: CGFloat, tileWidth: CGFloat) -> CGFloat {
        let count = columns(in: width, tileWidth: tileWidth)
        guard count > 1 else { return 0 }
        return (width - padding * 2 - CGFloat(count) * tileWidth) / CGFloat(count - 1)
    }

    /// Where a tile sits in its cell, from 0 (against the cell's leading edge) to 1
    /// (against its trailing edge).
    static func placement(ofColumn column: Int, columns: Int) -> CGFloat {
        columns > 1 ? CGFloat(column) / CGFloat(columns - 1) : 0
    }

    /// The leading edge of a tile in `column`, measured from the grid's leading edge, when
    /// the width between the paddings is divided into equal cells.
    static func tileOrigin(column: Int, columns: Int, width: CGFloat, tileWidth: CGFloat) -> CGFloat {
        let cell = (width - padding * 2) / CGFloat(columns)
        let room = cell - tileWidth
        return padding + CGFloat(column) * cell + room * placement(ofColumn: column, columns: columns)
    }
}
