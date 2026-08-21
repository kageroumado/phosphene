import AVKit
import SwiftUI

struct MenuBarPopoverView: View {
    @Bindable var manager: PhospheneManager
    var openLibrary: () -> Void = {}
    @State private var selectedIndex = 0
    @Namespace private var scopeNamespace

    private var prefsService: WallpaperPrefsService {
        manager.prefsService
    }

    var body: some View {
        VStack(spacing: 10) {
            headerSection

            if prefsService.selections.isEmpty {
                emptyStateSection
            } else {
                heroSection
                playbackScopePicker
            }

            settingsSection
            footerSection
        }
        .padding(14)
        .frame(width: 320)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: prefsService.selections.count) {
            selectedIndex = min(selectedIndex, max(0, prefsService.selections.count - 1))
        }
    }

    // MARK: - Header

    @Environment(\.openURL) private var openURL

    private var headerSection: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Phosphene")
                .font(.system(size: 15, weight: .bold))
            Spacer()
            Button {
                openURL(URL(string: "https://kagerou.glass")!)
            } label: {
                Text("made by kageroumado \(Image(systemName: "arrow.up.right"))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 4)
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
                VideoPreviewCard(videoURL: selection.videoURL, displayID: selection.displayID)
                    .id(selection.id)
            }

            if prefsService.selections.count > 1 {
                carouselArrows
            }
        }
        .overlay(alignment: .bottom) { heroScrim }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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
        if prefsService.pauseWhenOccluded, prefsService.desktopOccluded {
            return "Paused — Desktop Hidden"
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

    private var currentScope: PlaybackScope {
        if prefsService.userPaused { return .paused }
        if prefsService.alwaysPauseDesktop { return .lockScreen }
        return .everywhere
    }

    private func setScope(_ scope: PlaybackScope) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            switch scope {
            case .everywhere:
                prefsService.userPaused = false
                prefsService.alwaysPauseDesktop = false
            case .lockScreen:
                prefsService.alwaysPauseDesktop = true
                prefsService.userPaused = false
            case .paused:
                prefsService.userPaused = true
                prefsService.alwaysPauseDesktop = false
            }
        }
    }

    private var playbackScopePicker: some View {
        HStack(spacing: 0) {
            ForEach(PlaybackScope.allCases, id: \.self) { scope in
                let isSelected = scope == currentScope
                Button {
                    setScope(scope)
                } label: {
                    Text(scope.title)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background {
                            if isSelected {
                                Capsule().fill(Color.accentColor.opacity(0.28))
                                    .matchedGeometryEffect(id: "scope", in: scopeNamespace)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(.quinary, in: Capsule())
    }

    // MARK: - Empty State

    private var emptyStateSection: some View {
        VStack(spacing: 8) {
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
        .background(.quinary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var hasLibraryEntries: Bool {
        !VideoDeploymentService.listEntries().isEmpty
    }

    // MARK: - Settings

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Settings")
                .font(.system(size: 10.5, weight: .semibold))
                .kerning(0.7)
                .textCase(.uppercase)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 4)

            HStack(spacing: 6) {
                Toggle("Launch at Login", isOn: $manager.launchAtLogin)
                Toggle("Pause When Hidden", isOn: Binding(
                    get: { prefsService.pauseWhenOccluded },
                    set: { newValue in
                        prefsService.pauseWhenOccluded = newValue
                        if newValue {
                            manager.occlusionMonitor.startMonitoring()
                        } else {
                            manager.occlusionMonitor.stopMonitoring()
                        }
                    },
                ))
                .help("Pause playback when all screens are covered by windows")
            }
            .toggleStyle(SettingPillToggleStyle())
        }
    }

    // MARK: - Footer

    private var footerSection: some View {
        HStack(spacing: 6) {
            updateChip

            Button {
                openLibrary()
            } label: {
                Label("Library", systemImage: "film.stack")
            }
            .buttonStyle(ChipButtonStyle())

            Spacer(minLength: 0)

            Button {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension")!)
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(RoundIconButtonStyle())
            .help("Open macOS Wallpaper Settings")

            Button {
                WallpaperPrefsService.shared.restartWallpaperAgent()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(RoundIconButtonStyle())
            .help("Force-restart the system WallpaperAgent if the wallpaper is stuck or wrong.")

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(RoundIconButtonStyle())
            .keyboardShortcut("q")
            .help("Quit Phosphene")
        }
    }

    @ViewBuilder
    private var updateChip: some View {
        let updateCheck = manager.updateCheck
        Button {
            if updateCheck.availableVersion != nil {
                NSWorkspace.shared.open(updateCheck.releasesPageURL)
            } else {
                Task { await updateCheck.check(manual: true) }
            }
        } label: {
            if let version = updateCheck.availableVersion {
                Label("\(version) available", systemImage: "arrow.down.circle.fill")
            } else if updateCheck.isChecking {
                Text("Checking…")
            } else if updateCheck.checkedUpToDate {
                Label("Up to date", systemImage: "checkmark")
            } else {
                Text(versionString)
            }
        }
        .buttonStyle(ChipButtonStyle(prominent: updateCheck.availableVersion != nil))
        .disabled(updateCheck.isChecking)
        .help("Check for updates")
    }

    private var versionString: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
        return "v\(version)"
    }
}

// MARK: - Styles

/// A capsule chip: quiet fill, brightens on hover, accent-tinted when prominent.
private struct ChipButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        ChipBody(configuration: configuration, prominent: prominent)
    }

    private struct ChipBody: View {
        let configuration: Configuration
        let prominent: Bool
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .font(.system(size: 11, weight: prominent ? .semibold : .medium))
                .labelStyle(ChipLabelStyle())
                .foregroundStyle(prominent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background {
                    Capsule().fill(
                        prominent
                            ? AnyShapeStyle(Color.accentColor.opacity(isHovered ? 0.26 : 0.16))
                            : AnyShapeStyle(isHovered ? .quaternary : .quinary),
                    )
                }
                .contentShape(Capsule())
                .opacity(configuration.isPressed ? 0.7 : 1)
                .onHover { isHovered = $0 }
        }
    }

    private struct ChipLabelStyle: LabelStyle {
        func makeBody(configuration: Configuration) -> some View {
            HStack(spacing: 4) {
                configuration.icon.font(.system(size: 10, weight: .medium))
                configuration.title
            }
        }
    }
}

/// A circular icon button: quiet fill, brightens on hover.
private struct RoundIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RoundBody(configuration: configuration)
    }

    private struct RoundBody: View {
        let configuration: Configuration
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background {
                    Circle().fill(isHovered ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.quinary))
                }
                .contentShape(Circle())
                .opacity(configuration.isPressed ? 0.7 : 1)
                .onHover { isHovered = $0 }
        }
    }
}

/// A settings toggle as a tappable pill with a miniature switch.
private struct SettingPillToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        PillBody(configuration: configuration)
    }

    private struct PillBody: View {
        let configuration: Configuration
        @State private var isHovered = false

        var body: some View {
            Button {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                    configuration.isOn.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    pip
                    configuration.label
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(configuration.isOn ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                        .fixedSize()
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
                .background {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(
                        configuration.isOn
                            ? AnyShapeStyle(Color.accentColor.opacity(isHovered ? 0.26 : 0.18))
                            : AnyShapeStyle(isHovered ? .quaternary : .quinary),
                    )
                }
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }
        }

        private var pip: some View {
            Capsule()
                .fill(configuration.isOn ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                .frame(width: 20, height: 12)
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle()
                        .fill(.white)
                        .frame(width: 8, height: 8)
                        .padding(2)
                }
        }
    }
}

#Preview {
    MenuBarPopoverView(manager: PhospheneManager())
        .frame(width: 320)
}
