import AppKit
import SwiftUI

/// Workshop previews, decoded within bounds: they are downloads from strangers and
/// may claim any size or frame count.
nonisolated enum PreviewImage {
    /// Largest picture decoded whole, for animation.
    static let maxAnimatedPixels = 4_096
    static let maxAnimatedFrames = 300
    /// Largest picture a thumbnail is made from.
    static let maxSourcePixels = 8_192

    /// A still of at most `maxPixels` on a side.
    static func thumbnail(at url: URL, maxPixels: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              fits(source, within: maxSourcePixels)
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    /// The whole file, for `NSImageView` to animate, when every frame fits in memory;
    /// otherwise a still.
    static func animated(at url: URL) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) <= maxAnimatedFrames, fits(source, within: maxAnimatedPixels),
              let image = NSImage(contentsOf: url)
        else { return thumbnail(at: url, maxPixels: 1_280) }
        return image
    }

    private static func fits(_ source: CGImageSource, within limit: Int) -> Bool {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return false }
        return (1 ... limit).contains(width) && (1 ... limit).contains(height)
    }
}

/// An image that plays when it is an animated GIF.
struct AnimatedImageView: NSViewRepresentable {
    let url: URL

    final class Coordinator {
        var shown: URL?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.animates = true
        view.imageScaling = .scaleProportionallyUpOrDown
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: NSImageView, context: Context) {
        guard context.coordinator.shown != url else { return }
        context.coordinator.shown = url
        view.image = PreviewImage.animated(at: url)
    }
}

// MARK: - Tile

struct WorkshopTileView: View {
    let item: WorkshopItem
    let status: WorkshopLibrary.ItemStatus
    let isStaged: Bool
    let onTap: () -> Void

    @State private var isHovered = false
    @State private var image: NSImage?

    private var isUnsupported: Bool {
        status.isUnsupported
    }

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 7) {
                thumbnail
                Text(item.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .top)
                    .foregroundStyle(isUnsupported ? .secondary : .primary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.title)
        .accessibilityValue(isStaged ? Text("Selected") : Text(verbatim: ""))
        .accessibilityAddTraits(isStaged ? .isSelected : [])
        .onHover { isHovered = $0 }
        .task(id: item.preview) {
            image = ThumbnailCache.cached(item.preview)
            if image == nil {
                image = await ThumbnailCache.image(at: item.preview)
            }
        }
        .help(helpText)
    }

    private var thumbnail: some View {
        Color.clear
            .overlay {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Rectangle()
                        .fill(.quaternary)
                        .overlay {
                            Image(systemName: kindSymbol)
                                .font(.system(size: 24))
                                .foregroundStyle(.tertiary)
                        }
                }
            }
            .saturation(isUnsupported ? 0.2 : 1)
            .opacity(isUnsupported ? 0.55 : 1)
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(alignment: .topTrailing) { selectionMark }
            .overlay(alignment: .bottomLeading) { kindChip }
            .overlay(alignment: .bottomTrailing) { statusBadge }
            .overlay {
                if isStaged {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(.tint, lineWidth: 2.5)
                        .padding(-3)
                }
            }
            .shadow(color: .black.opacity(isHovered ? 0.18 : 0.08), radius: isHovered ? 8 : 4, y: 2)
            .animation(.easeInOut(duration: 0.15), value: isHovered)
    }

    @ViewBuilder
    private var selectionMark: some View {
        if isStaged {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 18))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, Color.accentColor)
                .padding(7)
        } else if isHovered, !isUnsupported, status != .queued {
            Image(systemName: "circle")
                .font(.system(size: 18))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.4), radius: 2)
                .padding(7)
        }
    }

    private var kindSymbol: String {
        switch item.kind {
        case .video: "film"
        case .scene: "square.stack.3d.up"
        case .web: "globe"
        case .application: "app.dashed"
        case .unknown: "questionmark.square.dashed"
        }
    }

    private var kindChip: some View {
        Image(systemName: kindSymbol)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 20, height: 20)
            .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .padding(7)
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch status {
        case .made:
            // Neutral, so it never reads as the selection checkmark.
            badge("film", fill: AnyShapeStyle(.black.opacity(0.55)))
        case .outdated:
            badge("arrow.triangle.2.circlepath", fill: AnyShapeStyle(.orange))
        case .failed:
            badge("exclamationmark", fill: AnyShapeStyle(.yellow))
        case .unsupported:
            badge("nosign", fill: AnyShapeStyle(.gray))
        case .queued:
            pill { Text("Waiting") }
        case let .rendering(progress, _):
            pill {
                ProgressView(value: progress)
                    .progressViewStyle(.circular)
                    .controlSize(.mini)
                    .tint(.white)
                Text(progress, format: .percent.precision(.fractionLength(0)))
            }
        case .available:
            EmptyView()
        }
    }

    private func badge(_ symbol: String, fill: AnyShapeStyle) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 20, height: 20)
            .background(fill, in: Circle())
            .padding(7)
    }

    private func pill(@ViewBuilder _ content: () -> some View) -> some View {
        HStack(spacing: 5, content: content)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.black.opacity(0.55), in: Capsule())
            .padding(7)
    }

    private var helpText: String {
        switch status {
        case .made: String(localized: "In your library")
        case .queued: String(localized: "Waiting to be made")
        case .rendering: String(localized: "Making its video")
        default: status.explanation ?? item.title
        }
    }
}

// MARK: - Make Videos sheet

struct MakeVideoSheet: View {
    @Bindable var library: WorkshopLibrary
    @Environment(\.dismiss) private var dismiss

    private struct SizeOption: Hashable {
        let width: Int
        let height: Int
        let label: String
    }

    private var sizeOptions: [SizeOption] {
        var options: [SizeOption] = []
        if let screen = NSScreen.screens.max(by: { $0.frame.width < $1.frame.width }) {
            let width = Int(screen.frame.width * screen.backingScaleFactor)
            let height = Int(screen.frame.height * screen.backingScaleFactor)
            options.append(SizeOption(
                width: width, height: height,
                label: String(localized: "This Mac’s display (\(width) × \(height))"),
            ))
        }
        options += [
            SizeOption(width: 3_840, height: 2_160, label: "4K (3840 × 2160)"),
            SizeOption(width: 2_560, height: 1_440, label: "1440p (2560 × 1440)"),
            SizeOption(width: 1_920, height: 1_080, label: "1080p (1920 × 1080)"),
        ]
        var seen = Set<String>()
        return options.filter { seen.insert("\($0.width)x\($0.height)").inserted }
    }

    private var stagedItems: [WorkshopItem] {
        library.items.filter { library.staged.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Make Videos")
                .font(.system(size: 15, weight: .semibold))
            Text("Each wallpaper becomes a looping video in your library. A scene takes about a minute.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Form {
                Picker("Size", selection: sizeBinding) {
                    ForEach(sizeOptions, id: \.self) { option in
                        Text(option.label).tag(option)
                    }
                }
                Picker("Frame rate", selection: $library.settings.fps) {
                    Text("30 fps").tag(30)
                    Text("60 fps").tag(60)
                }
                Picker("Format", selection: $library.settings.codec) {
                    Text("HEVC").tag(WEBakeSettings.Codec.hevc)
                    Text("H.264").tag(WEBakeSettings.Codec.h264)
                }
                Picker("Loop", selection: $library.settings.loopLength) {
                    Text("Automatic").tag(Double?.none)
                    Text("10 seconds").tag(Double?.some(10))
                    Text("20 seconds").tag(Double?.some(20))
                    Text("30 seconds").tag(Double?.some(30))
                    Text("60 seconds").tag(Double?.some(60))
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(height: 196)

            Text("HEVC files are about a quarter smaller than H.264. 60 fps doubles the file size.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            let partial = stagedItems.compactMap { item -> String? in
                guard case let .partial(omissions) = library.assessments[item.id] else { return nil }
                return "\(item.title): \(omissions.formatted(.list(type: .and)))"
            }
            if !partial.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Left out of the videos")
                        .font(.system(size: 10.5, weight: .semibold))
                        .kerning(0.6)
                        .textCase(.uppercase)
                        .foregroundStyle(.tertiary)
                    ForEach(partial, id: \.self) { line in
                        Text(line)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(11)
                .background(.quinary, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    library.makeVideos()
                    dismiss()
                } label: {
                    Text(stagedItems.count == 1 ? "Make Video" : "Make \(stagedItems.count) Videos")
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(stagedItems.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private var sizeBinding: Binding<SizeOption> {
        Binding(
            get: {
                sizeOptions.first { $0.width == library.settings.width && $0.height == library.settings.height }
                    ?? sizeOptions[0]
            },
            set: {
                library.settings.width = $0.width
                library.settings.height = $0.height
            },
        )
    }
}

// MARK: - Inspector

struct WorkshopInspectorView: View {
    let item: WorkshopItem
    @Bindable var library: WorkshopLibrary
    /// Select the library video made from this item.
    var onShowVideo: (String) -> Void

    private var status: WorkshopLibrary.ItemStatus {
        library.status(of: item)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                preview
                Text(item.title)
                    .font(.system(size: 13, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity)
                chips
                statusCard
                notes
                primaryButton
                HStack(spacing: 8) {
                    if let page = item.workshopPageURL {
                        Button {
                            NSWorkspace.shared.open(page)
                        } label: {
                            Text("Workshop Page")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([item.folder])
                    } label: {
                        Text("Show in Finder")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.bordered)
            }
            .padding(14)
        }
    }

    private var preview: some View {
        ZStack {
            Rectangle().fill(.black.opacity(0.85))
            if let url = item.preview {
                AnimatedImageView(url: url)
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private var chips: some View {
        HStack(spacing: 5) {
            chip(item.kind.name)
            chip(ByteCountFormatter.string(fromByteCount: item.sizeOnDisk, countStyle: .file))
            if let rating = item.contentRating, !rating.isEmpty {
                chip(rating)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.quinary, in: Capsule())
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Video")
                .font(.system(size: 10.5, weight: .semibold))
                .kerning(0.6)
                .textCase(.uppercase)
                .foregroundStyle(.tertiary)
            switch status {
            case let .rendering(progress, phase):
                ProgressView(value: progress) {
                    Text(phase.isEmpty ? String(localized: "Starting…") : phase)
                        .font(.system(size: 12, weight: .medium))
                }
            case .queued:
                Text("Waiting for the videos ahead of it.")
            case let .made(entryID), let .outdated(entryID):
                if let record = library.records[item.id]?.record {
                    Text(madeDescription(record))
                }
                if case .outdated = status {
                    Text("The author has updated this wallpaper since. Make the video again to get the changes.")
                        .foregroundStyle(.orange)
                }
                Button("Show in Library") { onShowVideo(entryID) }
                    .controlSize(.small)
            case let .failed(reason):
                Text(reason)
                    .foregroundStyle(.red)
            case let .unsupported(reason):
                Text(reason)
            case .available:
                Text("Not made yet.")
            }
        }
        .font(.system(size: 11.5))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func madeDescription(_ record: WorkshopRecord) -> String {
        let date = record.renderedAt.formatted(date: .abbreviated, time: .shortened)
        guard let settings = record.settings else { return String(localized: "Added on \(date), as it is.") }
        let loop = Duration.seconds(record.loopDuration).formatted(.units(allowed: [.seconds], width: .abbreviated))
        let kind = record.seamless
            ? String(localized: "a \(loop) seamless loop")
            : String(localized: "a \(loop) loop that crossfades into its start")
        let size = "\(String(settings.width)) × \(String(settings.height))"
        return String(localized: "Made on \(date): \(size), \(settings.fps) fps, \(kind).")
    }

    /// What the video leaves out: scene features Phosphene skips, then effects
    /// whose shader did not translate.
    private var noteLines: [String] {
        var lines: [String] = []
        if case let .partial(omissions) = library.assessments[item.id] {
            lines.append(String(localized: "The video leaves out \(omissions.formatted(.list(type: .and))), which need Wallpaper Engine running."))
        }
        if let record = library.records[item.id]?.record {
            let dropped = record.omissions.filter { $0.hasPrefix("the ") }
            if !dropped.isEmpty {
                lines.append(String(localized: "Drawn without \(dropped.formatted(.list(type: .and))), whose shader Phosphene couldn’t translate."))
            }
        }
        return lines
    }

    @ViewBuilder
    private var notes: some View {
        let lines = noteLines
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(lines, id: \.self) { Text($0) }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(11)
            .background(.quinary, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch status {
        case .rendering, .queued:
            Button(role: .destructive) {
                library.cancelAll()
            } label: {
                Text("Stop Making Videos")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        case .unsupported:
            EmptyView()
        case .made, .outdated:
            Button {
                library.makeVideos([item.id])
            } label: {
                Text("Make Video Again")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        default:
            Button {
                library.makeVideos([item.id])
            } label: {
                Text("Make Video")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
    }
}
