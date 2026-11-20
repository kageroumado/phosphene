import AVFoundation
import SwiftUI

struct VideoInspectorView: View {
    let entry: VideoDeploymentService.EntryInfo
    let file: FileIdentity?
    let pair: VideoPairSelection?
    let alternateFile: FileIdentity?
    let manager: PhospheneManager

    @State private var playback: LoopingVideoPreview?
    @State private var isPlaying = false
    @State private var isHoveringPreview = false
    @Environment(\.appearsActive) private var appearsActive

    private var videoURL: URL {
        VideoDeploymentService.videoURL(for: entry)
    }

    private static let displayStripHeight: CGFloat = 36
    private static let sectionHeaderSpacing: CGFloat = 6

    private var displaySelections: [WallpaperPrefsService.WallpaperSelection] {
        manager.prefsService.selections.filter { $0.videoID == entry.id || pair?.saved?.contains($0.videoID) == true }
    }

    var body: some View {
        Form {
            Section {
                if let pair, let record = pair.saved {
                    PairComparisonView(selection: pair, swapped: record.swapped)
                        .controlSize(.extraLarge)
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .clipShape(.rect(cornerRadius: 9))
                } else {
                    previewSection
                }
            } header: {
                InspectorDisplayStrip(selections: displaySelections)
                    .frame(maxWidth: .infinity)
                    .frame(height: Self.displayStripHeight, alignment: .bottom)
                    .offset(y: Self.sectionHeaderSpacing - 2)
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)

            Section("General") {
                InspectorNameField(label: "Name", name: entry.name) { name in
                    saveName(name)
                }
                .id(pair?.saved?.counterpart)
            }
            if let pair, let record = pair.saved {
                Section("Appearance") {
                    memberField("Light", entry: pair.entry(light: true, swapped: record.swapped))
                    memberField("Dark", entry: pair.entry(light: false, swapped: record.swapped))
                }
            }
            VideoInspectorProperties(entry: entry, file: file, pair: pair, alternateFile: alternateFile)
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        // Keep the preview on the library grid's top edge while the display strip scrolls with it.
        .padding(.top, -(Self.displayStripHeight + Self.sectionHeaderSpacing))
        .onChange(of: videoURL, cleanupPlayer)
        .onChange(of: file, cleanupPlayer)
    }

    // MARK: - Preview

    private var previewSection: some View {
        VideoThumbnail(videoID: entry.id) { thumbnail in
            Color.black
                .overlay {
                    if let thumbnail {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Image(systemName: "film")
                            .font(.system(size: 24))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .overlay {
            if let playback, isPlaying {
                PlayerLayerView(player: playback.player)
            }
        }
        .overlay {
            playOverlay
        }
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .contentShape(Rectangle())
        .onDisappear {
            cleanupPlayer()
            isHoveringPreview = false
        }
        .onChange(of: appearsActive) {
            if !appearsActive {
                cleanupPlayer()
            }
        }
        .onScrollVisibilityChange(threshold: 0.01) {
            if !$0 {
                cleanupPlayer()
            }
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHoveringPreview = hovering
            }
        }
    }

    private var playOverlay: some View {
        PlayOverlayButton(
            isPaused: !isPlaying,
            isVisible: isHoveringPreview || !isPlaying,
            diameter: 56,
            action: togglePlayback,
        )
    }

    private func togglePlayback() {
        if isPlaying {
            playback?.player.pause()
            isPlaying = false
        } else {
            if playback == nil {
                playback = LoopingVideoPreview(url: videoURL)
            }
            playback?.player.play()
            isPlaying = true
        }
    }

    private func cleanupPlayer() {
        playback?.stop()
        playback = nil
        isPlaying = false
    }

    // MARK: - Name

    @ViewBuilder
    private func memberField(_ label: LocalizedStringKey, entry: VideoDeploymentService.EntryInfo?) -> some View {
        if let entry {
            InspectorNameField(label: label, name: entry.name) { saveName($0, member: entry) }
                .id(entry.id)
        } else {
            LabeledContent(label) { Text("File unavailable") }
        }
    }

    private func saveName(_ name: String, member: VideoDeploymentService.EntryInfo? = nil) {
        do {
            if member == nil, let record = pair?.saved {
                try record.rename(to: name, in: VideoDeploymentService.videosFolderURL)
                VideoDeploymentService.notifyExtensionLibraryChanged()
            } else {
                // Older pairs inherit the visible member's name until either name is edited.
                if let record = pair?.saved, record.name == nil, member?.id == entry.id {
                    try record.rename(to: entry.name, in: VideoDeploymentService.videosFolderURL)
                }
                try VideoDeploymentService.renameEntry(entryID: member?.id ?? entry.id, to: name)
            }
        } catch {
            manager.optimizationAlertMessage = error.localizedDescription
            manager.showOptimizationAlert = true
        }
    }
}

private struct InspectorNameField: View {
    let label: LocalizedStringKey
    let name: String
    let save: (String) -> Void

    @State private var draft: String?
    @FocusState private var focused: Bool

    var body: some View {
        TextField(label, text: Binding(get: { draft ?? name }, set: { draft = $0 }))
            .focused($focused)
            .onSubmit {
                commit()
                focused = false
            }
            .onExitCommand {
                draft = nil
                focused = false
            }
            .onChange(of: focused) {
                if !focused {
                    commit()
                }
            }
            .onDisappear(perform: commit)
    }

    private func commit() {
        guard let draft else { return }
        self.draft = nil
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != name else { return }
        save(trimmed)
    }
}
