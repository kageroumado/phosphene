import AppKit

/// Draws the menu bar status icon: the app icon's broken concentric rings
/// around a core dot, as a template image so it adapts to menu bar appearance.
///
/// The radii are chosen so the clear gap between the dot and the inner ring
/// equals the clear gap between the two rings — at 18 pt the eye reads radial
/// spacing, so the rings must be evenly spaced even though the Icon Composer
/// artwork is not.
@MainActor
enum MenuBarIcon {
    static func image(updateBadge: Bool) -> NSImage {
        updateBadge ? badged : plain
    }

    private static let plain = draw(badge: false)
    private static let badged = draw(badge: true)

    private enum Metrics {
        static let canvas: CGFloat = 18
        static let dotRadius: CGFloat = 2.0
        static let innerRadius: CGFloat = 4.5
        static let outerRadius: CGFloat = 7.25
        static let strokeWidth: CGFloat = 1.5
        static let badgeRadius: CGFloat = 2.3
    }

    /// Arc spans in degrees (unflipped coordinates: 0° = right, 90° = top).
    /// The outer ring keeps a gap across the top-right so the update badge
    /// sits in negative space instead of colliding with a stroke.
    private static let innerArcs: [(start: CGFloat, end: CGFloat)] = [
        (20, 150), (200, 330),
    ]
    private static let outerArcs: [(start: CGFloat, end: CGFloat)] = [
        (80, 190), (260, 10),
    ]

    private static func draw(badge: Bool) -> NSImage {
        let size = NSSize(width: Metrics.canvas, height: Metrics.canvas)
        let image = NSImage(size: size, flipped: false) { _ in
            let center = NSPoint(x: Metrics.canvas / 2, y: Metrics.canvas / 2)
            NSColor.black.setFill()
            NSColor.black.setStroke()

            let dot = NSBezierPath(ovalIn: NSRect(
                x: center.x - Metrics.dotRadius,
                y: center.y - Metrics.dotRadius,
                width: Metrics.dotRadius * 2,
                height: Metrics.dotRadius * 2,
            ))
            dot.fill()

            for (radius, arcs) in [(Metrics.innerRadius, innerArcs), (Metrics.outerRadius, outerArcs)] {
                for arc in arcs {
                    let path = NSBezierPath()
                    path.lineWidth = Metrics.strokeWidth
                    path.lineCapStyle = .round
                    path.appendArc(withCenter: center, radius: radius, startAngle: arc.start, endAngle: arc.end)
                    path.stroke()
                }
            }

            if badge {
                let offset = Metrics.outerRadius * 0.7071 // 45°, centered in the outer ring's gap
                let badgePath = NSBezierPath(ovalIn: NSRect(
                    x: center.x + offset - Metrics.badgeRadius,
                    y: center.y + offset - Metrics.badgeRadius,
                    width: Metrics.badgeRadius * 2,
                    height: Metrics.badgeRadius * 2,
                ))
                badgePath.fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
