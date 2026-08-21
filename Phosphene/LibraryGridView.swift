import SwiftUI
import UniformTypeIdentifiers

struct LibraryGridView: View {
    @Bindable var manager: PhospheneManager
    @Binding var selectedEntryID: String?
    @State private var entries: [VideoDeploymentService.EntryInfo] = []
    @State private var confirmingDelete: VideoDeploymentService.EntryInfo?

    private static let columns = [GridItem(.adaptive(minimum: 220, maximum: 220), spacing: 16)]

    private var inUseVideoIDs: Set<String> {
        Set(manager.prefsService.selections.map(\.videoID))
    }

    var body: some View {
        Group {
            if entries.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 16) {
                        ForEach(entries, id: \.id) { entry in
                            VideoCardView(
                                entry: entry,
                                isSelected: selectedEntryID == entry.id,
                                isInUse: inUseVideoIDs.contains(entry.id),
                                isOptimizing: manager.isOptimizing && manager.optimizingEntryID == entry.id,
                                optimizationProgress: manager.optimizationProgress,
                                onSelect: { selectedEntryID = entry.id },
                                onDelete: { confirmingDelete = entry },
                            )
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 20)
                }
                .safeAreaInset(edge: .bottom, spacing: 0) { statusBar }
            }
        }
        .toolbar {
            ToolbarItem {
                Button {
                    manager.openVideoChooser()
                } label: {
                    Label("Add Video", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let videoTypes: Set<UTType> = [.movie, .video, .mpeg4Movie, .quickTimeMovie]
            let videoURLs = urls.filter { url in
                guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
                return videoTypes.contains(where: { type.conforms(to: $0) })
            }
            guard !videoURLs.isEmpty else { return false }
            Task {
                for url in videoURLs {
                    await manager.importVideo(url)
                }
            }
            return true
        }
        .onAppear { loadEntries() }
        .onReceive(
            NotificationCenter.default.publisher(for: VideoDeploymentService.libraryChangedNotification),
        ) { _ in
            loadEntries()
        }
        .alert("Delete Video", isPresented: .init(
            get: { confirmingDelete != nil },
            set: { if !$0 { confirmingDelete = nil } },
        )) {
            Button("Delete", role: .destructive) {
                if let entry = confirmingDelete {
                    deleteVideo(entry)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to remove \"\(confirmingDelete?.name ?? "")\" from your library?")
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Videos", systemImage: "film.stack")
        } description: {
            Text("Add a video to use as your wallpaper.")
        } actions: {
            Button("Add Video") {
                manager.openVideoChooser()
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Status Bar

    private var statusBar: some View {
        HStack {
            Text(librarySummary)
            Spacer()
            Button {
                NSWorkspace.shared.open(
                    URL(string: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension")!,
                )
            } label: {
                Text("Wallpapers apply in System Settings \(Image(systemName: "arrow.up.right"))")
            }
            .buttonStyle(.plain)
            .help("Open macOS Wallpaper Settings")
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var librarySummary: String {
        let count = entries.count
        let videos = count == 1 ? "1 video" : "\(count) videos"
        let totalBytes = entries.compactMap { VideoDeploymentService.fileSize(for: $0) }.reduce(0, +)
        guard totalBytes > 0 else { return videos }
        let size = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
        return "\(videos) · \(size)"
    }

    // MARK: - Data

    private func loadEntries() {
        entries = VideoDeploymentService.listEntries()
    }

    // MARK: - Actions

    private func deleteVideo(_ entry: VideoDeploymentService.EntryInfo) {
        manager.removeVideo(entryID: entry.id)
        loadEntries()
    }
}
