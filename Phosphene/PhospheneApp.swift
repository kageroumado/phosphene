import SwiftUI

@main
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
        #endif
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarPopoverView(manager: manager, openLibrary: {
                showLibraryWindow()
            })
        } label: {
            let announcing = manager.updateCheck.availableVersion != nil
                || SilentUpdates.shared.justUpdatedVersion != nil
            Image(nsImage: MenuBarIcon.image(updateBadge: announcing))
        }
        .menuBarExtraStyle(.window)

        Window("Phosphene", id: "library") {
            LibraryWindow(manager: manager)
        }
        // phosphene://library opens the window directly (used by the Settings-pane
        // context menu). Promotion to a regular app happens in LibraryWindow.onAppear
        // so every open path gets the Dock icon and activation.
        .handlesExternalEvents(matching: ["library"])
        .defaultSize(width: 900, height: 600)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Phosphene") {
                    NSApp.orderFrontStandardAboutPanel(options: [
                        .credits: Self.aboutCredits,
                    ])
                    NSApp.activate()
                }
            }
            SidebarCommands()
            InspectorCommands()
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
            .link: URL(string: "https://kagerou.glass")!,
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
