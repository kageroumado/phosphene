import AVKit
import Propofol
import SwiftUI

struct MenuBarPopoverView: View {
    @Bindable var manager: PhospheneManager
    var openLibrary: () -> Void = {}
    @State private var selectedIndex = 0
    @State private var isHoveringVersion = false

    private var prefsService: WallpaperPrefsService {
        manager.prefsService
    }

    var body: some View {
        GlassEffectContainer(spacing: Theme.Space.md) {
            VStack(spacing: Theme.Space.md) {
                PopoverHeader("Phosphene")

                if prefsService.selections.isEmpty {
                    emptyStateSection
                } else {
                    heroSection
                    playbackScopePicker
                }

                settingsSection
                footerSection
            }
            .padding(Theme.Space.lg)
        }
        .frame(width: Theme.popoverWidth)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { SilentUpdates.shared.refreshPending() }
        .onChange(of: prefsService.selections.count) {
            selectedIndex = min(selectedIndex, max(0, prefsService.selections.count - 1))
        }
    }

    // MARK: - Hero

    private var currentSelection: WallpaperPrefsService.WallpaperSelection? {
        guard !prefsService.selections.isEmpty else { return nil }
        let index = min(selectedIndex, prefsService.selections.count - 1)
        return prefsService.selections[index]
    }

    private var heroSection: some View {
        ZStack {
            if let selection = currentSelection {
                VideoPreviewCard(
                    videoID: selection.videoID,
                    videoURL: selection.videoURL,
                    displayID: selection.displayID,
                )
                    .id(selection.id)
            }

            if prefsService.selections.count > 1 {
                carouselArrows
            }
        }
        .overlay(alignment: .bottom) { heroScrim }
        .clipShape(Theme.cardShape)
    }

    @ViewBuilder
    private var heroScrim: some View {
        if let selection = currentSelection {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 1) {
                    if let name = selection.videoName {
                        Text(name)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Text(scrimSubtitle(for: selection))
                        .font(.system(size: 11))
                        .foregroundStyle(Color(white: 1, opacity: 0.72))
                        .lineLimit(1)
                }
                Spacer()
                if prefsService.selections.count > 1 {
                    pageDots
                }
            }
            .padding(10)
            .padding(.top, 26)
            .background {
                LinearGradient(
                    colors: [.clear, Color(white: 0, opacity: 0.72)],
                    startPoint: .top,
                    endPoint: .bottom,
                )
            }
        }
    }

    private func scrimSubtitle(for selection: WallpaperPrefsService.WallpaperSelection) -> String {
        var parts: [String] = []
        if prefsService.selections.count > 1 {
            parts.append(selection.displayName)
            if let spaceName = selection.spaceName {
                parts.append(spaceName)
            }
        }
        parts.append(playbackStatusText(for: selection))
        return parts.joined(separator: " · ")
    }

    private func playbackStatusText(for selection: WallpaperPrefsService.WallpaperSelection) -> String {
        if prefsService.alwaysPauseDesktop {
            return "Playing on Lock Screen"
        }
        if prefsService.fullscreenDisplays.contains(selection.displayID) {
            return "Paused — Fullscreen App"
        }
        if prefsService.pauseWhenOccluded,
           prefsService.desktopOccluded || prefsService.occludedDisplays.contains(selection.displayID) {
            return "Paused — Display Covered"
        }
        if prefsService.pausedDisplays.contains(selection.displayID) {
            return "Paused"
        }
        if prefsService.userPaused {
            return "Paused"
        }
        return "Playing"
    }

    private var carouselArrows: some View {
        HStack {
            carouselArrow(systemName: "chevron.left", step: -1)
            Spacer()
            carouselArrow(systemName: "chevron.right", step: 1)
        }
        .padding(.horizontal, 8)
    }

    private func carouselArrow(systemName: String, step: Int) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                let count = prefsService.selections.count
                selectedIndex = (selectedIndex + step + count) % count
            }
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 28, height: 28)
                .contentShape(Circle())
                .glassEffect(.clear)
        }
        .buttonStyle(.plain)
    }

    private var pageDots: some View {
        HStack(spacing: 4) {
            ForEach(0 ..< prefsService.selections.count, id: \.self) { index in
                Circle()
                    .fill(Color(white: 1, opacity: index == selectedIndex ? 1 : 0.35))
                    .frame(width: 5, height: 5)
            }
        }
        .padding(.bottom, 4)
    }

    // MARK: - Playback Scope

    private var playbackScopePicker: some View {
        @Bindable var prefsService = prefsService
        return PillPicker(
            title: "Playback",
            options: PlaybackScope.allCases.map { ($0, $0.title) },
            selection: $prefsService.playbackScope,
            height: 32,
            onTint: Theme.onAccent,
        )
    }

    // MARK: - Empty State

    private var emptyStateSection: some View {
        VStack(spacing: Theme.Space.sm) {
            Image(systemName: "film.stack")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.quaternary)

            if hasLibraryEntries {
                Text("Select a wallpaper in\nWallpaper Settings")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                Text("Add a video to your Library\nto get started")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Button("Open Library") {
                    openLibrary()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .glassCard()
    }

    private var hasLibraryEntries: Bool {
        !VideoDeploymentService.listEntries().isEmpty
    }

    // MARK: - Settings

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            SectionLabel("Settings")

            HStack(spacing: Theme.Space.sm) {
                @Bindable var prefsService = prefsService
                Toggle("Launch at Login", isOn: $manager.launchAtLogin)
                Toggle("Pause When Hidden", isOn: $prefsService.pauseWhenOccluded)
                    .help("Pause playback on displays fully covered by windows. Fullscreen apps and games always pause their display.")
            }
            .toggleStyle(SettingPillToggleStyle())
        }
    }

    // MARK: - Footer

    private var footerSection: some View {
        HStack(spacing: Theme.Space.sm) {
            switch SilentUpdates.shared.manualPhase {
            case .working:
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Updating…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .failed(let message):
                Button {
                    NSWorkspace.shared.open(manager.updateCheck.releasesPageURL)
                    SilentUpdates.shared.dismissFailure()
                } label: {
                    Label("Update failed", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.onAccent)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.small)
                .help(message)
            case .idle:
                updateChip

                FooterChip(text: "Library", systemImage: "film.stack") {
                    openLibrary()
                }

                FooterChip(text: "Choose", systemImage: "photo.on.rectangle") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension")!)
                }
                .help("Choose the wallpaper in macOS Wallpaper Settings")
            }

            Spacer(minLength: 0)

            HStack(spacing: Theme.Space.sm) {
                Button {
                    WallpaperPrefsService.shared.restartWallpaperAgent()
                } label: {
                    utilityIcon("arrow.clockwise")
                }
                .help("Force-restart the system WallpaperAgent if the wallpaper is stuck or wrong.")

                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    utilityIcon("xmark")
                }
                .keyboardShortcut("q")
                .help("Quit Phosphene")
            }
            .buttonStyle(.glass)
            .controlSize(.large)
        }
    }

    /// A glyph for the bottom-bar utility buttons, pinned to a fixed square so both `.glass`
    /// capsules come out the same size regardless of glyph proportions.
    private func utilityIcon(_ name: String) -> some View {
        Image(systemName: name)
            .frame(width: 16, height: 16)
    }

    /// The version chip is the whole update UI: it announces an update (click installs),
    /// confirms one just landed (click acknowledges), and at rest flips into the
    /// Auto-Update switch on hover so the setting costs no footer space.
    @ViewBuilder
    private var updateChip: some View {
        let updates = SilentUpdates.shared
        if let justUpdated = updates.justUpdatedVersion {
            Button {
                WhatsNewWindow.present(version: justUpdated, context: .justUpdated)
                updates.acknowledgeUpdate()
            } label: {
                Label("v\(justUpdated)", systemImage: "checkmark")
                    .font(.caption)
                    .foregroundStyle(Theme.onAccent)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.small)
            .help("Updated to version \(justUpdated) — see what changed")
        } else if let available = manager.updateCheck.availableVersion ?? updates.pendingVersion {
            Button {
                WhatsNewWindow.present(
                    version: available,
                    context: .updateAvailable(autoInstall: manager.autoUpdate),
                )
            } label: {
                Label(available, systemImage: "arrow.down.circle.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.onAccent)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.small)
            .help("See what's new in version \(available)")
        } else {
            Button {
                manager.autoUpdate.toggle()
            } label: {
                Group {
                    if isHoveringVersion {
                        HStack(spacing: 5) {
                            MiniSwitchPip(isOn: manager.autoUpdate)
                            Text("Auto")
                        }
                    } else {
                        Text(versionString)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            .onHover { isHoveringVersion = $0 }
            .help("Install updates automatically")
        }
    }

    private var versionString: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
        return "v\(version)"
    }
}

// MARK: - Playback scope

/// The tri-state the popover's scope picker edits, projected over the two underlying flags.
private enum PlaybackScope: CaseIterable {
    case everywhere, lockScreen, paused

    var title: String {
        switch self {
        case .everywhere: "Everywhere"
        case .lockScreen: "Lock Screen"
        case .paused: "Paused"
        }
    }
}

extension WallpaperPrefsService {
    fileprivate var playbackScope: PlaybackScope {
        get {
            if userPaused { return .paused }
            if alwaysPauseDesktop { return .lockScreen }
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

// MARK: - Styles

/// The miniature switch drawn inside chips and setting pills.
private struct MiniSwitchPip: View {
    var isOn: Bool

    var body: some View {
        Capsule()
            .fill(isOn ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
            .frame(width: 18, height: 11)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle()
                    .fill(.white)
                    .frame(width: 7, height: 7)
                    .padding(2)
            }
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isOn)
    }
}

/// A settings toggle as a tappable glass pill with a miniature switch — accent-tinted glass
/// when on, plain glass when off.
private struct SettingPillToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                configuration.isOn.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                MiniSwitchPip(isOn: configuration.isOn)
                configuration.label
                    .font(.caption)
                    .foregroundStyle(configuration.isOn ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .fixedSize()
                Spacer(minLength: 0)
            }
            .padding(Theme.Space.sm)
            .contentShape(Theme.innerShape)
        }
        .buttonStyle(.plain)
        .glassEffect(
            configuration.isOn ? .regular.tint(Color.accentColor.opacity(0.35)) : .regular,
            in: Theme.innerShape,
        )
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
    }
}

#Preview {
    MenuBarPopoverView(manager: PhospheneManager())
}
