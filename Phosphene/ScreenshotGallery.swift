#if DEBUG

    import AppKit
    import SwiftUI

    /// A chrome-less stage for capturing clean menu-bar popover screenshots.
    ///
    /// The real `MenuBarExtra` popover is useless for marketing captures: its window material
    /// samples whatever is behind the menu bar (muddy grays), and `screencapture` grabs that
    /// vibrancy rather than a crisp panel. This stage shows the same `MenuBarPopoverView`, bound
    /// to the same live manager, on an opaque window background with rounded alpha corners and no
    /// shadow — one window forced light, one forced dark, so both README variants come from a
    /// single run.
    ///
    /// Because `selections` is derived from the *system* wallpaper store, the popover shows its
    /// empty state on any Mac where Phosphene isn't the active wallpaper. So the stage fabricates
    /// one selection from the first video in the library (see `stageSelection`), the same way
    /// Dantrolene's gallery fakes an SSID — the capture is staged, not the machine.
    ///
    /// Present by launching with `-PHOSPHENE_GALLERY 1`. Capture each window with
    /// `screencapture -l <window id> -o out.png` (find the id by window title via CGWindowList).
    @MainActor
    enum ScreenshotGallery {
        private static var windows: [NSWindow] = []

        static func present(manager: PhospheneManager) {
            guard windows.isEmpty else {
                windows.forEach { $0.makeKeyAndOrderFront(nil) }
                NSApp.activate(ignoringOtherApps: true)
                return
            }

            stageSelection(on: manager.prefsService)

            let light = makeStage(manager: manager, dark: false, title: "Phosphene — Stage (Light)")
            let dark = makeStage(manager: manager, dark: true, title: "Phosphene — Stage (Dark)")

            light.center()
            let origin = light.frame.origin
            light.setFrameOrigin(NSPoint(x: origin.x - light.frame.width * 0.7, y: origin.y))
            dark.setFrameOrigin(NSPoint(x: origin.x + dark.frame.width * 0.7, y: origin.y))

            let library = makeLibraryStage(manager: manager)

            windows = [library, light, dark]
            windows.forEach { $0.orderFront(nil) }
            // Make the library window key last so its traffic lights render active in the capture.
            library.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }

        /// The library management window in a real titled window (traffic lights + unified
        /// toolbar), forced light, with the active wallpaper pre-selected so the inspector is
        /// populated — for the second README shot.
        private static func makeLibraryStage(manager: PhospheneManager) -> NSWindow {
            let selectedID = manager.prefsService.selections.first?.videoID
            let hosting = NSHostingController(
                rootView: NavigationStack { LibraryWindow(manager: manager, initialSelectionID: selectedID) }
                    .environment(\.colorScheme, .light),
            )
            let window = NSWindow(contentViewController: hosting)
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.title = "Phosphene — Library"
            window.setContentSize(NSSize(width: 940, height: 600))
            window.toolbarStyle = .unified
            window.appearance = NSAppearance(named: .aqua)
            window.isReleasedWhenClosed = false
            window.center()
            let origin = window.frame.origin
            window.setFrameOrigin(NSPoint(x: origin.x, y: origin.y - 180))
            return window
        }

        // MARK: - Staging

        /// Fabricate a single wallpaper selection so the popover renders its full "playing" state.
        private static func stageSelection(on prefs: WallpaperPrefsService) {
            let entries = VideoDeploymentService.listEntries()
            guard let entry = entries.first(where: { $0.name.localizedCaseInsensitiveContains("galaxy") })
                ?? entries.first else { return }

            let screen = NSScreen.main
            let displayID = (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32) ?? 1
            let displayName = screen?.localizedName ?? "Studio Display"

            let selection = WallpaperPrefsService.WallpaperSelection(
                id: "gallery",
                videoID: entry.id,
                displayUUID: "gallery",
                displayName: displayName,
                displayID: displayID,
                spaceUUID: nil,
                spaceName: nil,
                videoName: prettyName(for: entry.name),
                videoURL: VideoDeploymentService.videoURL(for: entry),
            )
            prefs.stageGallerySelection(selection)
        }

        /// The library stores raw source-file slugs ("…-moewalls-com"); tidy one for display.
        private static func prettyName(for raw: String) -> String {
            var name = raw
            for suffix in ["-moewalls-com", "-moewalls"] where name.hasSuffix(suffix) {
                name.removeLast(suffix.count)
            }
            let words = name
                .split(whereSeparator: { $0 == "-" || $0 == "_" })
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            return words.joined(separator: " ")
        }

        // MARK: - Stage window

        private static func makeStage(manager: PhospheneManager, dark: Bool, title: String) -> NSWindow {
            let hosting = NSHostingController(rootView: StageView(manager: manager, dark: dark))
            let window = KeyableBorderlessWindow(contentViewController: hosting)
            window.styleMask = [.borderless]
            window.title = title
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.level = .floating
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            return window
        }
    }

    /// Borderless windows refuse key status by default, which would make the popover's controls
    /// (toggles, buttons) unclickable while staging.
    private final class KeyableBorderlessWindow: NSWindow {
        override var canBecomeKey: Bool { true }
    }

    private struct StageView: View {
        @Bindable var manager: PhospheneManager
        let dark: Bool

        private static let cornerRadius: CGFloat = 12

        var body: some View {
            MenuBarPopoverView(manager: manager)
                .background(Color(nsColor: .windowBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                }
                .padding(1)
                .environment(\.colorScheme, dark ? .dark : .light)
        }
    }

#endif
