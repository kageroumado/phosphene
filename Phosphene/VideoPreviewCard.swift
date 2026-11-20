import SwiftUI

/// The popover uses the Wallpaper Settings thumbnail while the desktop plays the video.
struct VideoPreviewCard: View {
    var videoID: String?
    var videoURL: URL?
    var displayID: UInt32?

    @State private var loadedSelection: (videoID: String, pair: VideoPairSelection?)?
    @State private var isHovering = false
    @State private var libraryRevision = 0

    private struct PairRequest: Equatable {
        let videoID: String?
        let revision: Int
    }

    private enum Layout {
        static let playButtonDiameter: CGFloat = 56
    }

    private var prefsService: WallpaperPrefsService {
        .shared
    }

    private var pair: VideoPairSelection? {
        loadedSelection?.videoID == videoID ? loadedSelection?.pair : nil
    }

    var body: some View {
        ZStack {
            if let pair, let record = pair.saved {
                PairComparisonView(selection: pair, swapped: record.swapped)
            } else if let videoID, loadedSelection?.videoID == videoID {
                VideoThumbnail(videoID: videoID, legacyVideoURL: videoURL) { thumbnail in
                    if let thumbnail {
                        Color.black
                            .overlay {
                                Image(nsImage: thumbnail)
                                    .resizable()
                                    .scaledToFill()
                            }
                            .clipped()
                    } else {
                        placeholder
                    }
                }
            } else {
                placeholder
            }

            if pair == nil {
                playOverlay
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipped()
        .overlay(alignment: .topTrailing) {
            if pair != nil, canToggleWallpaper {
                Button("Wallpaper", systemImage: isEffectivelyPaused ? "play.fill" : "pause.fill", action: toggleWallpaperPlayback)
                    .buttonStyle(.glass)
                    .labelStyle(.titleAndIcon)
                    .controlSize(.small)
                    .accessibilityLabel(Text(wallpaperPlaybackLabel))
                    .help(Text(wallpaperPlaybackLabel))
                    .padding(8)
            }
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
        .task(id: PairRequest(videoID: videoID, revision: libraryRevision)) {
            await loadPair()
        }
        .onReceive(NotificationCenter.default.publisher(for: VideoDeploymentService.libraryChangedNotification)) { _ in
            libraryRevision += 1
        }
        .onDisappear { isHovering = false }
    }

    // MARK: - Placeholder

    private var placeholder: some View {
        Color(white: 0, opacity: 0.03)
            .overlay {
                VStack(spacing: 8) {
                    Image(systemName: videoURL != nil ? "film.fill" : "film")
                        .font(.system(size: 32, weight: .light))
                        .foregroundStyle(.quaternary)
                    Text("No Video Selected")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
            }
    }

    // MARK: - Wallpaper Playback

    private var playOverlay: some View {
        PlayOverlayButton(
            isPaused: isEffectivelyPaused,
            isVisible: shouldShowOverlay,
            diameter: Layout.playButtonDiameter,
            action: toggleWallpaperPlayback,
        )
        .accessibilityLabel(Text(wallpaperPlaybackLabel))
        .help(Text(wallpaperPlaybackLabel))
    }

    private var wallpaperPlaybackLabel: LocalizedStringKey {
        isEffectivelyPaused ? "Resume Desktop Wallpaper" : "Pause Desktop Wallpaper"
    }

    private func toggleWallpaperPlayback() {
        // Resume a global user pause before changing any per-display state.
        if prefsService.userPaused {
            prefsService.userPaused = false
        } else if let displayID {
            prefsService.togglePause(displayID: displayID)
        } else {
            prefsService.togglePause()
        }
    }

    /// This card's display is invisible behind windows (its own display covered,
    /// or every display) and the occlusion pause is on — or a fullscreen app owns
    /// the display, which pauses unconditionally.
    private var isPausedByOcclusion: Bool {
        if displayID.map({ prefsService.fullscreenDisplays.contains($0) }) ?? false {
            return true
        }
        return prefsService.pauseWhenOccluded
            && (prefsService.desktopOccluded
                || displayID.map { prefsService.occludedDisplays.contains($0) } ?? false)
    }

    /// The wallpaper is effectively paused for any reason: user, lock-screen-only, occlusion, or inactive.
    private var isEffectivelyPaused: Bool {
        !prefsService.isActive
            || prefsService.userPaused
            || prefsService.alwaysPauseDesktop
            || isPausedByOcclusion
            || displayID.map { prefsService.pausedDisplays.contains($0) } ?? false
    }

    /// Only user-initiated pauses can be toggled via the overlay button.
    private var isAutoPaused: Bool {
        prefsService.alwaysPauseDesktop || isPausedByOcclusion
    }

    private var canToggleWallpaper: Bool {
        videoURL != nil && !isAutoPaused
    }

    private var shouldShowOverlay: Bool {
        canToggleWallpaper && (isHovering || isEffectivelyPaused)
    }

    private func loadPair() async {
        guard let videoID else { return }
        let record = await Self.pairRecord(for: videoID, in: VideoDeploymentService.videosFolderURL)
        guard !Task.isCancelled else { return }
        guard let record else {
            loadedSelection = (videoID, nil)
            return
        }
        let entries = VideoDeploymentService.listEntries()
        loadedSelection = (
            videoID,
            VideoPairSelection(first: entries.first { $0.id == record.owner }, second: entries.first { $0.id == record.counterpart }, saved: record),
        )
    }

    @concurrent
    private nonisolated static func pairRecord(for videoID: String, in directory: URL) async -> AppearancePair? {
        try? AppearancePair.read(in: directory).first { $0.contains(videoID) }
    }
}

#Preview {
    VideoPreviewCard(videoURL: nil)
        .frame(width: 320)
}
