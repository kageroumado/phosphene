import SwiftUI

/// Started from `main.swift`, which runs a bake helper instead when asked to.
struct PhospheneApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var manager: PhospheneManager

    @Environment(\.openWindow) private var openWindow

    init() {
        let manager = PhospheneManager()
        _manager = State(initialValue: manager)

        #if DEBUG
            // Chrome-less popover stage for clean screenshot captures (see ScreenshotGallery).
            // A menu-bar app never auto-presents SwiftUI windows, so the stage is presented via
            // AppKit once launch settles.
            if UserDefaults.standard.bool(forKey: "PHOSPHENE_GALLERY") {
                DispatchQueue.main.async {
                    ScreenshotGallery.present(manager: manager)
                }
            }
            // Copy the extension's log and library listing somewhere readable: its container
            // refuses every process not signed by its team, a terminal included.
            if UserDefaults.standard.bool(forKey: "PHOSPHENE_EXPORT_DIAGNOSTICS") {
                let documents = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/Containers/glass.kagerou.phosphene.extension/Data/Documents")
                // The user's own temporary folder: `/tmp` is shared, and a fixed name there can
                // be planted as a link by another account before this runs.
                let out = FileManager.default.temporaryDirectory.appendingPathComponent("phosphene-diagnostics")
                try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
                for name in ["extension.log", "extension.log.1"] {
                    try? FileManager.default.removeItem(at: out.appendingPathComponent(name))
                    try? FileManager.default.copyItem(at: documents.appendingPathComponent(name), to: out.appendingPathComponent(name))
                }
                var listing = ""
                let videos = documents.appendingPathComponent("videos")
                for dir in (try? FileManager.default.contentsOfDirectory(at: videos, includingPropertiesForKeys: nil)) ?? [] {
                    listing += "== \(dir.lastPathComponent)\n"
                    for file in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] {
                        let attributes = try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(file).path)
                        listing += "  \(file) \(attributes?[.size] ?? 0)\n"
                    }
                    if let metadata = try? String(contentsOf: dir.appendingPathComponent("metadata.json"), encoding: .utf8) {
                        listing += "  metadata: \(metadata)\n"
                    }
                }
                try? listing.write(to: out.appendingPathComponent("videos.txt"), atomically: true, encoding: .utf8)
            }
        #endif
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarPopoverView(manager: manager, openLibrary: {
                showLibraryWindow()
            })
        } label: {
            let announcing = SilentUpdates.shared.availableVersion != nil
                || SilentUpdates.shared.justUpdatedVersion != nil
            Image(nsImage: MenuBarIcon.image(updateBadge: announcing))
        }
        .menuBarExtraStyle(.window)

        windows.commands { appMenu }
    }

    @SceneBuilder private var windows: some Scene {
        Window("Phosphene", id: "library") {
            LibraryWindow(manager: manager)
        }
        #if DEBUG
        .defaultLaunchBehavior(UserDefaults.standard.bool(forKey: "PHOSPHENE_OPEN_LIBRARY") ? .presented : .automatic)
        #endif
        // phosphene://library opens the window directly (used by the Settings-pane
        // context menu). Promotion to a regular app happens in LibraryWindow.onAppear
        // so every open path gets the Dock icon and activation.
        .handlesExternalEvents(matching: ["library"])
        .defaultSize(width: 1_180, height: 760)
        .commands { LibraryCommands() }

        Window("Custom Conversion", id: "custom-conversion") {
            ConversionToolView(mode: .single)
        }
        .defaultLaunchBehavior(.suppressed)
        .defaultSize(width: 620, height: 660)

        WindowGroup("Light/Dark Pair Converter", id: "pair-converter", for: PairConverterRequest.self) { $request in
            ConversionToolView(mode: .pair, pairRequest: request ?? .blank)
        }
        .commandsRemoved()
        .defaultLaunchBehavior(.suppressed)
        .defaultSize(width: 660, height: 740)

    }

    @CommandsBuilder private var appMenu: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Phosphene") {
                NSApp.orderFrontStandardAboutPanel(options: [
                    .credits: Self.aboutCredits,
                ])
                NSApp.activate()
            }
        }
        CommandMenu("Tools") {
            Button("Custom Conversion…") { openWindow(id: "custom-conversion") }
            Button("Light/Dark Pair Converter…") { openWindow(value: PairConverterRequest.blank) }
            Divider()
            Button("Restart Wallpaper Host and System Settings") {
                Task { await WallpaperPrefsService.shared.restartWallpaperHostAndSettings() }
            }
            .disabled(WallpaperPrefsService.shared.isRestartingWallpaperServices)
        }
    }

    private static let aboutCredits: NSAttributedString = {
        let style = NSMutableParagraphStyle()
        style.alignment = .center

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: style,
        ]

        let string = NSMutableAttributedString()
        string.append(NSAttributedString(string: "kagerou.glass", attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .link: URL(string: "https://kagerou.glass/phosphene/?from=app")!,
            .paragraphStyle: style,
        ]))
        string.append(NSAttributedString(string: "  ·  ", attributes: attributes))
        string.append(NSAttributedString(string: "@kageroumado", attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .link: URL(string: "https://x.com/kageroumado")!,
            .paragraphStyle: style,
        ]))
        return string
    }()

    private func showLibraryWindow() {
        NSApplication.shared.setActivationPolicy(.regular)
        openWindow(id: "library")
        // Two passes: cooperative activation can be declined while the popover is
        // still dismissing, so a second attempt runs after it has settled.
        for delay in [0.0, 0.25] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                NSApplication.shared.activate()
                NSRunningApplication.current.activate(options: [.activateAllWindows])
                for window in NSApplication.shared.windows
                    where window.identifier?.rawValue == "library" {
                    window.makeKeyAndOrderFront(nil)
                }
            }
        }
    }
}

// MARK: - App Delegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_: Notification) {
        // The app is a menu-bar accessory; opening the Library promotes it to a regular
        // app so the window gets a Dock icon and menu bar. Demote it back when the last
        // regular-level window closes. The check is deferred one runloop turn because
        // during willClose the closing window still reports isVisible == true — checking
        // synchronously (or in the view's onDisappear) always finds "a visible window"
        // and leaves the Dock icon behind.
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil, queue: .main,
        ) { _ in
            DispatchQueue.main.async {
                let app = NSApplication.shared
                guard app.activationPolicy() == .regular else { return }
                let anyVisible = app.windows.contains { $0.isVisible && $0.level == .normal }
                if !anyVisible {
                    app.setActivationPolicy(.accessory)
                }
            }
        }
    }

    nonisolated func application(_: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            for url in urls {
                guard url.scheme == "phosphene" else { continue }
                switch url.host {
                case "add-video":
                    PhospheneManager.shared?.openVideoChooser()
                #if DEBUG
                    // Exercise the What's New window against a real release without waiting
                    // for an update: phosphene://whats-new?v=1.2.1[&context=updated]
                    case "whats-new":
                        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
                        let version = components?.queryItems?.first(where: { $0.name == "v" })?.value ?? "1.2.1"
                        let updated = components?.queryItems?.contains(where: { $0.name == "context" && $0.value == "updated" }) ?? false
                        WhatsNewWindow.present(
                            version: version,
                            context: updated ? .justUpdated : .updateAvailable(autoInstall: true),
                        )
                #endif
                default:
                    break
                }
            }
        }
    }
}
