import Propofol
import SwiftUI

/// Phosphene's palette on top of Propofol's shared tokens — the coral identity. The accent is
/// backed by the AccentColor asset (light + dark variants).
extension Theme {
    /// Foreground for content sitting *on* the saturated coral accent (the scope picker's selected
    /// segment, prominent footer chips). The accent fill stays light in both light and dark mode,
    /// so this is a fixed warm near-black rather than `.primary` (which would flip to white in
    /// dark mode and fail contrast on coral).
    static let onAccent = Color(.sRGB, red: 0.20, green: 0.06, blue: 0.03, opacity: 1)
}
