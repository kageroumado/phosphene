import AVKit
import SwiftUI

struct MenuBarPopoverView: View {
    @Bindable var manager: PhospheneManager
    var openLibrary: () -> Void = {}
    @State private var showingOptions = false
    @State private var selectedIndex = 0

    private var prefsService: WallpaperPrefsService { manager.prefsService }

    var body: some View {
        VStack(spacing: 0) {
            if prefsService.selections.count > 1 {
                carouselSection
                Divider()
                videoInfoSection
            } else if let selection = prefsService.selections.first {
                VideoPreviewCard(videoURL: selection.videoURL, displayID: selection.displayID)
                Divider()
                videoInfoSection
            } else {
                emptyStateSection
            }
            Divider()
            actionsSection
            Divider()
            optionsDisclosure
            aboutLine
        }
        .frame(width: 320)
        .fixedSize(horizontal: false, vertical: true)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onChange(of: prefsService.selections.count) {
            selectedIndex = min(selectedIndex, max(0, prefsService.selections.count - 1))
        }
    }

    // MARK: - Carousel

    private var currentSelection: WallpaperPrefsService.WallpaperSelection? {
        guard !prefsService.selections.isEmpty else { return nil }
        let index = min(selectedIndex, prefsService.selections.count - 1)
        return prefsService.selections[index]
    }

    private var carouselSection: some View {
        ZStack {
            if let selection = currentSelection {
                VideoPreviewCard(videoURL: selection.videoURL, displayID: selection.displayID)
                    .id(selection.id)
            }

            // Navigation arrows
            HStack {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        selectedIndex = (selectedIndex - 1 + prefsService.selections.count) % prefsService.selections.count
                    }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .contentShape(Circle())
                        .glassEffect(.clear)
                }
                .buttonStyle(.plain)

                Spacer()

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        selectedIndex = (selectedIndex + 1) % prefsService.selections.count
                    }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .contentShape(Circle())
                        .glassEffect(.clear)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 8)
        }
    }

    // MARK: - Page Dots

    private var pageDots: some View {
        HStack(spacing: 6) {
            ForEach(0..<prefsService.selections.count, id: \.self) { index in
                Circle()
                    .fill(index == selectedIndex ? Color.primary : Color.primary.opacity(0.3))
                    .frame(width: 6, height: 6)
            }
        }
    }

    // MARK: - Video Info

    private var videoInfoSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let selection = prefsService.selections.count > 1 ? currentSelection : prefsService.selections.first {
                if let name = selection.videoName {
                    Text(name)
                        .font(.system(size: 13))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                HStack(spacing: 4) {
                    if prefsService.selections.count > 1 {
                        Text(selection.displayName)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                        if let spaceName = selection.spaceName {
                            Text("·")
                                .font(.system(size: 11))
                                .foregroundStyle(.quaternary)
                            Text(spaceName)
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        }
                        Text("·")
                            .font(.system(size: 11))
                            .foregroundStyle(.quaternary)
                    }
                    Text(playbackStatusText(for: selection))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                if prefsService.selections.count > 1 {
                    pageDots
                        .frame(maxWidth: .infinity)
                        .padding(.top, 4)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func playbackStatusText(for selection: WallpaperPrefsService.WallpaperSelection) -> String {
        if prefsService.alwaysPauseDesktop {
            return "Paused — Only on Lock Screen"
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
        .padding(.horizontal, 14)
        .padding(.vertical, 20)
    }

    private var hasLibraryEntries: Bool {
        !VideoDeploymentService.listEntries().isEmpty
    }

    // MARK: - Actions

    private var actionsSection: some View {
        VStack(spacing: 0) {
            Button {
                openLibrary()
            } label: {
                HStack {
                    Text("Manage Library")
                        .font(.system(size: 13))
                    Spacer()
                    Image(systemName: "film.stack")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .buttonStyle(PopoverMenuItemStyle())
            .padding(4)

            Button {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension")!)
            } label: {
                HStack {
                    Text("Wallpaper Settings")
                        .font(.system(size: 13))
                    Spacer()
                    Image(systemName: "gear")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .buttonStyle(PopoverMenuItemStyle())
            .padding(4)

            Button {
                if manager.updateCheck.availableVersion != nil {
                    NSWorkspace.shared.open(manager.updateCheck.releasesPageURL)
                } else {
                    Task { await manager.updateCheck.check(manual: true) }
                }
            } label: {
                HStack {
                    Text(updateRowTitle)
                        .font(.system(size: 13,
                                      weight: manager.updateCheck.availableVersion != nil ? .medium : .regular))
                        .foregroundStyle(manager.updateCheck.availableVersion != nil ? Color.accentColor : Color.primary)
                    Spacer()
                    updateRowIcon
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .buttonStyle(PopoverMenuItemStyle())
            .disabled(manager.updateCheck.isChecking)
            .padding(4)
        }
    }

    private var updateRowTitle: String {
        let uc = manager.updateCheck
        if let version = uc.availableVersion { return "Update available — version \(version)" }
        if uc.isChecking { return "Checking for Updates…" }
        if uc.checkedUpToDate { return "You're up to date" }
        return "Check for Updates"
    }

    @ViewBuilder private var updateRowIcon: some View {
        if manager.updateCheck.isChecking {
            ProgressView().controlSize(.small)
        } else if manager.updateCheck.availableVersion != nil {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.tint)
        } else {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Options Disclosure

    private var optionsDisclosure: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showingOptions.toggle()
                }
            } label: {
                HStack {
                    Text("Options")
                        .font(.system(size: 13))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(showingOptions ? 90 : 0))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showingOptions {
                Divider()

                VStack(spacing: 8) {
                    toggle("Resume on Launch", isOn: $manager.resumeLastWallpaper)
                    toggle("Only on Lock Screen", isOn: Bindable(prefsService).alwaysPauseDesktop)
                    toggle("Pause When Hidden", isOn: Binding(
                        get: { prefsService.pauseWhenOccluded },
                        set: { newValue in
                            prefsService.pauseWhenOccluded = newValue
                            if newValue {
                                manager.occlusionMonitor.startMonitoring()
                            } else {
                                manager.occlusionMonitor.stopMonitoring()
                            }
                        }
                    ))
                    .help("Pause playback when all screens are covered by windows")
                    toggle("Launch at Login", isOn: $manager.launchAtLogin)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

                Divider()

                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Text("Quit Phosphene")
                        .font(.system(size: 13))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                }
                .buttonStyle(PopoverMenuItemStyle())
                .keyboardShortcut("q")
                .padding(4)
            }
        }
    }

    // MARK: - About

    private var aboutLine: some View {
        HStack(spacing: 3) {
            Text(versionString)
                .foregroundStyle(.secondary)
            Text("·")
                .foregroundStyle(.quaternary)
            Link("kagerou.glass", destination: URL(string: "https://kagerou.glass")!)
            Text("·")
                .foregroundStyle(.quaternary)
            Link("@kageroumado", destination: URL(string: "https://x.com/kageroumado")!)
        }
        .font(.caption)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
    }

    private var versionString: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "v\(version) (\(build))"
    }

    private func toggle(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 13))
            Spacer()
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .labelsHidden()
        }
    }
}

// MARK: - Button Styles

private struct PopoverMenuItemStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PopoverMenuItemBody(configuration: configuration)
    }

    private struct PopoverMenuItemBody: View {
        let configuration: Configuration
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .background {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.primary.opacity(isHovered ? 0.1 : 0))
                }
                .contentShape(RoundedRectangle(cornerRadius: 6))
                .onHover { isHovered = $0 }
        }
    }
}

#Preview {
    MenuBarPopoverView(manager: PhospheneManager())
        .frame(width: 320)
}
