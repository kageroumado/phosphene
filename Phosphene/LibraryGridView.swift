import SwiftUI
import UniformTypeIdentifiers

struct LibraryGridView: View {
    @Bindable var manager: PhospheneManager
    @Binding var selectedEntryID: String?
    @State private var entries: [VideoDeploymentService.EntryInfo] = []
    @State private var confirmingDelete: VideoDeploymentService.EntryInfo?

    private static let columns = [GridItem(.adaptive(minimum: 220, maximum: 220), spacing: 16)]

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
                                onSelect: { selectedEntryID = entry.id },
                                onDelete: { confirmingDelete = entry },
                            )
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 20)

                    wallpaperSettingsFooter
                }
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

    private var wallpaperSettingsFooter: some View {
        VStack(spacing: 8) {
            Text("To set a wallpaper, choose one in System Settings.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Button {
                NSWorkspace.shared.open(
                    URL(string: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension")!,
                )
            } label: {
                Label("Open Wallpaper Settings", systemImage: "gearshape")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 20)
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
