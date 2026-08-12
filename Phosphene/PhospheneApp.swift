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
            Image(systemName: "play.rectangle.fill")
        }
        .menuBarExtraStyle(.window)

        Window("Phosphene", id: "library") {
            LibraryWindow(manager: manager)
        }
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
        if !manager.hideDockIcon {
            NSApplication.shared.setActivationPolicy(.regular)
        }
        openWindow(id: "library")
        DispatchQueue.main.async {
            NSApplication.shared.activate()
            for window in NSApplication.shared.windows
                where window.identifier?.rawValue == "library" {
                window.orderFrontRegardless()
                window.makeKey()
            }
        }
    }
}

// MARK: - URL Scheme Handling

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    nonisolated func application(_: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            for url in urls {
                guard url.scheme == "phosphene", url.host == "add-video" else { continue }
                PhospheneManager.shared?.openVideoChooser()
            }
        }
    }
}
