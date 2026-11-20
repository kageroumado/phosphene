import SwiftUI

/// The library window's actions, published to the menu bar.
struct LibraryActions {
    let showsInspector: Bool
    let toggleInspector: () -> Void
    let pair: VideoPairSelection?
    let openPair: (VideoPairSelection) -> Void
    let addVideo: () -> Void
    let addFolder: () -> Void
    let makeVideos: (() -> Void)?
    let showAsIcons: () -> Void
    let showAsList: () -> Void
    let largerIcons: () -> Void
    let smallerIcons: () -> Void
    let viewMode: LibraryViewMode
}

extension FocusedValues {
    @Entry var libraryActions: LibraryActions?
}

/// Every toolbar action also lives in the menu bar, with keyboard shortcuts.
struct LibraryCommands: Commands {
    @FocusedValue(\.libraryActions) private var actions

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Add Video…") { actions?.addVideo() }
                .keyboardShortcut("o")
                .disabled(actions == nil)
            Button("Add Wallpaper Engine Folder…") { actions?.addFolder() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(actions == nil)
            Divider()
            Button(actions?.pair?.actionTitle ?? "Pair…") {
                if let pair = actions?.pair {
                    actions?.openPair(pair)
                }
            }
            .disabled(actions?.pair == nil)
            Button("Make Videos…") { actions?.makeVideos?() }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .disabled(actions?.makeVideos == nil)
        }
        CommandGroup(before: .sidebar) {
            Toggle("as Icons", isOn: Binding(
                get: { actions?.viewMode == .icons },
                set: {
                    if $0 {
                        actions?.showAsIcons()
                    }
                },
            ))
            .keyboardShortcut("1")
            .disabled(actions == nil)
            Toggle("as List", isOn: Binding(
                get: { actions?.viewMode == .list },
                set: {
                    if $0 {
                        actions?.showAsList()
                    }
                },
            ))
            .keyboardShortcut("2")
            .disabled(actions == nil)
            Divider()
            Button("Make Icons Larger") { actions?.largerIcons() }
                .keyboardShortcut("+")
                .disabled(actions?.viewMode != .icons)
            Button("Make Icons Smaller") { actions?.smallerIcons() }
                .keyboardShortcut("-")
                .disabled(actions?.viewMode != .icons)
            Divider()
        }
        SidebarCommands()
        CommandGroup(after: .sidebar) {
            Button(actions?.showsInspector == true ? "Hide Inspector" : "Show Inspector") { actions?.toggleInspector() }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(actions == nil)
        }
    }
}
