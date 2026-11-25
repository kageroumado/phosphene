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
            Section {
                Toggle("Debug Logging", isOn: Binding(get: { prefs.debugLoggingEnabled }, set: prefs.setDebugLogging))
                    .toggleStyle(.switch)
                    .onAppear { prefs.refreshDebugLogging() }
            } header: {
                Text("Diagnostics")
            } footer: {
                Text("Records playback, appearance transitions, and snapshot details on this Mac. The log can include video filenames.")
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
                DynamicRangePicker(selection: $playback.hdrMode)
            }
            Section {
                HStack {
                    Toggle("Blend Matching Frames", isOn: $playback.frameMatchedTransitions)
                    BlendMatchingFramesInfoButton()
                }
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
