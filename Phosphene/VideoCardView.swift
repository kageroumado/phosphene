import AVFoundation
import SwiftUI

struct VideoCardView: View {
    let entry: VideoDeploymentService.EntryInfo
    var isSelected: Bool = false
    var isInUse: Bool = false
    var isOptimizing: Bool = false
    var optimizationProgress: Double = 0
    let onSelect: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false
    @State private var thumbnail: NSImage?
    @State private var previewPlayer: AVQueuePlayer?
    @State private var playerLooper: AVPlayerLooper?

    var body: some View {
        VStack(spacing: 7) {
            thumbnailView
            Text(entry.name)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .top)
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
            if hovering {
                startPreview()
            } else {
                stopPreview()
            }
        }
        .onTapGesture { onSelect() }
        .contextMenu { contextMenuItems }
        .task { loadThumbnail() }
        .onDisappear { stopPreview() }
    }

    // MARK: - Thumbnail

    private var thumbnailView: some View {
        ZStack {
            Group {
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
            }

            if let previewPlayer {
                PlayerLayerView(player: previewPlayer)
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
        .shadow(color: .black.opacity(isHovered ? 0.18 : 0.08), radius: isHovered ? 8 : 4, y: 2)
        .animation(.easeInOut(duration: 0.15), value: isHovered)
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

    // MARK: - Hover Preview

    private func startPreview() {
        guard previewPlayer == nil else { return }
        let url = VideoDeploymentService.videoURL(for: entry)
        let playerItem = AVPlayerItem(url: url)
        let queuePlayer = AVQueuePlayer(playerItem: playerItem)
        queuePlayer.isMuted = true
        playerLooper = AVPlayerLooper(player: queuePlayer, templateItem: playerItem)
        previewPlayer = queuePlayer
        queuePlayer.play()
    }

    private func stopPreview() {
        playerLooper?.disableLooping()
        previewPlayer?.pause()
        previewPlayer = nil
        playerLooper = nil
    }

    // MARK: - Context Menu

    @ViewBuilder
    private var contextMenuItems: some View {
        Button("Show in Finder") { showInFinder() }
        Divider()
        Button("Delete", role: .destructive) { onDelete() }
    }

    // MARK: - Private

    private func loadThumbnail() {
        if let url = VideoDeploymentService.thumbnailURL(for: entry.id),
           let image = NSImage(contentsOf: url) {
            thumbnail = image
        }
    }

    private func showInFinder() {
        let url = VideoDeploymentService.videoURL(for: entry)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
