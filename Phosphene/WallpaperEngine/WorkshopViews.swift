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

// MARK: - Make Videos sheet

/// Names the wallpapers about to become videos and asks how to make them.
struct MakeVideosSheet: View {
    @Environment(LibraryStore.self) private var store
    @Environment(WorkshopLibrary.self) private var workshop
    @Environment(\.dismiss) private var dismiss

    private enum Metrics {
        static let width: CGFloat = 440
        static let rowHeight: CGFloat = 38
        static let visibleRows: CGFloat = 4.5
    }

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

    var body: some View {
        @Bindable var workshop = workshop
        let items = store.renderableSelection
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(items.count == 1 ? "Make Video" : "Make \(items.count) Videos")
                    .font(.headline)
                Text("Each wallpaper becomes a looping video in your library. A scene takes about a minute.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            wallpapers(items)

            Form {
                Picker("Size", selection: sizeBinding) {
                    ForEach(sizeOptions, id: \.self) { option in
                        Text(verbatim: option.label).tag(option)
                    }
                }
                Picker("Frame rate", selection: $workshop.settings.fps) {
                    Text("30 fps").tag(30)
                    Text("60 fps").tag(60)
                }
                Picker("Format", selection: $workshop.settings.codec) {
                    Text("HEVC").tag(WEBakeSettings.Codec.hevc)
                    Text("H.264").tag(WEBakeSettings.Codec.h264)
                }
                Picker("Loop", selection: $workshop.settings.loopLength) {
                    Text("Automatic").tag(Double?.none)
                    Text("10 seconds").tag(Double?.some(10))
                    Text("20 seconds").tag(Double?.some(20))
                    Text("30 seconds").tag(Double?.some(30))
                    Text("60 seconds").tag(Double?.some(60))
                }
            }
            .formStyle(.columns)

            Text("HEVC files are about a quarter smaller than H.264. 60 fps doubles the file size.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(items.count == 1 ? "Make Video" : "Make \(items.count) Videos") {
                    workshop.makeVideos(items.map(\.id))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(items.isEmpty)
            }
        }
        .padding(20)
        .frame(width: Metrics.width)
    }

    /// The wallpapers, each with what its video leaves out.
    private func wallpapers(_ items: [WorkshopItem]) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(items) { item in
                    HStack(spacing: 10) {
                        RowThumbnail(url: item.preview, placeholder: item.kind.symbol)
                        Text(verbatim: item.title)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        if case let .partial(omissions) = workshop.assessments[item.id] {
                            Text("Without \(omissions.formatted(.list(type: .and)))")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .padding(.horizontal, 10)
                    .frame(height: Metrics.rowHeight)
                    .overlay(alignment: .top) {
                        if item.id != items.first?.id {
                            Divider()
                                .padding(.leading, 10)
                        }
                    }
                }
            }
        }
        .frame(height: min(CGFloat(items.count), Metrics.visibleRows) * Metrics.rowHeight)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var sizeBinding: Binding<SizeOption> {
        Binding(
            get: {
                sizeOptions.first { $0.width == workshop.settings.width && $0.height == workshop.settings.height }
                    ?? sizeOptions[0]
            },
            set: {
                workshop.settings.width = $0.width
                workshop.settings.height = $0.height
            },
        )
    }
}
