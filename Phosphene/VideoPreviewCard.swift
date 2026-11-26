import AppKit
import SwiftUI

/// The popover's hero card: the entry's first-frame thumbnail, like the tiles in
/// Wallpaper Settings. A live player here spawns its own VTDecoderXPCService and
/// software-scales full-resolution frames for as long as the popover is open
/// (~50% CPU), all to preview a video that
/// is already playing full-screen behind the popover.
struct VideoPreviewCard: View {
    var videoID: String?
    var videoURL: URL?
    var displayID: UInt32?

    @State private var isHovering = false
    @State private var thumbnail: NSImage?
    @State private var loadedSelection: (videoID: String, pair: VideoPairSelection?)?
    @State private var revision = 0

    private struct SelectionKey: Equatable {
        let videoID: String?
        let videoURL: URL?
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
                    .id(revision)
            } else if let thumbnail {
                Color.black
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
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
        .task(id: SelectionKey(videoID: videoID, videoURL: videoURL, revision: revision)) {
            await loadPair()
            guard !Task.isCancelled, pair == nil else { return }
            await loadThumbnail()
        }
        .onReceive(NotificationCenter.default.publisher(for: VideoDeploymentService.libraryChangedNotification)) { _ in
            revision += 1
        }
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

    // MARK: - Play Overlay

    private var playOverlay: some View {
        PlayOverlayButton(
            isPaused: isEffectivelyPaused,
            isVisible: shouldShowOverlay,
            diameter: Layout.playButtonDiameter,
            action: toggleWallpaperPlayback,
        )
    }

    private var wallpaperPlaybackLabel: LocalizedStringKey {
        isEffectivelyPaused ? "Resume Desktop Wallpaper" : "Pause Desktop Wallpaper"
    }

    private func toggleWallpaperPlayback() {
        // A global user pause (the popover's "Paused" scope) outranks per-display
        // pause, so while it is set the play button resumes globally — toggling a
        // display underneath it would visibly do nothing.
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
        (videoURL != nil || pair != nil) && !isAutoPaused
    }

    private var shouldShowOverlay: Bool {
        canToggleWallpaper && (isHovering || isEffectivelyPaused)
    }

    // MARK: - Thumbnail

    private func loadThumbnail() async {
        guard let videoID else {
            thumbnail = nil
            return
        }
        if let url = VideoDeploymentService.thumbnailURL(for: videoID),
           let image = NSImage(contentsOf: url) {
            thumbnail = image
            return
        }
        // Entries deployed before thumbnails existed have no thumbnail.jpg yet:
        // generate one into the entry folder so every later load is a file read.
        guard let videoURL else {
            thumbnail = nil
            return
        }
        await VideoDeploymentService.generateThumbnail(
            for: videoURL,
            in: videoURL.deletingLastPathComponent(),
        )
        guard !Task.isCancelled else { return }
        if let url = VideoDeploymentService.thumbnailURL(for: videoID) {
            thumbnail = NSImage(contentsOf: url)
        } else {
            thumbnail = nil
        }
    }

    private func loadPair() async {
        guard let videoID else {
            loadedSelection = nil
            return
        }
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
        try? AppearancePair.read(in: directory).first { $0.contains(videoID) && $0.deletionPending != true }
    }
}

#Preview {
    VideoPreviewCard(videoURL: nil)
        .frame(width: 320)
}
