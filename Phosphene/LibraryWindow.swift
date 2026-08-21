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
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showInspector.toggle()
                    } label: {
                        Label("Toggle Inspector", systemImage: "sidebar.trailing")
                    }
                    .help(showInspector ? "Hide Inspector" : "Show Inspector")
                }
            }
            .onAppear {
                loadEntries()
                // Promote to a regular app for every open path (menu bar, URL scheme):
                // the window needs a Dock icon and menu bar while visible. The
                // AppDelegate's willClose observer demotes back to accessory.
                NSApplication.shared.setActivationPolicy(.regular)
                NSApplication.shared.activate()
            }
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
        // Open with something useful in the inspector: the wallpaper in use, else the first video.
        if selectedEntryID == nil {
            let inUse = Set(manager.prefsService.selections.map(\.videoID))
            selectedEntryID = (entries.first(where: { inUse.contains($0.id) }) ?? entries.first)?.id
        }
    }
}
