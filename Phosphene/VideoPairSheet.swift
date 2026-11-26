import AppKit
import Foundation
import SwiftUI

nonisolated struct VideoPairSelection: Identifiable, Sendable {
    typealias Entry = VideoDeploymentService.EntryInfo
    let first: Entry?
    let second: Entry?
    let saved: AppearancePair?

    var members: [Entry] {
        [first, second].compactMap(\.self)
    }

    var id: String {
        saved?.owner ?? first?.id ?? ""
    }

    var actionTitle: LocalizedStringKey {
        saved == nil ? "Create Pair…" : "Split Pair…"
    }

    func entry(light: Bool, swapped: Bool) -> Entry? {
        light != swapped ? first : second
    }

    struct PreviewSources: Equatable, Sendable {
        let first: URL?
        let second: URL?
    }

    @MainActor
    var previewSources: PreviewSources {
        PreviewSources(
            first: first.map(VideoDeploymentService.videoURL),
            second: second.map(VideoDeploymentService.videoURL),
        )
    }

    @MainActor
    func commit(validation: AppearancePair.Validation?, swapped: Bool) throws -> Set<String> {
        let directory = VideoDeploymentService.videosFolderURL
        if let saved {
            try saved.edit(in: directory, split: true)
            return [saved.owner, saved.counterpart]
        }
        guard let first, let second, let validation else { throw PairIssue.changed }
        let pair = AppearancePair(owner: first.id, counterpart: second.id, swapped: swapped, validation: validation, name: first.name)
        try pair.merge(in: directory) {
            let entries = VideoDeploymentService.listEntries()
            guard let a = entries.first(where: { $0.id == first.id && $0.filename == first.filename }),
                  let b = entries.first(where: { $0.id == second.id && $0.filename == second.filename }) else { throw PairIssue.changed }
            return (VideoDeploymentService.videoURL(for: a), VideoDeploymentService.videoURL(for: b))
        }
        return [first.id]
    }
}

/// Both halves use the same full-size image rectangle in physical screen coordinates.
struct VideoPairPreview: View {
    let selection: VideoPairSelection
    let swapped: Bool
    var fraction: CGFloat = 0.5
    var isPlaying: Bool = false
    var onPlaybackEnded: (() -> Void)?
    @State private var playback: (sources: VideoPairSelection.PreviewSources, session: PairPlayback)?

    var body: some View {
        let sources = selection.previewSources
        let activeSources = isPlaying ? sources : nil
        let session = playback.flatMap { $0.sources == activeSources ? $0.session : nil }
        GeometryReader { geometry in
            let size = geometry.size
            let posterSplit = size.width * fraction
            let left = CGRect(x: 0, y: 0, width: posterSplit, height: size.height)
            let right = CGRect(x: posterSplit, y: 0, width: size.width - posterSplit, height: size.height)
            ZStack {
                poster(videoID: selection.first?.id, url: sources.first, size: size, clip: swapped ? right : left)
                poster(videoID: selection.second?.id, url: sources.second, size: size, clip: swapped ? left : right)
                if let session {
                    PairPlayerLayerView(playback: session, swapped: swapped, fraction: fraction)
                        .frame(width: size.width, height: size.height)
                        .transition(.identity)
                        .allowsHitTesting(false)
                }
                Rectangle().fill(.white.opacity(0.85))
                    .frame(width: 1, height: size.height)
                    .position(x: size.width * fraction, y: size.height / 2)
            }
            .environment(\.layoutDirection, .leftToRight)
        }
        .task(id: activeSources) {
            guard let activeSources, let first = activeSources.first, let second = activeSources.second,
                  !Task.isCancelled else { return }
            let session = PairPlayback(first: first, second: second)
            playback = (activeSources, session)
            await session.run()
            if playback?.session === session {
                playback = nil
                if !Task.isCancelled {
                    onPlaybackEnded?()
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Light appearance on the left, dark appearance on the right")
    }

    private func poster(videoID: String?, url: URL?, size: CGSize, clip: CGRect) -> some View {
        PairPoster(videoID: videoID, videoURL: url)
            .id(url)
            .frame(width: size.width, height: size.height)
            .mask { Path(clip) }
    }
}

private struct PairPoster: View {
    let videoID: String?
    let videoURL: URL?
    @State private var image: NSImage?

    var body: some View {
        Rectangle().fill(.quaternary)
            .overlay {
                if let image {
                    Image(nsImage: image).resizable().scaledToFit()
                } else {
                    Image(systemName: "film").foregroundStyle(.secondary)
                }
            }
            .task(id: videoID) {
                guard let videoID else { return }
                var poster = VideoDeploymentService.thumbnailURL(for: videoID)
                if poster == nil, let videoURL {
                    await VideoDeploymentService.generateThumbnail(for: videoURL, in: videoURL.deletingLastPathComponent())
                    poster = VideoDeploymentService.thumbnailURL(for: videoID)
                }
                guard !Task.isCancelled else { return }
                image = await ThumbnailCache.image(at: poster)
            }
    }
}

struct VideoPairActionButtons: View {
    let pair: VideoPairSelection
    let store: LibraryStore

    var body: some View {
        Button { store.pairSheet = pair } label: {
            Label(pair.actionTitle, image: .lightDarkPair)
        }
        if pair.saved != nil, pair.members.count == 2 {
            Button("Swap Light and Dark", systemImage: "arrow.left.arrow.right") {
                store.swapAppearances(pair)
            }
        }
    }
}

struct VideoPairSheet: View {
    let selection: VideoPairSelection
    let completed: (Set<String>) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @State private var swapped = false
    @State private var validation: AppearancePair.Validation?
    @State private var failure: (any Error)?
    @State private var showsRequirements = false

    private var splitting: Bool {
        selection.saved != nil
    }
    private var rolesSwapped: Bool {
        selection.saved?.swapped ?? swapped
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(splitting ? "Split Light/Dark Pair" : "Create Light/Dark Pair")
                    .font(.title2.bold())
                Text(splitting ? "Both videos will appear separately in your library." : "Choose the light and dark versions of the same animation.")
                    .foregroundStyle(.secondary)
            }
            PairComparisonView(selection: selection, swapped: rolesSwapped)
                .controlSize(.extraLarge)
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(.rect(cornerRadius: 8))
            HStack(alignment: .top, spacing: 16) {
                role(light: true)
                if !splitting {
                    Button { swapped.toggle() } label: { Image(systemName: "arrow.left.arrow.right") }
                        .buttonBorderShape(.circle)
                        .help("Swap Light and Dark")
                        .accessibilityLabel("Swap Light and Dark")
                }
                role(light: false)
            }
            if let failure {
                Label { Text(failure.localizedDescription).fixedSize(horizontal: false, vertical: true) } icon: {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                }
            } else if !splitting {
                if validation == nil {
                    HStack { ProgressView().controlSize(.small); Text("Checking video compatibility…") }
                } else {
                    Label("Videos are compatible", systemImage: "checkmark.circle")
                }
            }
            HStack {
                if !splitting {
                    HelpLink { showsRequirements.toggle() }
                        .accessibilityLabel("Pairing Requirements")
                        .help("Pairing Requirements")
                        .popover(isPresented: $showsRequirements, arrowEdge: .top) {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Pairing Requirements").font(.headline)
                                Text("**Picture.** Match the resolution, orientation, codec settings, and color profile (SDR, HLG, or PQ).")
                                Text("**Timing.** Use one full-length, untrimmed video track in each file. Match the constant frame rate, frame count, and duration.")
                                Text("**Keyframes.** Start on a shared keyframe and align keyframes at least every half second. Use closed GOPs with B-frames turned off.")
                            }
                            .padding()
                            .frame(width: 320, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    if let issue = failure as? PairIssue, issue.isCompatibilityIssue,
                       let light = selection.entry(light: true, swapped: rolesSwapped),
                       let dark = selection.entry(light: false, swapped: rolesSwapped) {
                        Button("Open Pair Converter…") {
                            dismiss()
                            openWindow(value: PairConverterRequest.library(lightID: light.id, darkID: dark.id, draftID: UUID()))
                        }
                    }
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(splitting ? "Split Pair" : "Create Pair") {
                    do {
                        let ids = try selection.commit(validation: validation, swapped: swapped)
                        VideoDeploymentService.notifyExtensionLibraryChanged()
                        completed(ids)
                        dismiss()
                    } catch { failure = error }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(failure != nil || (!splitting && validation == nil))
            }
            .padding(.top, 4)
        }
        .padding(22)
        .frame(width: 500)
        .task {
            guard !splitting, let first = selection.first, let second = selection.second else { return }
            do {
                validation = try await PairEligibility.validate(VideoDeploymentService.videoURL(for: first), VideoDeploymentService.videoURL(for: second))
            } catch is CancellationError {
                return
            } catch { failure = error }
        }
    }

    private func role(light: Bool) -> some View {
        let name = selection.entry(light: light, swapped: rolesSwapped)?.name ?? String(localized: "File unavailable")
        return VStack(alignment: .leading, spacing: 4) {
            Label(light ? "Light" : "Dark", systemImage: light ? "sun.max" : "moon")
                .font(.headline)
            Text(name)
                .lineLimit(2).truncationMode(.middle).foregroundStyle(.secondary)
                .help(name)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
