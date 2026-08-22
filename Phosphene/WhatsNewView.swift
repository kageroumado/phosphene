import AppKit
import SwiftUI

// MARK: - Release notes

/// One GitHub release's changelog, reduced to what the What's New window shows.
struct ReleaseNotes: Sendable, Equatable {
    let version: String
    let body: String
    let url: URL
}

/// Fetches a release's changelog from GitHub by tag. Stateless; the window that shows the notes
/// owns the (single) in-flight fetch, so there is nothing to cache or throttle here.
enum ReleaseNotesLoader {
    static func fetch(version: String) async -> ReleaseNotes? {
        let api = URL(string: "https://api.github.com/repos/\(SilentUpdates.owner)/\(SilentUpdates.repo)/releases/tags/v\(version)")!
        var request = URLRequest(url: api)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let release = try? JSONDecoder().decode(Release.self, from: data) else { return nil }
        return ReleaseNotes(version: version, body: release.body ?? "", url: release.htmlURL)
    }

    private struct Release: Decodable {
        let body: String?
        let htmlURL: URL

        enum CodingKeys: String, CodingKey {
            case body
            case htmlURL = "html_url"
        }
    }
}

// MARK: - What's New window

/// Presents the changelog in its own small window. Always built fresh: the same window can be
/// asked to show a different version or context (available → just-updated), and replacing it
/// is simpler than mutating it.
@MainActor
enum WhatsNewWindow {
    private static var window: NSWindow?

    static func present(version: String, context: WhatsNewView.Context) {
        window?.close()
        let hosting = NSHostingController(rootView: WhatsNewView(
            version: version, context: context,
            onClose: { close() },
        ))
        hosting.sizingOptions = .standardBounds
        let w = NSWindow(contentViewController: hosting)
        w.title = "What's New" // for the window menu / accessibility only
        w.styleMask = [.titled, .closable]
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.isMovableByWindowBackground = true
        w.center()
        w.isReleasedWhenClosed = false
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    static func close() {
        window?.close()
        window = nil
    }
}

/// The changelog, shown from both ends of an update: before one ("here's what you'd get",
/// with the install action) and after one ("here's what just changed").
struct WhatsNewView: View {
    enum Context: Equatable {
        /// A newer version exists. `autoInstall` decides the framing: an auto-updating app will
        /// get there on its own, a manual one waits for the button either way.
        case updateAvailable(autoInstall: Bool)
        /// The app was updated (silently or via the install button) and this is the announcement.
        case justUpdated
    }

    let version: String
    let context: Context
    /// Injected by previews so the window renders without a network.
    var preloadedNotes: ReleaseNotes?
    /// Closes the hosting window.
    var onClose: () -> Void = {}

    @State private var notes: ReleaseNotes?
    @State private var loadFailed = false
    @State private var installer = SilentUpdates.shared

    private var releasePageURL: URL {
        notes?.url ?? URL(string: "https://github.com/\(SilentUpdates.owner)/\(SilentUpdates.repo)/releases")!
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(18)

            Divider()

            ScrollView {
                notesBody
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            footer
                .padding(12)
        }
        .frame(width: 480, height: 440)
        .task(id: version) {
            guard notes == nil else { return }
            if let preloadedNotes {
                notes = preloadedNotes
            } else if let fetched = await ReleaseNotesLoader.fetch(version: version) {
                notes = fetched
            } else {
                loadFailed = true
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(context == .justUpdated ? "Updated to \(version)" : "What's new in \(version)")
                    .font(.title3.weight(.bold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var subtitle: String {
        switch context {
        case .justUpdated:
            "Phosphene updated itself at a quiet moment — here's what changed."
        case .updateAvailable(autoInstall: true):
            "It will install itself when your Mac is idle — the wallpaper keeps playing."
        case .updateAvailable(autoInstall: false):
            "A newer version of Phosphene is ready when you are."
        }
    }

    @ViewBuilder
    private var notesBody: some View {
        if let notes {
            if notes.body.isEmpty {
                Text("This release shipped without notes.")
                    .foregroundStyle(.secondary)
            } else {
                ReleaseNotesText(markdown: notes.body)
            }
        } else if loadFailed {
            VStack(alignment: .leading, spacing: 8) {
                Text("Couldn't load the release notes.")
                    .foregroundStyle(.secondary)
                Link("Read them on GitHub", destination: releasePageURL)
            }
        } else {
            HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
                .padding(.top, 18)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Link("View on GitHub", destination: releasePageURL)
                .font(.callout)
                .foregroundStyle(Color.accentColor)
            Spacer()
            if case let .failed(message) = installer.manualPhase, showsInstallButton {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: 200, alignment: .trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
            switch context {
            case .justUpdated:
                Button("Done") { onClose() }
                    .keyboardShortcut(.defaultAction)
            case .updateAvailable:
                Button("Later") { onClose() }
                Button {
                    Task { await installer.updateNow() }
                } label: {
                    HStack(spacing: 4) {
                        if installer.manualPhase == .working {
                            ProgressView().controlSize(.small)
                        }
                        Text(installer.manualPhase == .working ? "Updating…" : "Update Now")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(installer.manualPhase == .working)
            }
        }
    }

    private var showsInstallButton: Bool {
        if case .updateAvailable = context { return true }
        return false
    }
}

// MARK: - Markdown-lite renderer

/// Renders a GitHub release body: `###` headings, `-`/`*` bullets (with indented continuation
/// paragraphs), and plain paragraphs, each with inline markdown (bold, code, links). SwiftUI's
/// `Text` handles inline markdown but flattens block structure, hence the hand-rolled blocks.
struct ReleaseNotesText: View {
    let markdown: String

    private enum Block {
        case heading(String)
        case bullet([String])
        case paragraph(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case let .heading(text):
                    Text(inline(text))
                        .font(.headline)
                        .padding(.top, 4)
                case let .bullet(paragraphs):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, p in
                                Text(inline(p))
                            }
                        }
                    }
                case let .paragraph(text):
                    Text(inline(text))
                }
            }
        }
        .textSelection(.enabled)
        .tint(Color.accentColor)
    }

    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text)) ?? AttributedString(text)
    }

    /// Groups lines into blocks. A line indented under a bullet continues that bullet (GitHub
    /// nests follow-up paragraphs that way); consecutive plain lines merge into one paragraph.
    private var blocks: [Block] {
        var result: [Block] = []
        var bullet: [String]?
        var paragraph = ""

        func flushParagraph() {
            let trimmed = paragraph.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { result.append(.paragraph(trimmed)) }
            paragraph = ""
        }
        func flushBullet() {
            if let b = bullet { result.append(.bullet(b)) }
            bullet = nil
        }

        for rawLine in markdown.components(separatedBy: .newlines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            let indented = rawLine.first == " " || rawLine.first == "\t"

            if trimmed.isEmpty {
                flushParagraph()
                // A blank line inside a bullet's indented continuation doesn't end the bullet;
                // whether it did is decided by the next non-blank line's indentation.
                continue
            }
            if trimmed.hasPrefix("#") {
                flushParagraph(); flushBullet()
                result.append(.heading(trimmed.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)))
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                flushParagraph(); flushBullet()
                bullet = [String(trimmed.dropFirst(2))]
            } else if indented, bullet != nil {
                bullet?.append(trimmed)
            } else {
                flushBullet()
                paragraph = paragraph.isEmpty ? trimmed : paragraph + " " + trimmed
            }
        }
        flushParagraph(); flushBullet()
        return result
    }
}

#if DEBUG
    #Preview("What's New — update available") {
        WhatsNewView(
            version: "9.9.9",
            context: .updateAvailable(autoInstall: true),
            preloadedNotes: .debugSample,
        )
    }

    #Preview("What's New — just updated") {
        WhatsNewView(version: "9.9.9", context: .justUpdated, preloadedNotes: .debugSample)
    }

    extension ReleaseNotes {
        /// Exercises every block shape the renderer knows: headings, bold, links, a bullet with an
        /// indented continuation paragraph, and a trailing plain paragraph.
        static let debugSample = ReleaseNotes(
            version: "9.9.9",
            body: """
            A redesign and a new updater — most of it from **community reports**.

            ### Fixed

            - **The wallpaper no longer stays small after a display reconnects** — the reuse \
            path discarded the new size. Reported by [@someone](https://github.com/kageroumado). (#21)
            - **Grey wallpaper after standby is gone** — the extension re-acquires its surface.

            ### New

            - **Silent auto-updates** — Phosphene installs new versions at a quiet moment.

              The swap waits while a video optimization is running, and the wallpaper keeps \
            playing throughout.

            Prefer manual updates? Turn off Auto-Update from the version pill in the menu bar.
            """,
            url: URL(string: "https://github.com/kageroumado/phosphene/releases")!,
        )
    }
#endif
