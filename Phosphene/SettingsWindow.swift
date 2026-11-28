import Propofol
import SwiftUI

/// Phosphene's Settings window (⌘, or the popover's gear): startup and pausing, how
/// wallpapers render, and whether this Mac is counted.
struct PhospheneSettingsView: View {
    @Bindable var manager: PhospheneManager

    var body: some View {
        @Bindable var prefs = manager.prefsService
        Form {
            Section {
                Toggle("Launch at Login", isOn: $manager.launchAtLogin)
                Toggle(isOn: $prefs.pauseWhenOccluded) {
                    Text("Pause When Hidden")
                    Text("Pause playback on displays fully covered by windows. Fullscreen apps and games always pause their display.")
                }
            }

            Section {
                Toggle(isOn: $prefs.frameMatchedTransitions) {
                    HStack(spacing: 4) {
                        Text("Blend Matching Frames")
                        BlendMatchingFramesInfoButton()
                    }
                }
                Picker("Dynamic Range", selection: $prefs.hdrMode) {
                    Text("Automatic").tag(HDRMode.automatic)
                    Text("Standard").tag(HDRMode.standard)
                    Text("Constrained High").tag(HDRMode.constrainedHigh)
                    Text("High").tag(HDRMode.high)
                }
            }

            UsageCountingSection()
        }
        .formStyle(.grouped)
        .frame(width: Layout.width)
        .fixedSize(horizontal: false, vertical: true)
    }

    private enum Layout {
        static let width: CGFloat = 460
    }
}

/// The ⓘ beside Blend Matching Frames: when blending helps and what it costs.
struct BlendMatchingFramesInfoButton: View {
    @State private var showsInfo = false

    var body: some View {
        Button("About Blend Matching Frames", systemImage: "info.circle") { showsInfo.toggle() }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("About Blend Matching Frames")
            .popover(isPresented: $showsInfo) {
                VStack(alignment: .leading, spacing: Theme.Space.sm) {
                    Text("Blend Matching Frames").font(.headline)
                    Text("In Everywhere mode, matching frames can smooth the switch between light and dark as the wallpaper plays. You may still see some ghosting.")
                    Text("In Lock Screen and Paused modes, the desktop shows a still frame and usually doesn’t need blending.")
                    Text("Both videos decode briefly at once. GPU and memory use can spike, especially with HDR, high frame rates, or multiple displays.")
                }
                .font(.callout)
                .frame(width: 260, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding()
            }
    }
}
