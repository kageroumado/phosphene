import AppKit
import SwiftUI

/// The library status bar's help button: how System Settings puts a Phosphene video
/// on every display, on one display, or on one desktop (Space). Phosphene fills the
/// library; System Settings decides which video plays where.
struct WallpaperPlacementHelpButton: View {
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: "questionmark.circle")
        }
        .buttonStyle(.plain)
        .help("Using a video on each display and desktop")
        .accessibilityLabel("Using a video on each display and desktop")
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            WallpaperPlacementHelp()
        }
    }
}

struct WallpaperPlacementHelp: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Where Each Video Plays")
                    .font(.headline)
                Text("Phosphene adds videos to your library. System Settings › Wallpaper chooses which one plays on each display and desktop.")
                    .foregroundStyle(.secondary)
            }
            PlacementStep(
                symbol: "display.2",
                title: "Every display",
                detail: "Turn on “Show on all Spaces”, then choose the video. Displays without a wallpaper of their own show it too, including ones you connect later.",
            )
            PlacementStep(
                symbol: "display",
                title: "One display",
                detail: "Turn off “Show on all Spaces”, move the System Settings window onto that display, then choose the video.",
            )
            PlacementStep(
                symbol: "rectangle.3.group",
                title: "One desktop",
                detail: "With “Show on all Spaces” off, switch to that desktop, then choose the video.",
            )
            Button("Open Wallpaper Settings") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension")!)
            }
        }
        .font(.callout)
        .foregroundStyle(.primary)
        .padding(16)
        .frame(width: 320, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct PlacementStep: View {
    let symbol: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(.tint)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .fontWeight(.semibold)
                Text(detail)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
