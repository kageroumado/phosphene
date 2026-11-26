import AppKit
import AppUpdater
import Foundation
import Observation
import os
import SwiftUI
import Tiptoe

/// The app's updater: downloads from GitHub Releases, verifies, and swaps the bundle in place —
/// silently when the user allows it, on an explicit install otherwise.
///
/// The heavy lifting is [Tiptoe](https://github.com/artginzburg/Tiptoe) over mxcl/AppUpdater:
/// AppUpdater checks the release, downloads the DMG, and verifies the Team ID against the running
/// app; Tiptoe decides *when* the swap may run, waiting for the Mac to go quiet. The swap restarts
/// the app — harmless for a menu bar controller (the wallpaper extension is a separate process and
/// keeps playing) — except while a video optimization is running, so the gate below vetoes exactly
/// that. The gate is a veto, not a preference: Tiptoe's own patience relaxes over days, this never
/// does.
///
/// One check loop serves both modes: with auto-update off the check still runs and still
/// answers ``availableVersion`` — the menu bar badge and version chip draw from it — but nothing
/// downloads or installs except through ``updateNow(version:)``.
///
/// The loop ticks every ``checkInterval``; between ticks, opening the popover or waking the Mac
/// repeats the check once it is ``staleAfter`` old, and the version chip's refresh button makes
/// one on demand. Each is a single GitHub metadata request, which GitHub itself caches for a
/// minute.
@MainActor
@Observable
final class SilentUpdates {
    static let shared = SilentUpdates()

    static let owner = "kageroumado"
    static let repo = "phosphene"

    /// The chip announces a release within hours of it shipping, so a fix reaches people the
    /// same day; the request is one cached metadata call.
    private static let checkInterval: TimeInterval = 4 * 60 * 60

    /// A check older than this is repeated when the popover opens or the Mac wakes: the loop's
    /// tick may have landed while the Mac slept, or at a launch before the network was up.
    private static let staleAfter: TimeInterval = 60 * 60

    /// The network comes back a beat after the Mac does; asking at the wake notification itself
    /// fails and leaves the next try to the loop.
    private static let wakeGrace: Duration = .seconds(20)

    /// How long the chip shows the result of a check that found no installable update.
    private static let checkNoticeDuration: Duration = .seconds(3)

    /// How often ``refresh()`` copies Tiptoe's in-memory state into the observable properties,
    /// so the menu bar badge appears without the popover being opened. No network involved.
    private static let mirrorInterval: Duration = .seconds(60)

    /// Where the update-failed affordance sends the user.
    static let releasesPageURL = URL(string: "https://github.com/\(owner)/\(repo)/releases/latest")!

    /// Progress of a user-initiated install, for the version chip. A successful install replaces
    /// the process, so the only terminal state this side of the swap is `.failed`.
    enum ManualPhase: Equatable {
        case idle
        case working
        case failed(String)
    }

    private(set) var manualPhase: ManualPhase = .idle

    /// The newest installable release newer than the running app, whether downloaded or not.
    private(set) var availableVersion: String?

    /// The version the automatic path has downloaded and is holding for a quiet moment, if any.
    /// A stronger claim than ``availableVersion``; refreshed by ``refresh()``.
    private(set) var pendingVersion: String?

    /// The version a silent (or manual) install brought us to, until the user has seen the
    /// notice. Read from Tiptoe's store at launch; cleared by ``acknowledgeUpdate()``.
    private(set) var justUpdatedVersion: String?

    /// True while a check the user asked for is in flight, for the version chip.
    private(set) var isChecking = false

    /// True briefly after a successful explicit check found no installable update.
    private(set) var checkedNoInstallableUpdate = false

    /// The updater: check loop, plus the quiet-moment install when auto-update is on.
    /// Created up front so its `Tiptoe` reconciles the recorded wait and the post-update notice
    /// against the running bundle (a notice that outlived its version is dropped) before the
    /// loop starts. Notify-only until ``start(autoInstall:)``
    /// applies the user's setting — which never happens in DEBUG, so a development build's
    /// manual check stays a metadata request and cannot download a DMG on the side.
    @ObservationIgnored private let tiptoe: Tiptoe
    @ObservationIgnored private let updater: AppUpdater
    @ObservationIgnored private let activity: UpdateActivity
    @ObservationIgnored private var checkingPanel: NSPanel?
    @ObservationIgnored private var checkLoop: Task<Void, Never>?
    @ObservationIgnored private var mirrorTask: Task<Void, Never>?
    @ObservationIgnored private var wakeObserver: (any NSObjectProtocol)?

    /// When the shared check last finished.
    @ObservationIgnored private var lastCheckedAt: Date?
    @ObservationIgnored private var consecutiveCheckFailures = 0

    private init() {
        updater = AppUpdater(owner: Self.owner, repo: Self.repo)
        tiptoe = Tiptoe()
        activity = UpdateActivity(tiptoe: tiptoe, videoWork: .shared)
        justUpdatedVersion = tiptoe.justUpdatedTo
    }

    // MARK: - Automatic installs

    /// Called once at launch with the user's setting.
    func start(autoInstall: Bool) {
        // Never in DEBUG: a development build must not poll GitHub, and must never be swapped
        // out from under Xcode.
        #if !DEBUG
            guard checkLoop == nil else { return }
            activity.autoInstall = autoInstall
            checkLoop = Task(name: "Check for updates periodically") { [weak self] in
                while !Task.isCancelled {
                    await self?.check()
                    try? await Task.sleep(for: .seconds(Self.checkInterval))
                }
            }
            mirrorTask = Task(name: "Mirror update state") { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: Self.mirrorInterval)
                    self?.refresh()
                }
            }
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main,
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.checkAfterWake()
                }
            }
        #endif
    }

    /// Reacts to the Auto-Update toggle. Turning it off keeps the check loop but stops the
    /// quiet-moment watcher; a DMG already downloaded stays downloaded but installs only
    /// via ``updateNow(version:)``.
    func setAutoInstall(_ enabled: Bool) {
        #if !DEBUG
            activity.autoInstall = enabled
            refresh()
            if enabled {
                Task { await check() }
            }
        #endif
    }

    /// Copies Tiptoe's state into the observable properties. Called when the popover appears,
    /// every ``mirrorInterval``, and after update actions — Tiptoe has no change callback.
    func refresh() {
        pendingVersion = activity.pendingVersion
    }

    // MARK: - Checking

    /// The user pressed the chip's refresh: the same request the loop makes, off-schedule, with
    /// the chip saying what it is doing and, briefly, what it found.
    func checkForUpdates() async {
        guard !isChecking else { return }
        isChecking = true
        checkedNoInstallableUpdate = false
        defer { isChecking = false }
        // The background check shares AppUpdater's metadata request and can prepare the download.
        Task { await check() }
        do {
            _ = try await checkForRelease()
        } catch {
            return
        }
        guard availableVersion == nil, activity.pendingVersion == nil else { return }
        checkedNoInstallableUpdate = true
        Task(name: "Clear the update check notice") { [weak self] in
            try? await Task.sleep(for: Self.checkNoticeDuration)
            self?.checkedNoInstallableUpdate = false
        }
    }

    /// Presents the result of an explicit check from the application menu.
    func checkForUpdates(autoInstall: Bool) {
        if let checkingPanel {
            checkingPanel.makeKeyAndOrderFront(nil)
            return
        }

        let content = NSHostingView(rootView: UpdateCheckProgressView { [weak self] in
            self?.dismissCheck()
        })
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: content.fittingSize),
            styleMask: [.titled], backing: .buffered, defer: false,
        )
        panel.title = String(localized: "Software Update")
        panel.isReleasedWhenClosed = false
        panel.contentView = content
        checkingPanel = panel
        panel.center()
        panel.makeKeyAndOrderFront(nil)

        Task { [weak panel] in
            let result: Result<String?, any Error>
            do {
                result = try await .success(checkForRelease()?.version)
            } catch {
                result = .failure(error)
            }
            // AppUpdater shares its metadata request with the background updater.
            guard let panel, checkingPanel === panel else { return }
            dismissCheck()
            switch result {
            case let .success(version?):
                showAvailableUpdate(version: version, autoInstall: autoInstall)
            case .success(nil):
                let notice = NSAlert()
                notice.messageText = String(localized: "No installable update found")
                notice.addButton(withTitle: String(localized: "Done"))
                notice.addButton(withTitle: String(localized: "View on GitHub"))
                if notice.runModal() == .alertSecondButtonReturn {
                    NSWorkspace.shared.open(Self.releasesPageURL)
                }
            case let .failure(error):
                let notice = NSAlert()
                notice.alertStyle = .warning
                notice.messageText = String(localized: "Couldn’t check for updates")
                notice.informativeText = error.localizedDescription
                notice.addButton(withTitle: String(localized: "Try Again"))
                notice.addButton(withTitle: String(localized: "Cancel")).keyEquivalent = "\u{1b}"
                if notice.runModal() == .alertFirstButtonReturn {
                    checkForUpdates(autoInstall: autoInstall)
                }
            }
        }
    }

    private func dismissCheck() {
        checkingPanel?.close()
        checkingPanel = nil
    }

    private func showAvailableUpdate(version: String, autoInstall: Bool) {
        dismissFailure()
        let alert = NSAlert()
        alert.messageText = String(localized: "Phosphene \(version) is available")
        alert.alertStyle = .informational
        #if DEBUG
            alert.addButton(withTitle: String(localized: "View on GitHub"))
        #else
            alert.addButton(withTitle: String(localized: "Update Now"))
        #endif
        alert.addButton(withTitle: String(localized: "Later")).keyEquivalent = "\u{1b}"
        alert.addButton(withTitle: String(localized: "Release Notes"))
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            #if DEBUG
                NSWorkspace.shared.open(Self.releasesPageURL)
            #else
                WhatsNewWindow.present(version: version, context: .updateAvailable(autoInstall: autoInstall))
                Task { await updateNow(version: version) }
            #endif
        case .alertThirdButtonReturn:
            WhatsNewWindow.present(version: version, context: .updateAvailable(autoInstall: autoInstall))
        default:
            break
        }
    }

    /// The check the popover's appearance and the Mac's waking make, when the last one is old
    /// enough to be worth repeating. Quiet: the chip shows its result, never its progress.
    func checkIfStale() {
        // A development build does not poll GitHub on its own; the chip's refresh is the one
        // request it makes, and only when asked.
        #if !DEBUG
            if let lastCheckedAt, Date.now.timeIntervalSince(lastCheckedAt) < Self.staleAfter {
                return
            }
            Task(name: "Check for updates (stale)") { await check() }
        #endif
    }

    private func checkAfterWake() {
        Task(name: "Check for updates after wake") { [weak self] in
            try? await Task.sleep(for: Self.wakeGrace)
            self?.checkIfStale()
        }
    }

    /// Every background check joins the same task, including its preparation.
    private func check() async {
        await activity.check {
            defer {
                self.lastCheckedAt = .now
                self.refresh()
            }
            do {
                if let candidate = try await self.checkCandidate(), self.activity.autoInstall {
                    try await self.activity.prepare(candidate)
                }
                self.consecutiveCheckFailures = 0
            } catch {
                guard !(error is CancellationError), (error as? URLError)?.code != .cancelled else { return }
                Log.update.debug("update check failed: \(error.localizedDescription, privacy: .public)")
                self.consecutiveCheckFailures += 1
                if self.consecutiveCheckFailures == Int(86_400 / Self.checkInterval) {
                    Log.update.error("update checks have been failing: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    private func checkForRelease() async throws -> Update? {
        let update = try await updater.check()
        availableVersion = update?.version
        lastCheckedAt = .now
        return update
    }

    private func checkCandidate() async throws -> UpdateActivity.Candidate? {
        guard let update = try await checkForRelease() else { return nil }
        return UpdateActivity.Candidate(version: update.version) {
            let prepared = try await update.prepareInstallation()
            return UpdateActivity.Download(
                install: { try await prepared.installAndRelaunch() },
                discard: { await prepared.discard() },
            )
        }
    }

    // MARK: - Update Now

    /// Download (if needed), verify, and install the version shown to the user.
    /// On success the app relaunches and this never returns to its caller in a meaningful way;
    /// still running a few seconds later means the attempt failed and `manualPhase` says so.
    func updateNow(version: String) async {
        guard manualPhase != .working else { return }
        #if DEBUG
            manualPhase = .failed(String(localized: "In-app updates are disabled in development builds."))
        #else
            manualPhase = .working
            defer { refresh() }
            do {
                switch try await activity.install(version: version, findCandidate: checkCandidate) {
                case .alreadyInstalling:
                    manualPhase = .idle
                case .videoWorkInProgress:
                    manualPhase = .failed(String(localized: "Wait for the current video conversion or optimization to finish, then try again."))
                case .noMatchingDownload:
                    manualPhase = .failed(String(localized: "Couldn't find a download for this update. Get it from the releases page."))
                case .attempted:
                    if activity.isReplacingApp {
                        // Give AppUpdater's scheduled termination time to run.
                        try? await Task.sleep(for: .seconds(4))
                    }
                    manualPhase = .failed(String(localized: "The update couldn't be installed. Try again, or get it from the releases page."))
                }
            } catch {
                Log.update.error("could not prepare Phosphene \(version, privacy: .public): \(error.localizedDescription, privacy: .public)")
                manualPhase = .failed(String(localized: "Couldn't download the update. Check your connection, or get it from the releases page."))
            }
        #endif
    }

    /// The user has seen the failure notice (the version chip was clicked).
    func dismissFailure() {
        if case .failed = manualPhase {
            manualPhase = .idle
        }
    }

    /// The user has seen the post-update notice.
    func acknowledgeUpdate() {
        if tiptoe.justUpdatedTo == justUpdatedVersion {
            tiptoe.acknowledge()
        }
        justUpdatedVersion = nil
    }
}

private struct UpdateCheckProgressView: View {
    let cancel: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: 60, height: 60)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 12) {
                Text("Checking for updates…")
                    .font(.headline)
                ProgressView()
                    .progressViewStyle(.linear)
                    .accessibilityLabel("Checking for updates…")
                Button(action: cancel) {
                    Text("Cancel").frame(minWidth: 72)
                }
                .keyboardShortcut(.cancelAction)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(width: 400)
        .fixedSize(horizontal: false, vertical: true)
    }
}
