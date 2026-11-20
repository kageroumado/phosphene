import AVFoundation
import SwiftUI
import VideoToolbox

/// The inspector column: what is selected in the current section.
struct LibraryInspector: View {
    @Environment(LibraryStore.self) private var store

    var body: some View {
        if store.section.isWorkshop {
            let selected = store.selectedDownloads
            if selected.count == 1, let item = selected.first {
                DownloadInspector(item: item)
            } else if selected.count > 1 {
                let renderable = store.renderableSelection.count
                SelectionSummary(
                    count: selected.count,
                    detail: String(localized: "\(renderable) can become videos"),
                )
            } else {
                emptySelection(Text("Select wallpapers to see what Phosphene can make of them."))
            }
        } else {
            let selected = store.selectedVideos
            if selected.count == 1, let entry = selected.first {
                VideoInspector(entry: entry)
            } else if selected.count > 1 {
                SelectionSummary(count: selected.count, detail: nil)
            } else {
                emptySelection(Text("Select a video to view its details."))
            }
        }
    }

    private func emptySelection(_ description: Text) -> some View {
        ContentUnavailableView {
            Label("No Selection", systemImage: "sidebar.right")
        } description: {
            description
        }
    }
}

/// The inspector when several things are selected.
private struct SelectionSummary: View {
    let count: Int
    let detail: String?

    var body: some View {
        ContentUnavailableView {
            Label("\(count) Selected", systemImage: "square.stack")
        } description: {
            if let detail {
                Text(detail)
            }
        }
    }
}

// MARK: - Shared pieces

private enum InspectorMetrics {
    static let padding: CGFloat = 16
    static let sectionSpacing: CGFloat = 16
    static let previewRadius: CGFloat = 8
}

private extension View {
    /// The inspector's content padding. Its top inset is the grid's, so the preview lines
    /// up with the first row of tiles.
    func inspectorPadding() -> some View {
        padding(.horizontal, InspectorMetrics.padding)
            .padding(.bottom, InspectorMetrics.padding)
            .padding(.top, LibraryGridMetrics.padding)
    }
}

/// A titled group of inspector content.
private struct InspectorSection<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One fact: its name and its value.
private struct InfoRow: Identifiable {
    let label: String
    let value: String

    var id: String {
        label
    }
}

/// Facts as label and value rows, divided like Finder's preview pane.
private struct InfoRows: View {
    let rows: [InfoRow]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(rows) { row in
                HStack(alignment: .firstTextBaseline) {
                    Text(verbatim: row.label)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 12)
                    Text(verbatim: row.value)
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                }
                .padding(.vertical, 5)
                .overlay(alignment: .top) {
                    if row.id != rows.first?.id {
                        Divider()
                    }
                }
            }
        }
        .font(.callout)
    }
}

// MARK: - Video

/// The video track's codec, and whether this Mac decodes it in hardware.
nonisolated struct VideoCodec: Equatable {
    let label: String
    let isHardwareDecoded: Bool

    static func load(from url: URL) async -> VideoCodec? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let description = try? await track.load(.formatDescriptions).first
        else { return nil }
        let code = CMFormatDescriptionGetMediaSubType(description)
        let label = switch code {
        case kCMVideoCodecType_HEVC: "HEVC"
        case kCMVideoCodecType_H264: "H.264"
        case kCMVideoCodecType_VP9: "VP9"
        case kCMVideoCodecType_AV1: "AV1"
        default: fourCharacterCode(code)
        }
        return VideoCodec(label: label, isHardwareDecoded: VTIsHardwareDecodeSupported(code))
    }

    private static func fourCharacterCode(_ code: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        return String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? "—"
    }
}

/// One library video: it plays, then its name, where it is in use, and its facts.
struct VideoInspector: View {
    let entry: VideoDeploymentService.EntryInfo

    @Environment(PhospheneManager.self) private var manager
    @Environment(LibraryStore.self) private var store
    @State private var codec: VideoCodec?
    @State private var fileSize: Int64?
    @State private var confirmingRemoveVariants = false

    private var isWorkingOnThis: Bool {
        manager.isOptimizing && manager.optimizingEntryID == entry.id
    }

    private var isConvertingThis: Bool {
        isWorkingOnThis && manager.isConverting
    }

    /// What the file facts depend on: the entry, its file, and whether a conversion of it
    /// is running, so they reload once a conversion swaps the file.
    private struct FileKey: Equatable {
        let entryID: String
        let filename: String
        let isConverting: Bool
        let revision: Int
    }

    private var usedOn: [String] {
        manager.prefsService.selections.filter { $0.videoID == entry.id }.map { selection in
            if let spaceName = selection.spaceName {
                "\(selection.displayName) · \(spaceName)"
            } else {
                selection.displayName
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: InspectorMetrics.sectionSpacing) {
                VideoPreview(
                    url: VideoDeploymentService.videoURL(for: entry),
                    poster: VideoDeploymentService.thumbnailURL(for: entry.id),
                    revision: store.revision,
                )
                header
                if let codec, !codec.isHardwareDecoded {
                    softwareDecodeNotice(codec.label)
                }
                InfoRows(rows: facts)
                InspectorSection(title: "Optimization") {
                    optimization
                }
            }
            .inspectorPadding()
        }
        .task(id: FileKey(
            entryID: entry.id, filename: entry.filename, isConverting: isConvertingThis, revision: store.revision,
        )) {
            let url = VideoDeploymentService.videoURL(for: entry)
            fileSize = VideoDeploymentService.fileSize(for: entry)
            let loaded = await VideoCodec.load(from: url)
            guard !Task.isCancelled else { return }
            codec = loaded
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                InspectorNameField(entryID: entry.id, name: entry.name)
                let usedOn = usedOn
                if !usedOn.isEmpty {
                    Label {
                        Text("In use on \(usedOn.joined(separator: ", "))")
                    } icon: {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.tint)
                    }
                    .font(.callout)
                }
            }
            Button("Open Wallpaper Settings…") { store.openWallpaperSettings() }
                .help("Phosphene wallpapers are selected in System Settings → Wallpaper")
        }
    }

    // MARK: Facts

    private var facts: [InfoRow] {
        var rows: [InfoRow] = []
        if entry.resolution != .zero {
            let size = "\(Int(entry.resolution.width)) × \(Int(entry.resolution.height))"
            rows.append(InfoRow(label: String(localized: "Resolution"), value: size))
        }
        if entry.fps > 0 {
            rows.append(InfoRow(label: String(localized: "Frame Rate"), value: String(localized: "\(Int(entry.fps.rounded())) fps")))
        }
        if entry.duration > 0 {
            let duration = Duration.seconds(entry.duration).formatted(.time(pattern: .minuteSecond))
            rows.append(InfoRow(label: String(localized: "Duration"), value: duration))
        }
        if let fileSize {
            let size = ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
            rows.append(InfoRow(label: String(localized: "Size"), value: size))
        }
        if let codec {
            rows.append(InfoRow(label: String(localized: "Codec"), value: codec.label))
        }
        let added = entry.dateAdded.formatted(date: .abbreviated, time: .omitted)
        rows.append(InfoRow(label: String(localized: "Added"), value: added))
        return rows
    }

    // MARK: Software decoding

    private func softwareDecodeNotice(_ codecLabel: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text("This Mac decodes \(codecLabel) in software, so playback can stutter.")
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
            }
            .font(.callout)

            if isConvertingThis {
                ProgressView(value: manager.optimizationProgress) {
                    Text("Converting…")
                        .font(.callout)
                }
                Button("Cancel") { manager.cancelOptimization() }
                    .frame(maxWidth: .infinity, alignment: .trailing)
            } else {
                Button {
                    manager.convertToHEVC(entryID: entry.id)
                } label: {
                    Text("Convert to HEVC")
                        .frame(maxWidth: .infinity)
                }
                .disabled(manager.isOptimizing)
            }
        }
    }

    // MARK: Optimization

    @ViewBuilder
    private var optimization: some View {
        if isWorkingOnThis, !manager.isConverting {
            ProgressView(value: manager.optimizationProgress) {
                Text("Optimizing…")
                    .font(.callout)
            }
            Button("Cancel") { manager.cancelOptimization() }
                .frame(maxWidth: .infinity, alignment: .trailing)
        } else if let variants = entry.variants, !variants.isEmpty {
            InfoRows(rows: variants.map { variant in
                InfoRow(
                    label: String(localized: "\(variant.fps) fps"),
                    value: "\(Int(variant.resolution.width)) × \(Int(variant.resolution.height))",
                )
            })
            Button("Remove Variants") { confirmingRemoveVariants = true }
                .alert("Remove Variants", isPresented: $confirmingRemoveVariants) {
                    Button("Remove", role: .destructive) { manager.removeVariants(entryID: entry.id) }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    let rates = variants.map { String(localized: "\($0.fps) fps") }
                    Text("Deletes the \(rates.formatted(.list(type: .and))) copies.")
                }
        } else {
            Menu("Create Variants") {
                ForEach(OptimizationPreset.allCases) { preset in
                    Button {
                        manager.optimizeVideo(entryID: entry.id, preset: preset)
                    } label: {
                        Text(preset.title)
                        Text(preset.description)
                    }
                }
            }
            .fixedSize()
            .disabled(entry.resolution == .zero || manager.isOptimizing)
        }
    }
}

/// The selected video, playing muted on a loop over its poster frame. A click opens it
/// in Quick Look.
private struct VideoPreview: View {
    let url: URL
    let poster: URL?
    let revision: Int

    @Environment(LibraryStore.self) private var store
    @State private var image: NSImage?
    @State private var player: LoopingPlayer?

    private struct Key: Equatable {
        let url: URL
        let revision: Int
    }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.quaternary)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
            }
            if let player {
                PlayerLayerView(player: player.player)
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: InspectorMetrics.previewRadius, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { store.toggleQuickLook() }
        .help("Click to open in Quick Look")
        .accessibilityLabel("Preview")
        .accessibilityAddTraits(.isButton)
        .task(id: Key(url: url, revision: revision)) {
            player?.stop()
            player = nil
            image = ThumbnailCache.cached(poster)
            if image == nil {
                image = await ThumbnailCache.image(at: poster)
            }
            guard !Task.isCancelled else { return }
            player = LoopingPlayer(url: url)
        }
        .onDisappear {
            player?.stop()
            player = nil
        }
    }
}

/// The video's name: a label that becomes a text field when clicked. A resident text
/// field would take the window's first responder and sit in editing mode.
private struct InspectorNameField: View {
    let entryID: String
    let name: String

    @State private var draft = ""
    @State private var isEditing = false
    @State private var isHovered = false
    @FocusState private var isFocused: Bool

    var body: some View {
        Group {
            if isEditing {
                TextField("Name", text: $draft)
                    .textFieldStyle(.plain)
                    .focused($isFocused)
                    .onSubmit { finish(commit: true) }
                    .onExitCommand { finish(commit: false) }
                    .onChange(of: isFocused) { _, focused in
                        if !focused {
                            finish(commit: true)
                        }
                    }
                    .task { isFocused = true }
            } else {
                Text(verbatim: name)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        draft = name
                        isEditing = true
                    }
                    .help("Click to rename — the name also shows in the System Settings wallpaper picker")
            }
        }
        .font(.headline)
        .padding(.vertical, 2)
        .padding(.horizontal, 5)
        .background(
            isEditing || isHovered ? AnyShapeStyle(.quinary) : AnyShapeStyle(.clear),
            in: RoundedRectangle(cornerRadius: 5, style: .continuous),
        )
        .padding(.horizontal, -5)
        .onHover { isHovered = $0 }
        .onChange(of: entryID) { isEditing = false }
    }

    private func finish(commit: Bool) {
        guard isEditing else { return }
        isEditing = false
        guard commit else { return }
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != name else { return }
        VideoDeploymentService.renameEntry(entryID: entryID, to: trimmed)
    }
}

// MARK: - Wallpaper Engine download

/// One Wallpaper Engine download: its video once made, or its Workshop preview before;
/// where it stands, the one action that offers, what the video leaves out, and its facts.
struct DownloadInspector: View {
    let item: WorkshopItem

    @Environment(LibraryStore.self) private var store
    @Environment(WorkshopLibrary.self) private var workshop

    var body: some View {
        let status = workshop.status(of: item)
        let video = store.video(for: item)
        ScrollView {
            VStack(alignment: .leading, spacing: InspectorMetrics.sectionSpacing) {
                if let video {
                    VideoPreview(
                        url: VideoDeploymentService.videoURL(for: video),
                        poster: VideoDeploymentService.thumbnailURL(for: video.id),
                        revision: store.revision,
                    )
                } else {
                    DownloadPreview(url: item.preview, placeholder: item.kind.symbol, isDimmed: status.isUnsupported)
                }
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: item.title)
                            .font(.headline)
                            .lineLimit(3)
                        statusLine(status)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    action(status)
                }
                if let note {
                    Text(verbatim: note)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                InfoRows(rows: facts(video: video))
            }
            .inspectorPadding()
        }
    }

    @ViewBuilder
    private func statusLine(_ status: WorkshopLibrary.ItemStatus) -> some View {
        switch status {
        case let .rendering(progress, phase):
            ProgressView(value: progress) {
                Text(verbatim: phase.isEmpty ? String(localized: "Starting…") : phase)
            }
        case .queued:
            Text("Waiting for the videos ahead of it.")
                .foregroundStyle(.secondary)
        case .outdated:
            Text("The author has updated this wallpaper since. Make the video again to get the changes.")
                .foregroundStyle(.orange)
        case let .failed(reason):
            Text(verbatim: reason)
                .foregroundStyle(.red)
        case let .unsupported(reason):
            Label {
                Text(verbatim: reason)
            } icon: {
                Image(systemName: "nosign")
            }
        case .available, .made:
            EmptyView()
        }
    }

    @ViewBuilder
    private func action(_ status: WorkshopLibrary.ItemStatus) -> some View {
        switch status {
        case .rendering, .queued:
            Button("Stop Making Videos") { workshop.cancelAll() }
        case let .made(entryID):
            Button("Show in Library") { store.reveal(videoID: entryID) }
        case .outdated:
            Button("Make Video Again…") { store.requestMakeVideos([item.id]) }
        case .available, .failed:
            Button("Make Video…") { store.requestMakeVideos([item.id]) }
        case .unsupported:
            EmptyView()
        }
    }

    /// What the video leaves out, in one sentence: scene features Phosphene skips, effects
    /// whose shader did not translate, and an audio visualizer.
    private var note: String? {
        var parts: [String] = []
        if case let .partial(omissions) = workshop.assessments[item.id] {
            parts += omissions
        }
        if let record = workshop.records[item.id]?.record {
            parts += record.omissions.filter { $0.hasPrefix("the ") }
            if record.omissions.contains("audio visualizer") {
                parts.append(String(localized: "the audio visualizer"))
            }
        }
        guard !parts.isEmpty else { return nil }
        return String(localized: "The video leaves out \(parts.formatted(.list(type: .and))).")
    }

    /// The download's facts; once it has a video, the video's facts take the place of the
    /// download's size.
    private func facts(video: VideoDeploymentService.EntryInfo?) -> [InfoRow] {
        var rows = [InfoRow(label: String(localized: "Type"), value: item.kind.name)]
        if let video {
            rows += videoFacts(video)
        } else {
            let size = ByteCountFormatter.string(fromByteCount: item.sizeOnDisk, countStyle: .file)
            rows.append(InfoRow(label: String(localized: "Size"), value: size))
        }
        if let rating = item.contentRating, !rating.isEmpty {
            rows.append(InfoRow(label: String(localized: "Rating"), value: rating))
        }
        let updated = item.modified.formatted(date: .abbreviated, time: .omitted)
        rows.append(InfoRow(label: String(localized: "Updated"), value: updated))
        return rows
    }

    private func videoFacts(_ video: VideoDeploymentService.EntryInfo) -> [InfoRow] {
        var rows: [InfoRow] = []
        if video.resolution != .zero {
            let size = "\(Int(video.resolution.width)) × \(Int(video.resolution.height))"
            rows.append(InfoRow(label: String(localized: "Resolution"), value: size))
        }
        if video.fps > 0 {
            rows.append(InfoRow(label: String(localized: "Frame Rate"), value: String(localized: "\(Int(video.fps.rounded())) fps")))
        }
        let record = workshop.records[item.id]?.record
        if let record, record.settings != nil, record.loopDuration > 0 {
            let loop = Duration.seconds(record.loopDuration).formatted(.units(allowed: [.seconds], width: .abbreviated))
            let value = record.seamless ? String(localized: "\(loop), seamless") : String(localized: "\(loop), crossfade")
            rows.append(InfoRow(label: String(localized: "Loop"), value: value))
        }
        if let fileSize = store.fileSize(ofVideo: video.id) {
            let size = ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
            rows.append(InfoRow(label: String(localized: "Size"), value: size))
        }
        if let record {
            rows.append(InfoRow(label: String(localized: "Made"), value: record.renderedAt.formatted(date: .abbreviated, time: .omitted)))
        }
        return rows
    }
}

/// A download's Workshop preview, animated when it is a GIF, at no more than one image
/// pixel per screen pixel. A click opens it in Quick Look.
private struct DownloadPreview: View {
    let url: URL?
    let placeholder: String
    let isDimmed: Bool

    @Environment(LibraryStore.self) private var store
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                ActualSizeFrame(pixelSize: image.pixelSize) {
                    AnimatedImageView(image: image)
                }
            } else {
                Rectangle()
                    .fill(.quaternary)
                Image(systemName: placeholder)
                    .font(.title)
                    .foregroundStyle(.tertiary)
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .unsupportedDimming(isDimmed)
        .clipShape(RoundedRectangle(cornerRadius: InspectorMetrics.previewRadius, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { store.toggleQuickLook() }
        .help("Click to open in Quick Look")
        .accessibilityLabel("Preview")
        .accessibilityAddTraits(.isButton)
        .task(id: url) {
            image = nil
            guard let url else { return }
            let loaded = await PreviewImage.animatedImage(at: url)
            guard !Task.isCancelled else { return }
            image = loaded
        }
    }
}
