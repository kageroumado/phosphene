import AVFoundation
import SwiftUI

struct VideoPreviewCard: View {
    var videoURL: URL?
    var displayID: UInt32?

    @State private var isHovering = false
    @State private var previewPlayer: AVQueuePlayer?
    @State private var playerLooper: AVPlayerLooper?

    private var prefsService: WallpaperPrefsService {
        .shared
    }

    var body: some View {
        ZStack {
            if let previewPlayer {
                PlayerLayerView(player: previewPlayer)
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
        .onAppear { startPreview() }
        .onChange(of: videoURL) {
            cleanupPreviewPlayer()
            startPreview()
        }
        .onChange(of: isEffectivelyPaused) {
            if isEffectivelyPaused {
                previewPlayer?.pause()
            } else {
                previewPlayer?.play()
            }
        }
        .onDisappear { cleanupPreviewPlayer() }
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

    /// The wallpaper is effectively paused for any reason: user, lock-screen-only, occlusion, or inactive.
    private var isEffectivelyPaused: Bool {
        !prefsService.isActive
            || prefsService.userPaused
            || prefsService.alwaysPauseDesktop
            || (prefsService.pauseWhenOccluded && prefsService.desktopOccluded)
            || displayID.map { prefsService.pausedDisplays.contains($0) } ?? false
    }

    /// Only user-initiated pauses can be toggled via the overlay button.
    private var isAutoPaused: Bool {
        prefsService.alwaysPauseDesktop
            || (prefsService.pauseWhenOccluded && prefsService.desktopOccluded)
    }

    private var shouldShowOverlay: Bool {
        videoURL != nil && !isAutoPaused && (isHovering || isEffectivelyPaused)
    }

    // MARK: - Playback

    private func startPreview() {
        guard videoURL != nil, previewPlayer == nil else { return }
        createPlayer()
        if isEffectivelyPaused {
            previewPlayer?.pause()
        } else {
            previewPlayer?.play()
        }
    }

    private func createPlayer() {
        guard let videoURL else { return }

        let playerItem = AVPlayerItem(url: videoURL)
        let queuePlayer = AVQueuePlayer(playerItem: playerItem)
        queuePlayer.isMuted = true

        let looper = AVPlayerLooper(player: queuePlayer, templateItem: playerItem)

        previewPlayer = queuePlayer
        playerLooper = looper
    }

    private func cleanupPreviewPlayer() {
        playerLooper?.disableLooping()
        previewPlayer?.pause()
        previewPlayer = nil
        playerLooper = nil
    }
}

// MARK: - PlayerLayerView

struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true

        let playerLayer = AVPlayerLayer(player: player)
        playerLayer.videoGravity = .resizeAspect
        playerLayer.frame = view.bounds
        playerLayer.backgroundColor = NSColor.clear.cgColor
        playerLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]

        if let viewLayer = view.layer {
            viewLayer.addSublayer(playerLayer)
            context.coordinator.playerLayer = playerLayer
        }

        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let playerLayer = context.coordinator.playerLayer {
            let newFrame = nsView.bounds
            if newFrame != playerLayer.frame {
                playerLayer.frame = newFrame
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    @MainActor
    class Coordinator {
        var playerLayer: AVPlayerLayer?
    }
}

#Preview {
    VideoPreviewCard(videoURL: nil)
        .frame(width: 320)
}
