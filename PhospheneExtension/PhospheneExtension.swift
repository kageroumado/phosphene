// Extension entry point.
//
// Loads WallpaperExtensionKit via dlopen to register real XPC type classes,
// then swizzles WallpaperSnapshotXPC's encode to bypass the exact NSXPCCoder check.

import AppKit
import ExtensionFoundation
import Foundation

@main
final class PhospheneExtension: NSObject, AppExtension {
    override required init() {
        super.init()

        let frameworkPath = "/System/Library/PrivateFrameworks/WallpaperExtensionKit.framework/WallpaperExtensionKit"
        if let handle = dlopen(frameworkPath, RTLD_LAZY) {
            // Keep handle open — framework must stay loaded for vtable/C-function-pointer validity.
            _ = handle
            extensionLog("INIT (PID: \(ProcessInfo.processInfo.processIdentifier)) — WallpaperExtensionKit loaded")
            verifyRuntimeLayout()
            VideoLibrary.shared.scan()
            observeLibraryChanges()
            observeDisplaySleepWake()
            observeScreenLockState()
            WallpaperPrefs.shared.observeChanges()
            PowerMonitor.shared.startMonitoring()
            Task {
                for await powerState in PowerMonitor.shared.stateChanges() {
                    let state = WallpaperState.shared
                    let prefs = WallpaperPrefs.shared
                    let policy = PlaybackPolicy.compute(
                        presentationMode: state.presentationMode,
                        activityState: state.activityState,
                        userPaused: prefs.userPaused,
                        alwaysPauseDesktop: prefs.alwaysPauseDesktop,
                        pauseWhenOccluded: prefs.pauseWhenOccluded,
                        desktopOccluded: prefs.desktopOccluded,
                        powerState: powerState,
                    )
                    WallpaperState.shared.forEachRenderer { renderer in
                        renderer.applyPolicy(policy)
                    }
                }
            }
        } else {
            let err = String(cString: dlerror())
            extensionLog("INIT (PID: \(ProcessInfo.processInfo.processIdentifier)) — dlopen failed: \(err)")
        }
    }

    /// Startup self-check: confirm the private WallpaperExtensionKit classes the
    /// extension bridges to are present after dlopen. This doesn't fail the
    /// launch — the per-call guards already fail closed — but it surfaces an
    /// unsupported OS/runtime layout in one clear log line up front instead of
    /// as scattered downstream failures, which is the documented manual
    /// compatibility check for OS upgrades.
    private func verifyRuntimeLayout() {
        let critical = [
            "WallpaperRemoteContextXPC",
            "WallpaperSnapshotXPC",
            "WallpaperCreationRequestXPC",
            "WallpaperSettingsViewModelsXPC",
            "WallpaperIDXPC",
        ]
        let missing = critical.filter { objc_getClass($0) == nil }
        if missing.isEmpty {
            extensionLog("  [SelfCheck] Runtime layout OK — all \(critical.count) critical classes present")
        } else {
            extensionLog("  [SelfCheck] UNSUPPORTED RUNTIME — missing: \(missing.joined(separator: ", ")). Rendering/snapshots may be degraded.")
        }
    }


    /// Observe display sleep/wake to stop rendering when no display is awake
    /// and resume on wake with correct policy.
    private func observeDisplaySleepWake() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil, queue: .main
        ) { _ in
            WallpaperState.shared.isDisplayAsleep = true
            WallpaperState.shared.forEachRenderer { renderer in
                renderer.applyPolicy(.paused)
            }
            extensionLog("[Extension] Displays asleep — paused all renderers")
        }
        center.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil, queue: .main
        ) { _ in
            WallpaperState.shared.isDisplayAsleep = false
            Self.recomputeAndApplyPolicy()
            extensionLog("[Extension] Displays awake — recomputed policy (locked: \(WallpaperState.shared.isScreenLocked))")

            // Recompute again after a short delay to catch any pending
            // WallpaperAgent presentation mode updates that arrive after wake.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                Self.recomputeAndApplyPolicy()
            }
        }
    }

    /// Track screen lock state via distributed notifications from loginwindow.
    /// This lets us know the lock screen is showing even before the WallpaperAgent
    /// sends a presentation mode update — fixing the race where a video paused
    /// on the desktop doesn't resume on the lock screen after lid open.
    private func observeScreenLockState() {
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(
            forName: .init("com.apple.screenIsLocked"),
            object: nil, queue: .main
        ) { _ in
            WallpaperState.shared.isScreenLocked = true
            extensionLog("[Extension] Screen locked")
        }
        dnc.addObserver(
            forName: .init("com.apple.screenIsUnlocked"),
            object: nil, queue: .main
        ) { _ in
            WallpaperState.shared.isScreenLocked = false
            Self.recomputeAndApplyPolicy()
            extensionLog("[Extension] Screen unlocked — recomputed policy")
        }
    }

    /// Recompute playback policy from current state and apply to all renderers.
    static func recomputeAndApplyPolicy() {
        let state = WallpaperState.shared
        let prefs = WallpaperPrefs.shared
        let power = PowerMonitor.shared.currentState

        // When we know the screen is locked but the WallpaperAgent hasn't
        // updated the presentation mode yet (e.g., right after display wake),
        // use "locked" to prevent stale desktop-mode policy from blocking
        // lock screen playback.
        let effectiveMode = state.isScreenLocked && state.presentationMode != "locked"
            ? "locked"
            : state.presentationMode

        let policy = PlaybackPolicy.compute(
            presentationMode: effectiveMode,
            activityState: state.activityState,
            userPaused: prefs.userPaused,
            alwaysPauseDesktop: prefs.alwaysPauseDesktop,
            pauseWhenOccluded: prefs.pauseWhenOccluded,
            desktopOccluded: prefs.desktopOccluded,
            powerState: power
        )
        state.forEachRenderer { renderer in
            renderer.applyPolicy(policy)
        }
    }

    /// Listen for Darwin notifications from the main app when it adds/removes videos.
    private func observeLibraryChanges() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            center,
            observer,
            { _, _, _, _, _ in
                VideoLibrary.shared.scan()
                extensionLog("[Extension] Library changed notification received, re-scanned")
            },
            "glass.kagerou.phosphene.libraryChanged" as CFString,
            nil,
            .deliverImmediately,
        )
    }

    var configuration: some AppExtensionConfiguration {
        WallpaperExtensionConfig()
    }
}
