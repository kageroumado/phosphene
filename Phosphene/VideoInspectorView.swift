import AVFoundation
import CoreMedia
import SwiftUI

struct VideoInspectorView: View {
    let entry: VideoDeploymentService.EntryInfo
    @Bindable var manager: PhospheneManager
    @State private var thumbnail: NSImage?
    @State private var selectedPreset: OptimizationPreset = .balanced
    @State private var codec: String = ""
    @State private var draftName: String = ""
    @State private var isRenaming = false
    @State private var isHoveringName = false
    @FocusState private var nameFocused: Bool
    @State private var confirmingRemoveVariants = false
    @State private var confirmingDelete = false

    @State private var player: AVQueuePlayer?
    @State private var looper: AVPlayerLooper?
    @State private var isPlaying = false
    @State private var isHoveringPreview = false

    private var isOptimizingThis: Bool {
        manager.isOptimizing && manager.optimizingEntryID == entry.id
    }

    /// The wallpaper selections currently using this video, one per display/Space.
    private var activeSelections: [WallpaperPrefsService.WallpaperSelection] {
        manager.prefsService.selections.filter { $0.videoID == entry.id }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                previewSection
                nameField
                specChips
                if !activeSelections.isEmpty {
                    inUseCard
                }
                optimizationCard

                Button {
                    NSWorkspace.shared.open(
                        URL(string: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension")!,
                    )
                } label: {
                    Text("Use as Wallpaper…")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .help("Phosphene wallpapers are selected in System Settings → Wallpaper")

                HStack(spacing: 8) {
                    Button {
                        let url = VideoDeploymentService.videoURL(for: entry)
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } label: {
                        Text("Show in Finder")
                            .frame(maxWidth: .infinity)
                    }

                    Button(role: .destructive) {
                        confirmingDelete = true
                    } label: {
                        Text("Delete…")
                            .frame(maxWidth: .infinity)
                    }
                    .alert("Delete Video", isPresented: $confirmingDelete) {
                        Button("Delete", role: .destructive) {
                            manager.removeVideo(entryID: entry.id)
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Are you sure you want to remove \"\(entry.name)\" from your library?")
                    }
                }
                .buttonStyle(.bordered)
            }
            .padding(14)
        }
        .task(id: entry.id) {
            draftName = entry.name
            loadThumbnail()
            await loadCodec()
        }
        .onChange(of: entry.id) {
            cleanupPlayer()
            isRenaming = false
        }
        .onDisappear {
            cleanupPlayer()
        }
    }

    // MARK: - Preview

    private var previewSection: some View {
        ZStack {
            if let player, isPlaying {
                PlayerLayerView(player: player)
            } else if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(16 / 9, contentMode: .fill)
            } else {
                Rectangle()
                    .fill(.quaternary)
                    .aspectRatio(16 / 9, contentMode: .fill)
                    .overlay {
                        Image(systemName: "film")
                            .font(.system(size: 24))
                            .foregroundStyle(.tertiary)
                    }
            }

            playOverlay
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHoveringPreview = hovering
            }
        }
    }

    private var playOverlay: some View {
        let showOverlay = isHoveringPreview || !isPlaying
        return Button {
            togglePlayback()
        } label: {
            ZStack {
                Circle()
                    .frame(width: 44, height: 44)
                    .glassEffect(.clear)

                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.secondary)
                    .contentTransition(.symbolEffect(.replace))
            }
        }
        .buttonStyle(.plain)
        .opacity(showOverlay ? 1 : 0)
        .scaleEffect(showOverlay ? 1 : 0.8)
        .allowsHitTesting(showOverlay)
        .animation(.spring(response: 0.5, dampingFraction: 0.7), value: showOverlay)
        .animation(.default, value: isPlaying)
    }

    private func togglePlayback() {
        if isPlaying {
            player?.pause()
            isPlaying = false
        } else {
            if player == nil {
                createPlayer()
            }
            player?.play()
            isPlaying = true
        }
    }

    private func createPlayer() {
        let url = VideoDeploymentService.videoURL(for: entry)
        let item = AVPlayerItem(url: url)
        let queuePlayer = AVQueuePlayer(playerItem: item)
        queuePlayer.isMuted = true
        let playerLooper = AVPlayerLooper(player: queuePlayer, templateItem: item)
        player = queuePlayer
        looper = playerLooper
    }

    private func cleanupPlayer() {
        looper?.disableLooping()
        player?.pause()
        player = nil
        looper = nil
        isPlaying = false
    }

    // MARK: - Name

    /// A plain label until clicked — a resident TextField would grab the window's
    /// initial first responder and sit in editing mode permanently.
    @ViewBuilder
    private var nameField: some View {
        if isRenaming {
            TextField("Name", text: $draftName)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .semibold))
                .multilineTextAlignment(.center)
                .focused($nameFocused)
                .onSubmit { endRenaming(commit: true) }
                .onExitCommand { endRenaming(commit: false) }
                .onChange(of: nameFocused) { _, focused in
                    if !focused { endRenaming(commit: true) }
                }
                .padding(.vertical, 3)
                .padding(.horizontal, 6)
                .background(.quinary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .task { nameFocused = true }
        } else {
            Text(entry.name)
                .font(.system(size: 13, weight: .semibold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 3)
                .padding(.horizontal, 6)
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isHoveringName ? AnyShapeStyle(.quinary) : AnyShapeStyle(.clear))
                }
                .onHover { isHoveringName = $0 }
                .onTapGesture {
                    draftName = entry.name
                    isRenaming = true
                }
                .help("Click to rename — the name also shows in the System Settings wallpaper picker")
        }
    }

    private func endRenaming(commit: Bool) {
        guard isRenaming else { return }
        isRenaming = false
        guard commit else { return }
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != entry.name else { return }
        VideoDeploymentService.renameEntry(entryID: entry.id, to: trimmed)
    }

    // MARK: - Specs

    private var specChips: some View {
        HStack(spacing: 5) {
            if entry.resolution != .zero {
                specChip(resolutionLabel(entry.resolution))
            }
            if entry.fps > 0 {
                specChip("\(Int(entry.fps)) fps")
            }
            if entry.duration > 0 {
                specChip(formattedDuration(entry.duration))
            }
            if let size = VideoDeploymentService.fileSize(for: entry) {
                specChip(formattedFileSize(size))
            }
            if !codec.isEmpty {
                specChip(codec)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func specChip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.quinary, in: Capsule())
    }

    private func resolutionLabel(_ size: CGSize) -> String {
        switch (Int(size.width), Int(size.height)) {
        case (3840, 2160): "4K"
        case (2560, 1440): "1440p"
        case (1920, 1080): "1080p"
        default: "\(Int(size.width)) × \(Int(size.height))"
        }
    }

    // MARK: - In Use

    private var inUseCard: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(.tint)
            Text(inUseText)
                .font(.system(size: 11.5, weight: .medium))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private var inUseText: String {
        let names = activeSelections.map { selection in
            if let spaceName = selection.spaceName {
                "\(selection.displayName) · \(spaceName)"
            } else {
                selection.displayName
            }
        }
        return "In use on \(names.joined(separator: ", "))"
    }

    // MARK: - Optimization

    private var optimizationCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Optimization")
                .font(.system(size: 10.5, weight: .semibold))
                .kerning(0.6)
                .textCase(.uppercase)
                .foregroundStyle(.tertiary)

            if isOptimizingThis {
                optimizingView
            } else if let variants = entry.variants, !variants.isEmpty {
                optimizedView(variants)
            } else {
                notOptimizedView
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private var optimizingView: some View {
        VStack(spacing: 8) {
            ProgressView(value: manager.optimizationProgress) {
                Text("Optimizing…")
                    .font(.system(size: 12, weight: .medium))
            }

            Button("Cancel", role: .destructive) {
                manager.cancelOptimization()
            }
            .controlSize(.small)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private func optimizedView(_ variants: [VideoVariant]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(variants, id: \.filename) { variant in
                HStack {
                    Text("\(variant.fps) fps")
                        .font(.system(size: 11.5))
                    Spacer()
                    Text("\(Int(variant.resolution.width)) × \(Int(variant.resolution.height))")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Label("Optimized", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.green)
                Spacer()
                Button("Remove Variants", role: .destructive) {
                    confirmingRemoveVariants = true
                }
                .controlSize(.small)
            }
            .padding(.top, 3)
            .alert("Remove Variants", isPresented: $confirmingRemoveVariants) {
                Button("Remove", role: .destructive) {
                    manager.removeVariants(entryID: entry.id)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will delete the optimized variants. The original video is not affected.")
            }
        }
    }

    private var notOptimizedView: some View {
        VStack(alignment: .leading, spacing: 7) {
            Picker(selection: $selectedPreset) {
                ForEach(OptimizationPreset.allCases) { preset in
                    Text(preset.rawValue).tag(preset)
                }
            } label: {
                EmptyView()
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text(selectedPreset.description)
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                manager.optimizeVideo(entryID: entry.id, preset: selectedPreset)
            } label: {
                Text("Create Variants")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(entry.resolution == .zero)
        }
    }

    // MARK: - Helpers

    private func loadThumbnail() {
        if let url = VideoDeploymentService.thumbnailURL(for: entry.id),
           let image = NSImage(contentsOf: url) {
            thumbnail = image
        } else {
            thumbnail = nil
        }
    }

    private func loadCodec() async {
        let url = VideoDeploymentService.videoURL(for: entry)
        let asset = AVURLAsset(url: url)
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let descriptions = try? await track.load(.formatDescriptions),
           let desc = descriptions.first {
            let code = CMFormatDescriptionGetMediaSubType(desc)
            switch code {
            case kCMVideoCodecType_HEVC: codec = "HEVC"
            case kCMVideoCodecType_H264: codec = "H.264"
            case kCMVideoCodecType_VP9: codec = "VP9"
            case kCMVideoCodecType_AV1: codec = "AV1"
            default:
                let b3 = UInt8((code >> 24) & 0xFF)
                let b2 = UInt8((code >> 16) & 0xFF)
                let b1 = UInt8((code >> 8) & 0xFF)
                let b0 = UInt8(code & 0xFF)
                codec = String(bytes: [b3, b2, b1, b0], encoding: .ascii)?
                    .trimmingCharacters(in: .whitespaces) ?? "Unknown"
            }
        }
    }

    private func formattedDuration(_ seconds: Double) -> String {
        let total = Int(seconds)
        let mins = total / 60
        let secs = total % 60
        let secStr = secs < 10 ? "0\(secs)" : "\(secs)"
        return "\(mins):\(secStr)"
    }

    private func formattedFileSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
