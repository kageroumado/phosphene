import AVFoundation
import SwiftUI

struct VideoCardView: View {
    let entry: VideoDeploymentService.EntryInfo
    let pair: VideoPairSelection?
    var isSelected: Bool = false
    var isInUse: Bool = false
    var isOptimizing: Bool = false
    var optimizationProgress: Double = 0
    let onSelect: (NSEvent.ModifierFlags) -> Void

    var body: some View {
        BrowserHoverPreview { isHovered, isPlaying in
            VStack(spacing: 7) {
                thumbnailView(isHovered: isHovered, isPlaying: isPlaying)
                VideoEntryTitle(name: entry.name, isPair: pair != nil)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .top)
            }
        }
        .gesture(
            TapGesture().modifiers(.command).onEnded { onSelect(.command) }
                .exclusively(before: TapGesture().modifiers(.shift).onEnded { onSelect(.shift) })
                .exclusively(before: TapGesture().onEnded { onSelect([]) }),
        )
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { onSelect([]) }
    }

    // MARK: - Thumbnail

    private func thumbnailView(isHovered: Bool, isPlaying: Bool) -> some View {
        Group {
            if let pair, let saved = pair.saved {
                VideoPairPreview(selection: pair, swapped: saved.swapped, isPlaying: isPlaying)
            } else {
                VideoThumbnail(videoID: entry.id) { thumbnail in
                    ZStack {
                        if let thumbnail {
                            Color.clear
                                .overlay {
                                    Image(nsImage: thumbnail)
                                        .resizable()
                                        .scaledToFill()
                                }
                        } else {
                            Rectangle()
                                .fill(.quaternary)
                                .overlay {
                                    Image(systemName: "film")
                                        .font(.system(size: 24))
                                        .foregroundStyle(.tertiary)
                                }
                        }
                        if isPlaying {
                            VideoHoverPlayer(url: VideoDeploymentService.videoURL(for: entry))
                                .allowsHitTesting(false)
                        }
                    }
                }
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(alignment: .bottomTrailing) {
            if isInUse {
                inUseBadge
            }
        }
        .overlay(alignment: .bottomLeading) {
            if isOptimizing {
                optimizingPill
            }
        }
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.tint, lineWidth: 2.5)
                    .padding(-3)
            }
        }
        .animation(.easeInOut(duration: 0.15)) { content in
            content.shadow(color: .black.opacity(isHovered ? 0.18 : 0.08), radius: isHovered ? 8 : 4, y: 2)
        }
    }

    private var inUseBadge: some View {
        Image(systemName: "checkmark")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 20, height: 20)
            .background(.tint, in: Circle())
            .padding(7)
            .help("In use as wallpaper")
    }

    private var optimizingPill: some View {
        HStack(spacing: 5) {
            ProgressView(value: optimizationProgress)
                .progressViewStyle(.circular)
                .controlSize(.mini)
                .tint(.white)
            Text("Optimizing")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.black.opacity(0.55), in: Capsule())
        .padding(7)
    }
}

private struct VideoHoverPlayer: View {
    let url: URL
    @State private var playback: LoopingVideoPreview?

    var body: some View {
        Color.clear
            .overlay {
                if let playback {
                    PlayerLayerView(player: playback.player)
                }
            }
            .task(id: url) {
                guard !Task.isCancelled else { return }
                stop()
                let playback = LoopingVideoPreview(url: url)
                self.playback = playback
                playback.player.play()
            }
            .onDisappear(perform: stop)
    }

    private func stop() {
        playback?.stop()
        playback = nil
    }
}

/// Owns a muted preview loop and explicitly releases its queued items.
struct LoopingVideoPreview {
    let player: AVQueuePlayer
    private let looper: AVPlayerLooper

    init(url: URL) {
        let player = AVQueuePlayer()
        player.isMuted = true
        self.player = player
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
    }

    func stop() {
        player.pause()
        looper.disableLooping()
        player.removeAllItems()
    }
}
