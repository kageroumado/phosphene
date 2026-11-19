import SwiftUI

struct PhospheneSettingsView: View {
    @Bindable var manager: PhospheneManager

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                general
            }
            Tab("Playback", systemImage: "play.rectangle") {
                playback
            }
            Tab("Privacy", systemImage: "hand.raised") {
                Form {
                    UsageCountingSettings()
                }
                .toggleStyle(.switch)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 380)
    }

    private var general: some View {
        @Bindable var prefs = manager.prefsService
        return Form {
            Section {
                Toggle("Launch at Login", isOn: $manager.launchAtLogin)
                Toggle("Install updates automatically", isOn: $manager.autoUpdate)
            }
            Section("Wallpaper Settings") {
                Toggle("Show “Add Video…” when the library is empty", isOn: $prefs.showAddVideoPlaceholder)
                    .toggleStyle(.switch)
            }
        }
    }

    private var playback: some View {
        @Bindable var playback = manager.prefsService
        return Form {
            Section {
                Picker("Playback", selection: $playback.playbackScope) {
                    ForEach(PlaybackScope.allCases, id: \.self) { scope in
                        Text(scope.title).tag(scope)
                    }
                }
                Toggle("Pause When Hidden", isOn: $playback.pauseWhenOccluded)
                    .help("Pause playback on displays fully covered by windows. Fullscreen apps and games always pause their display.")
                Picker("Dynamic Range", selection: $playback.hdrMode) {
                    Text("Automatic").tag(HDRMode.automatic)
                    Text("Standard").tag(HDRMode.standard)
                    Text("Constrained High").tag(HDRMode.constrainedHigh)
                    Text("High").tag(HDRMode.high)
                }
                .help("Choose Constrained High for more subdued desktop highlights.")
            }
            Section {
                Toggle("Blend Matching Frames", isOn: $playback.frameMatchedTransitions)
            } footer: {
                Text("""
                Switching between light and dark briefly decodes both videos and increases GPU and memory use. HDR, \
                high frame rates, and multiple displays can make the transition stutter.
                """)
            }
        }
    }
}

// MARK: - Playback scope

/// The playback scope stored by the wallpaper service as two flags.
private enum PlaybackScope: CaseIterable {
    case everywhere
    case lockScreen
    case paused

    var title: String {
        switch self {
        case .everywhere: String(localized: "Everywhere")
        case .lockScreen: String(localized: "Lock Screen")
        case .paused: String(localized: "Paused")
        }
    }
}

private extension WallpaperPrefsService {
    var playbackScope: PlaybackScope {
        get {
            if userPaused {
                return .paused
            }
            if alwaysPauseDesktop {
                return .lockScreen
            }
            return .everywhere
        }
        set {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                switch newValue {
                case .everywhere:
                    userPaused = false
                    alwaysPauseDesktop = false
                case .lockScreen:
                    alwaysPauseDesktop = true
                    userPaused = false
                case .paused:
                    userPaused = true
                    alwaysPauseDesktop = false
                }
            }
        }
    }
}
