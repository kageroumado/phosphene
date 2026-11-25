import AVFoundation
import CoreVideo
import SwiftUI
import VideoToolbox

/// The inspector column: what is selected in the current section.
struct LibraryInspector: View {
    @Environment(LibraryStore.self) private var store
    @Environment(CatalogStore.self) private var catalog

    var body: some View {
        switch store.section.content {
        case .videos:
            let selected = store.selectedVideos
            if selected.count == 1, let entry = selected.first {
                VideoInspector(entry: entry)
                    .id(entry.id)
            } else if selected.count > 1 {
                SelectionSummary(count: selected.count, detail: nil)
            } else {
                emptySelection(Text("Select a video to view its details."))
            }
        case .downloads:
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
        case .catalog:
            if let item = catalog.selectedItem {
                CatalogInspector(item: item)
            } else {
                emptySelection(Text("Select a wallpaper to view its details."))
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
    let resolution: CGSize
    let hdrTransfer: String?

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
        let dimensions = CMVideoFormatDescriptionGetDimensions(description)
        let transfer = CMFormatDescriptionGetExtension(
            description, extensionKey: kCMFormatDescriptionExtension_TransferFunction,
        ) as? String
        let hdrTransfer: String? = if transfer == kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String {
            String(localized: "HDR (PQ)")
        } else if transfer == kCVImageBufferTransferFunction_ITU_R_2100_HLG as String {
            String(localized: "HDR (HLG)")
        } else {
            nil
        }
        return VideoCodec(
            label: label, isHardwareDecoded: VTIsHardwareDecodeSupported(code),
            resolution: CGSize(width: Int(dimensions.width), height: Int(dimensions.height)), hdrTransfer: hdrTransfer,
        )
    }

    private static func fourCharacterCode(_ code: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        return String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? "—"
    }
}

/// A selected video with its preview, names, technical details and optimization controls.
struct VideoInspector: View {
    let entry: VideoDeploymentService.EntryInfo

    @Environment(PhospheneManager.self) private var manager
    @Environment(LibraryStore.self) private var store
    @State private var inspection: Inspection?
    @State private var detailsExpanded = true

    private var pair: VideoPairSelection? {
        store.pairs[entry.id]
    }

    private var target: VideoOptimizationTarget {
        VideoOptimizationTarget(entry: entry, pair: pair)
    }

    private var isWorkingOnThis: Bool {
        manager.isOptimizing && manager.optimizingEntryID == target.id
    }

    private var isConvertingThis: Bool {
        isWorkingOnThis && manager.isConverting
    }

    /// The library revision also catches a file replacement under the same filename.
    private struct FileKey: Equatable {
        let filename: String
        let revision: Int
    }

    private struct Inspection {
        let key: FileKey
        let codec: VideoCodec?
        let validation: AppearancePair.Validation?
    }

    private var displaySelections: [WallpaperPrefsService.WallpaperSelection] {
        manager.prefsService.selections.filter {
            $0.videoID == entry.id || pair?.saved?.contains($0.videoID) == true
        }
    }

    var body: some View {
        let key = FileKey(filename: entry.filename, revision: store.revision)
        let inspected = inspection?.key == key ? inspection : nil
        Form {
            Section {
                VStack(spacing: 8) {
                    if !displaySelections.isEmpty {
                        InspectorDisplayStrip(selections: displaySelections)
                    }
                    if let pair, let record = pair.saved {
                        PairComparisonView(selection: pair, swapped: record.swapped)
                            .aspectRatio(16 / 9, contentMode: .fit)
                            .clipShape(.rect(cornerRadius: InspectorMetrics.previewRadius))
                            .id(store.revision)
                    } else {
                        VideoPreview(
                            url: VideoDeploymentService.videoURL(for: entry),
                            poster: VideoDeploymentService.thumbnailURL(for: entry.id),
                            revision: store.revision,
                        )
                    }
                }
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)

            Section("General") {
                LabeledContent("Name") {
                    InspectorNameField(label: "Name", name: entry.name) { store.renameVideo(entryID: entry.id, to: $0) }
                }
                LibraryVideoActions(store: store, ids: [entry.id]).useAsWallpaper
            }
            if let pair, let record = pair.saved {
                Section("Appearance") {
                    memberField("Light", member: pair.entry(light: true, swapped: record.swapped))
                    memberField("Dark", member: pair.entry(light: false, swapped: record.swapped))
                }
            }
            if isConvertingThis || inspected?.codec?.isHardwareDecoded == false {
                Section {
                    softwareDecodeNotice(inspected?.codec?.label)
                }
            }
            Section("Video Details", isExpanded: $detailsExpanded) {
                if pair != nil, inspected != nil, inspected?.validation == nil {
                    Text("Shared video details are unavailable because a source file is missing or has changed.")
                        .foregroundStyle(.secondary)
                }
                ForEach(facts(inspection: inspected)) { row in
                    LabeledContent {
                        Text(verbatim: row.value)
                            .multilineTextAlignment(.trailing)
                            .textSelection(.enabled)
                    } label: {
                        Text(verbatim: row.label)
                    }
                }
            }
            Section("Optimization") {
                optimization
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .task(id: key) {
            let url = VideoDeploymentService.videoURL(for: entry)
            let validation = pair.flatMap { pair -> AppearancePair.Validation? in
                guard let record = pair.saved, record.validation.version == 1, record.validation.frameCount > 0,
                      record.validation.frameTicks > 0, record.validation.timescale > 0,
                      let first = pair.previewSources.first, let second = pair.previewSources.second,
                      FileIdentity(of: first) == record.validation.original,
                      FileIdentity(of: second) == record.validation.alternate else { return nil }
                return record.validation
            }
            let codec = await VideoCodec.load(from: url)
            guard !Task.isCancelled else { return }
            inspection = Inspection(key: key, codec: codec, validation: validation)
        }
    }

    private func memberField(_ label: LocalizedStringKey, member: VideoDeploymentService.EntryInfo?) -> some View {
        LabeledContent(label) {
            if let member {
                InspectorNameField(label: label, name: member.name) {
                    store.renameVideo(entryID: entry.id, to: $0, memberID: member.id)
                }
                .id(member.id)
            } else {
                Text("File unavailable")
            }
        }
    }

    private func facts(inspection: Inspection?) -> [InfoRow] {
        var rows: [InfoRow] = []
        let validation = inspection?.validation
        if pair == nil || validation != nil {
            let size = pair == nil ? entry.resolution : inspection?.codec?.resolution ?? entry.resolution
            if size.width > 0, size.height > 0, size.width.isFinite, size.height.isFinite {
                let format = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0)).grouping(.never)
                let resolution = "\(Double(size.width).formatted(format)) × \(Double(size.height).formatted(format))"
                rows.append(InfoRow(label: String(localized: "Resolution"), value: resolution))
            }
            let fps = validation.map { Double($0.timescale) / Double($0.frameTicks) } ?? entry.fps
            if fps.isFinite, fps > 0 {
                let rate = fps.formatted(.number.precision(.fractionLength(0 ... 3)))
                rows.append(InfoRow(label: String(localized: "Frame Rate"), value: String(localized: "\(rate) fps")))
            }
            let duration = validation.map { Double($0.frameCount) / fps } ?? entry.duration
            if duration.isFinite, duration > 0 {
                rows.append(InfoRow(label: String(localized: "Duration"), value: Duration.seconds(duration).formatted(.time(pattern: .minuteSecond))))
            }
            if let codec = inspection?.codec {
                rows.append(InfoRow(label: String(localized: "Codec"), value: codec.label))
            }
            let range = inspection?.codec?.hdrTransfer ?? entry.sourceIsHDR.map { $0 ? String(localized: "HDR") : String(localized: "SDR") }
            if let range {
                rows.append(InfoRow(label: String(localized: "Dynamic Range"), value: range))
            }
        }
        let size = pair?.members.reduce(0) { $0 + (store.fileSize(ofVideo: $1.id) ?? 0) } ?? store.fileSize(ofVideo: entry.id)
        if let size {
            rows.append(InfoRow(label: String(localized: "Size"), value: ByteCountFormatter.string(fromByteCount: size, countStyle: .file)))
        }
        let added = entry.dateAdded.formatted(date: .abbreviated, time: .omitted)
        rows.append(InfoRow(label: String(localized: "Added"), value: added))
        return rows
    }

    @ViewBuilder
    private func softwareDecodeNotice(_ codecLabel: String?) -> some View {
        if let codecLabel {
            Label {
                Text("This Mac decodes \(codecLabel) in software, so playback can stutter.")
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
            }
        }
        if isConvertingThis {
            ProgressView(value: manager.optimizationProgress) { Text("Converting…") }
            Button("Cancel", action: manager.cancelOptimization)
        } else if pair == nil {
            Button("Convert to HEVC") { manager.convertToHEVC(entryID: entry.id) }
                .disabled(manager.isOptimizing)
        }
    }

    @ViewBuilder
    private var optimization: some View {
        if isWorkingOnThis, !manager.isConverting {
            ProgressView(value: manager.optimizationProgress) { Text("Optimizing…") }
            Button("Cancel", action: manager.cancelOptimization)
        } else if !target.tiers.isEmpty {
            if entry.sourceIsHDR == true {
                Text(target.convertedToSDR ? "Optimized · SDR" : "Optimized · HDR")
            }
            ForEach(target.tiers, id: \.fps) { variant in
                LabeledContent("\(variant.fps) fps") {
                    Text("\(Int(variant.resolution.width)) × \(Int(variant.resolution.height))")
                }
            }
        } else {
            let unavailable = target.eligibilityError
            Menu {
                CreateVideoVariantActions(store: store, target: target)
            } label: {
                Text(target.storedTiers.isEmpty ? "Create Variants" : "Regenerate Variants")
            }
            .disabled(unavailable != nil || manager.isOptimizing)
            if let unavailable {
                Text(unavailable.localizedDescription)
                    .foregroundStyle(.secondary)
            }
        }
        if !target.storedTiers.isEmpty {
            Button("Remove Variants…") { store.pendingVariantRemoval = target }
                .disabled(isWorkingOnThis)
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
    let label: LocalizedStringKey
    let name: String
    let save: (String) -> Void

    @State private var draft = ""
    @State private var isEditing = false
    @State private var isHovered = false
    @FocusState private var isFocused: Bool

    var body: some View {
        Group {
            if isEditing {
                TextField(label, text: $draft)
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
                Button {
                    draft = name
                    isEditing = true
                } label: {
                    Text(verbatim: name)
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                }
                .buttonStyle(.plain)
                .help("Click to rename")
            }
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 5)
        .background(
            isEditing || isHovered ? AnyShapeStyle(.quinary) : AnyShapeStyle(.clear),
            in: RoundedRectangle(cornerRadius: 5, style: .continuous),
        )
        .padding(.horizontal, -5)
        .onHover { isHovered = $0 }
        .onDisappear { finish(commit: true) }
    }

    private func finish(commit: Bool) {
        guard isEditing else { return }
        isEditing = false
        guard commit else { return }
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != name else { return }
        save(trimmed)
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

// MARK: - Workshop wallpaper

/// One wallpaper on the Steam Workshop: its preview, the way to get it, and its facts.
private struct CatalogInspector: View {
    let item: CatalogItem

    @Environment(LibraryStore.self) private var store
    @Environment(CatalogStore.self) private var catalog
    @Environment(WorkshopLibrary.self) private var workshop

    var body: some View {
        let status = catalog.status(of: item.id, downloaded: workshop.item(item.id) == nil ? [] : [item.id])
        let blocker = workshop.subscribeBlocker
        ScrollView {
            VStack(alignment: .leading, spacing: InspectorMetrics.sectionSpacing) {
                CatalogPreview(url: item.preview, placeholder: item.kind.symbol)
                VStack(alignment: .leading, spacing: 10) {
                    Text(verbatim: item.title)
                        .font(.headline)
                        .lineLimit(3)
                    action(status, blocker: blocker)
                }
                if status == .available, let blocker {
                    Text(Self.explanation(of: blocker))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                InfoRows(rows: facts)
                if status != .available || blocker == nil {
                    Button("Open Workshop Page") { workshop.openWorkshopPage(ofID: item.id) }
                        .buttonStyle(.link)
                }
            }
            .inspectorPadding()
        }
    }

    @ViewBuilder
    private func action(_ status: CatalogStore.Status, blocker: WorkshopLibrary.SubscribeBlocker?) -> some View {
        switch status {
        case .downloaded:
            Button("Show in All Wallpapers") { store.reveal(downloadID: item.id) }
        case .getting:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Steam is downloading it")
                    .foregroundStyle(.secondary)
            }
        case .available:
            if blocker == nil {
                Button("Get") { catalog.get(item.id) }
                    .buttonStyle(.borderedProminent)
                    .help("Subscribe on the Steam Workshop; Steam downloads the wallpaper")
            } else {
                Button("Open Workshop Page") { workshop.openWorkshopPage(ofID: item.id) }
            }
        }
    }

    private static func explanation(of blocker: WorkshopLibrary.SubscribeBlocker) -> LocalizedStringKey {
        switch blocker {
        case .sevofluraneMissing:
            "Phosphene gets wallpapers through Sevoflurane, which runs Windows Steam on your Mac."
        case .sevofluraneOutdated:
            "Update Sevoflurane to get wallpapers from here."
        case .wallpaperEngineMissing:
            "Install Wallpaper Engine in Sevoflurane’s Steam to get wallpapers from here."
        }
    }

    private var facts: [InfoRow] {
        [
            InfoRow(label: String(localized: "Type"), value: item.kind.name),
            InfoRow(
                label: String(localized: "Size"),
                value: ByteCountFormatter.string(fromByteCount: item.fileSize, countStyle: .file),
            ),
            InfoRow(label: String(localized: "Subscribers"), value: item.subscriptions.formatted()),
            InfoRow(
                label: String(localized: "Updated"), value: item.updated.formatted(date: .abbreviated, time: .omitted),
            ),
        ]
    }
}

/// A Workshop wallpaper's preview, square as authors upload them.
private struct CatalogPreview: View {
    let url: URL?
    let placeholder: String

    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Rectangle()
                    .fill(.black)
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Rectangle()
                    .fill(.quaternary)
                Image(systemName: placeholder)
                    .font(.title)
                    .foregroundStyle(.tertiary)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: InspectorMetrics.previewRadius, style: .continuous))
        .accessibilityLabel("Preview")
        .task(id: url) {
            image = ThumbnailCache.cached(url)
            if image == nil {
                image = await ThumbnailCache.image(at: url)
            }
        }
    }
}
