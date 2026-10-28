import AppIntents

struct PhospheneShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SetWallpaperIntent(),
            phrases: [
                "Add a video to \(.applicationName)",
                "Add a wallpaper video to \(.applicationName)",
            ],
            shortTitle: "Add Video",
            systemImageName: "plus.rectangle.on.rectangle",
        )
    }
}
