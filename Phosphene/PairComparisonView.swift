import SwiftUI

/// Detail previews provide a movable divider and local playback controls.
struct PairComparisonView: View {
    let selection: VideoPairSelection
    let swapped: Bool
    @State private var preferredFraction: CGFloat = 0.5
    @State private var playingSources: VideoPairSelection.PreviewSources?
    @Environment(\.appearsActive) private var appearsActive
    @Namespace private var previewSpace

    var body: some View {
        let sources = selection.previewSources
        let isPlaying = playingSources == sources
        GeometryReader { geometry in
            let size = geometry.size
            let fraction = Self.dividerFraction(preferredFraction, width: size.width)
            ZStack {
                VideoPairPreview(selection: selection, swapped: swapped, fraction: fraction, isPlaying: isPlaying) {
                    playingSources = nil
                }
                Image(systemName: "chevron.left.chevron.right")
                    .font(.caption.bold())
                    .frame(width: 28, height: 28)
                    .background(.regularMaterial, in: Circle())
                    .contentShape(.focusEffect, Circle())
                    .focusable()
                    .shadow(radius: 2)
                    .frame(width: 32, height: size.height)
                    .contentShape(Rectangle())
                    .pointerStyle(.columnResize)
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .named(previewSpace))
                            .onChanged { drag in
                                preferredFraction = Self.dividerFraction(drag.location.x / max(size.width, 1), width: size.width)
                            },
                    )
                    .onMoveCommand { direction in
                        if direction == .left {
                            preferredFraction = Self.dividerFraction(fraction - 0.1, width: size.width)
                        }
                        if direction == .right {
                            preferredFraction = Self.dividerFraction(fraction + 0.1, width: size.width)
                        }
                    }
                    .accessibilityLabel("Comparison divider")
                    .accessibilityValue(Text("\(Double(fraction).formatted(.percent.precision(.fractionLength(0)))) light"))
                    .accessibilityAdjustableAction { direction in
                        preferredFraction = Self.dividerFraction(fraction + (direction == .increment ? 0.1 : -0.1), width: size.width)
                    }
                    .help("Drag to compare light and dark")
                    .position(x: size.width * fraction, y: size.height / 2)
            }
            .coordinateSpace(name: previewSpace)
            .environment(\.layoutDirection, .leftToRight)
        }
        .overlay(alignment: .topLeading) {
            Button {
                playingSources = isPlaying ? nil : sources
            } label: {
                Label(isPlaying ? "Stop Pair Preview" : "Play Pair Preview", systemImage: isPlaying ? "stop.fill" : "play.fill")
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .labelStyle(.iconOnly)
            .disabled(sources.first == nil || sources.second == nil)
            .help(isPlaying ? "Stop Pair Preview" : "Play Pair Preview")
            .padding(8)
        }
        .onChange(of: sources) {
            playingSources = nil
            preferredFraction = 0.5
        }
        .onDisappear { playingSources = nil }
        .onChange(of: appearsActive) {
            if !appearsActive {
                playingSources = nil
            }
        }
        .onScrollVisibilityChange(threshold: 0.01) {
            if !$0 {
                playingSources = nil
            }
        }
    }

    static func dividerFraction(_ value: CGFloat, width: CGFloat) -> CGFloat {
        // Keep the handle and its keyboard focus ring inside the preview.
        let inset = min(0.5, 20 / max(1, width))
        return min(1 - inset, max(inset, value))
    }
}
