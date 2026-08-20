import AppKit
import SwiftUI

struct LibraryWindow: View {
    @Bindable var manager: PhospheneManager
    var initialSelectionID: String?
    @State private var selectedEntryID: String?
    @State private var showInspector = true
    @State private var entries: [VideoDeploymentService.EntryInfo] = []

    var body: some View {
        LibraryGridView(manager: manager, selectedEntryID: $selectedEntryID)
            .frame(minWidth: 260)
            .inspector(isPresented: $showInspector) {
                Group {
                    if let selectedEntryID,
                       let entry = entries.first(where: { $0.id == selectedEntryID }) {
                        VideoInspectorView(entry: entry, manager: manager)
                    } else {
                        ContentUnavailableView {
                            Label("No Selection", systemImage: "sidebar.right")
                        } description: {
                            Text("Select a video to view its details.")
                        }
                    }
                }
                .inspectorColumnWidth(min: 260, ideal: 300, max: 380)
            }
            .navigationTitle("Phosphene")
            .toolbar {
                ToolbarItem {
                    Button {
                        let folder = VideoDeploymentService.videosFolderURL
                        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(folder)
                    } label: {
                        Label("Open in Finder", systemImage: "folder")
                    }
                    .help("Open the library folder in Finder")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showInspector.toggle()
                    } label: {
                        Label("Toggle Inspector", systemImage: "sidebar.trailing")
                    }
                    .help(showInspector ? "Hide Inspector" : "Show Inspector")
                }
            }
            .onAppear { loadEntries() }
            .onReceive(
                NotificationCenter.default.publisher(for: VideoDeploymentService.libraryChangedNotification),
            ) { _ in
                loadEntries()
            }
    }

    private func loadEntries() {
        entries = VideoDeploymentService.listEntries()
        if let selectedEntryID, !entries.contains(where: { $0.id == selectedEntryID }) {
            self.selectedEntryID = nil
        }
        if selectedEntryID == nil, let initialSelectionID,
           entries.contains(where: { $0.id == initialSelectionID }) {
            selectedEntryID = initialSelectionID
        }
    }
}
