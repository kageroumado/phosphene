import SwiftUI

/// The glass play/pause button floating over a video preview.
///
/// Always resident in the hierarchy — visibility is opacity-only, so state flips (scope
/// changes, hover) cross-fade instead of removing and reinserting the button, which drops a
/// frame and restarts the transition from nothing.
struct PlayOverlayButton: View {
    /// Shows the play glyph when true, the pause glyph otherwise.
    var isPaused: Bool
    var isVisible: Bool
    var diameter: CGFloat
    var action: () -> Void

    private enum Layout {
        static let glyphScale: CGFloat = 0.36
        static let hiddenScale: CGFloat = 0.8
    }

    var body: some View {
        Button(action: action) {
            // A glass view is composited outside its ancestors' layers, glyph included, so the
            // button's `opacity` leaves both on screen: the hidden state fades the glyph itself
            // and swaps the glass for `.identity`.
            Image(systemName: isPaused ? "play.fill" : "pause.fill")
                .font(.system(size: diameter * Layout.glyphScale, weight: .medium))
                .contentTransition(.symbolEffect(.replace))
                .opacity(isVisible ? 1 : 0)
                .frame(width: diameter, height: diameter)
                .contentShape(Circle())
                .glassEffect(isVisible ? .clear.interactive() : .identity, in: Circle())
        }
        .buttonStyle(.plain)
        .scaleEffect(isVisible ? 1 : Layout.hiddenScale)
        .allowsHitTesting(isVisible)
        .animation(.spring(response: 0.5, dampingFraction: 0.7), value: isVisible)
        .animation(.default, value: isPaused)
        .accessibilityLabel(isPaused ? "Play" : "Pause")
    }
}
