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
            // Push current view models shortly after launch: the extension is only
            // ever spawned by a host connection, and the host's disk cache may
            // predate library changes made while no extension process was alive to
            // push them (issue #27). The delay lets the spawning connection's
            // accept() register its proxy first.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                Task { await SettingsPush.push() }
            }
            SystemEvents.start()
            PrefsSource.start()
            PowerMonitor.shared.startMonitoring()
            Task(name: "Power events") {
                for await power in PowerMonitor.shared.stateChanges() {
                    PlaybackStore.post(.powerChanged(power))
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { PlaybackStore.shared.startPublishing() }
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
                SettingsPush.libraryDidChange()
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
