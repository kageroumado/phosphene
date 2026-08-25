import AppKit
import SwiftUI

/// The popover's hero card: the entry's first-frame thumbnail, like the tiles in
/// Wallpaper Settings. A live player here spawns its own VTDecoderXPCService and
/// software-scales full-resolution frames for as long as the popover is open
/// (~50% CPU — see GAME-INTERFERENCE-FINDINGS.md), all to preview a video that
/// is already playing full-screen behind the popover.
struct VideoPreviewCard: View {
    var videoID: String?
    var videoURL: URL?
    var displayID: UInt32?

    @State private var isHovering = false
    @State private var thumbnail: NSImage?

    private var prefsService: WallpaperPrefsService {
        .shared
    }

    var body: some View {
        ZStack {
            if let thumbnail {
                Color.black
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                placeholder
            }

            playOverlay
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipped()
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
        .task(id: videoID) { await loadThumbnail() }
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

    /// Always resident in the hierarchy — visibility is opacity-only, so state flips
    /// (scope changes, hover) cross-fade instead of removing and reinserting the button,
    /// which drops a frame and restarts the transition from nothing.
    private var playOverlay: some View {
        Button(action: {
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
        }) {
            ZStack {
                Circle()
                    .frame(width: 56, height: 56)
                    .glassEffect(.clear)

                Image(systemName: isEffectivelyPaused ? "play.fill" : "pause.fill")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.secondary)
                    .contentTransition(.symbolEffect(.replace))
            }
        }
        .buttonStyle(.plain)
        .opacity(shouldShowOverlay ? 1 : 0)
        .scaleEffect(shouldShowOverlay ? 1 : 0.8)
        .allowsHitTesting(shouldShowOverlay)
        .animation(.spring(response: 0.5, dampingFraction: 0.7), value: shouldShowOverlay)
        .animation(.default, value: isEffectivelyPaused)
    }

    /// This card's display is invisible behind windows (its own display covered,
    /// or every display) and the occlusion pause is on.
    private var isPausedByOcclusion: Bool {
        prefsService.pauseWhenOccluded
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

    private var shouldShowOverlay: Bool {
        videoURL != nil && !isAutoPaused && (isHovering || isEffectivelyPaused)
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
        if let url = VideoDeploymentService.thumbnailURL(for: videoID) {
            thumbnail = NSImage(contentsOf: url)
        } else {
            thumbnail = nil
        }
    }
}

#Preview {
    VideoPreviewCard(videoURL: nil)
        .frame(width: 320)
}
