import Foundation
import Observation
import Tiptoe
import TiptoeGitHub

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
/// With auto-update off, the daily check still runs but only reports: nothing is downloaded,
/// and nothing is swapped except through ``updateNow()``, which performs the same
/// download-verify-swap on demand.
@MainActor
@Observable
final class SilentUpdates {
    static let shared = SilentUpdates()

    static let owner = "kageroumado"
    static let repo = "phosphene"

    /// Matches `UpdateCheckService`'s cadence — finding an update sooner would not install it
    /// sooner anyway.
    private static let checkInterval: TimeInterval = 60 * 60 * 24

    /// Progress of a user-initiated install, for the version chip. A successful install replaces
    /// the process, so the only terminal state this side of the swap is `.failed`.
    enum ManualPhase: Equatable {
        case idle
        case working
        case failed(String)
    }

    private(set) var manualPhase: ManualPhase = .idle

    /// The version the automatic path has downloaded and is holding for a quiet moment, if any.
    /// Refreshed by ``refreshPending()`` — Tiptoe itself is not observable.
    private(set) var pendingVersion: String?

    /// The version a silent (or manual) install brought us to, until the user has seen the
    /// notice. Read from Tiptoe's store at launch; cleared by ``acknowledgeUpdate()``.
    private(set) var justUpdatedVersion: String?

    /// The updater: daily check loop, plus the quiet-moment install when auto-update is on.
    /// Created up front so its `Tiptoe` reconciles the recorded wait (and surfaces
    /// `justUpdatedTo`) before the loop starts.
    @ObservationIgnored private let github: TiptoeGitHub

    private init() {
        github = TiptoeGitHub(owner: Self.owner, repo: Self.repo, checkInterval: Self.checkInterval)
            .gate("a video optimization is running") { await Self.noOptimizationRunning() }
        justUpdatedVersion = github.tiptoe.justUpdatedTo
    }

    // MARK: - Automatic installs

    /// Called once at launch with the user's setting.
    func start(autoInstall: Bool) {
        // Never in DEBUG: a development build must not poll GitHub, and must never be swapped
        // out from under Xcode.
        #if !DEBUG
            github.installsAutomatically(autoInstall).start()
        #endif
    }

    /// Reacts to the Auto-Update toggle. Turning it off keeps the check loop but stops the
    /// quiet-moment watcher; a DMG already downloaded stays downloaded but installs only
    /// via ``updateNow()``.
    func setAutoInstall(_ enabled: Bool) {
        github.installsAutomatically(enabled)
        refreshPending()
    }

    /// Copies Tiptoe's pending state into the observable ``pendingVersion``. Called when the
    /// popover appears and after update actions — Tiptoe has no change callback for it.
    func refreshPending() {
        pendingVersion = github.tiptoe.pending?.version
    }

    // MARK: - Update Now

    /// Download (if needed), verify, and install the newest release right away — the user asked.
    /// On success the app relaunches and this never returns to its caller in a meaningful way;
    /// still running a few seconds later means the attempt failed and `manualPhase` says so.
    func updateNow() async {
        guard manualPhase != .working else { return }
        #if DEBUG
            manualPhase = .failed("In-place updating is disabled in development builds.")
        #else
            manualPhase = .working

            guard await github.updateNow() else {
                // `availableVersion` is set only by a check that reached GitHub and found an
                // installable DMG; without it there is nothing to download, whatever the network.
                manualPhase = .failed(
                    github.availableVersion == nil
                        ? "Couldn't find a download for this update. Get it from the releases page."
                        : "Couldn't download the update. Check your connection, or get it from the releases page."
                )
                return
            }

            // A successful swap terminates this process on its own schedule, possibly a beat
            // after the install call returns — wait it out before declaring failure.
            try? await Task.sleep(for: .seconds(4))
            refreshPending()
            manualPhase = .failed("The update couldn't be installed. Try again, or get it from the releases page.")
        #endif
    }

    /// The user has seen the failure notice (the version chip was clicked).
    func dismissFailure() {
        if case .failed = manualPhase { manualPhase = .idle }
    }

    /// The user has seen the post-update notice.
    func acknowledgeUpdate() {
        justUpdatedVersion = nil
        github.tiptoe.acknowledge()
    }

    // MARK: - The gate

    /// Restarting the app mid-optimization would kill the transcode; everything else the app
    /// does survives a restart (the wallpaper extension is its own process). A missing manager
    /// answers "not safe" — an update is never so urgent that it is worth guessing.
    private static func noOptimizationRunning() async -> Bool {
        guard let manager = PhospheneManager.shared else { return false }
        return !manager.isOptimizing
    }
}
