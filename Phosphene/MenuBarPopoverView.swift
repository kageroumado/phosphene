import Propofol
import SwiftUI

struct MenuBarPopoverView: View {
    @Bindable var manager: PhospheneManager
    var openLibrary: () -> Void = {}
    @State private var selectedIndex = 0
    @Environment(\.openSettings) private var openSettings

    private var prefsService: WallpaperPrefsService {
        manager.prefsService
    }

    var body: some View {
        // Zero blend distance: the footer's controls sit closer together than any nonzero
        // spacing would allow before their glass starts pooling into one shape.
        GlassEffectContainer(spacing: 0) {
            VStack(spacing: Theme.Space.md) {
                PopoverHeader("Phosphene")

                UsageQuestionCard()

                if prefsService.selections.isEmpty {
                    emptyStateSection
                } else {
                    heroSection
                }

                footerSection
            }
            .popoverContainer()
        }
        .frame(width: Theme.popoverWidth)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            SilentUpdates.shared.refresh()
            SilentUpdates.shared.checkIfStale()
            UsageCounting.shared.noteUse()
        }
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
        .clipShape(Theme.concentricCardShape)
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
            return String(localized: "Playing on Lock Screen")
        }
        if prefsService.fullscreenDisplays.contains(selection.displayID) {
            return String(localized: "Paused — Fullscreen App")
        }
        if prefsService.pauseWhenOccluded,
           prefsService.desktopOccluded || prefsService.occludedDisplays.contains(selection.displayID) {
            return String(localized: "Paused — Display Covered")
        }
        if prefsService.pausedDisplays.contains(selection.displayID) {
            return String(localized: "Paused")
        }
        if prefsService.userPaused {
            return String(localized: "Paused")
        }
        return String(localized: "Playing")
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

                HStack(spacing: Theme.Space.xs) {
                    Button("Open Library") {
                        openLibrary()
                    }
                    Button("Wallpaper Engine…") {
                        manager.library.section = .workshopAll
                        openLibrary()
                    }
                    .help("Make wallpapers from Wallpaper Engine downloads")
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

    // MARK: - Footer

    private var footerSection: some View {
        HStack(spacing: 6) {
            FooterChip(text: String(localized: "Library"), systemImage: "film.stack", action: openLibrary)
            FooterChip(text: String(localized: "Choose"), systemImage: "photo.on.rectangle") {
                NSWorkspace.shared.open(WallpaperPrefsService.wallpaperSettingsURL)
            }
            .help("Choose the wallpaper in macOS Wallpaper Settings")

            Spacer(minLength: 0)

            FooterIconButton(String(localized: "Settings"), systemImage: "gearshape") {
                NSApp.setActivationPolicy(.regular)
                openSettings()
                NSApp.activate()
            }
            .help("Settings")

            FooterIconButton(String(localized: "Restart Wallpaper Agent"), systemImage: "arrow.clockwise") {
                WallpaperPrefsService.shared.restartWallpaperAgent()
            }
            .help("Force-restart the system WallpaperAgent if the wallpaper is stuck or wrong.")

            FooterIconButton(String(localized: "Quit Phosphene"), systemImage: "xmark") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
            .help("Quit Phosphene")
        }
    }
}

#Preview {
    MenuBarPopoverView(manager: PhospheneManager())
}
