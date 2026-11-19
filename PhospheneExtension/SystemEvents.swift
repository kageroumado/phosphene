import AppKit
import CoreGraphics

/// Delivers system appearance, sleep and session changes independently of the video clock.
final class SystemEvents: NSObject {
    private static func refreshAppearance(from source: String) {
        let domain = kCFPreferencesAnyApplication
        let user = kCFPreferencesCurrentUser
        let host = kCFPreferencesAnyHost
        CFPreferencesSynchronize(domain, user, host)
        let style = CFPreferencesCopyValue("AppleInterfaceStyle" as CFString, domain, user, host) as? String
        let dark = style == "Dark"
        extensionLog("[Appearance] \(source): system \(dark ? "dark" : "light")")
        PlaybackStore.post(.systemAppearanceChanged(dark: dark))
    }

    @objc
    private static func systemAppearanceDidChange(_: Notification) {
        refreshAppearance(from: "Theme notification")
    }

    static func start() {
        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(
            self,
            selector: #selector(systemAppearanceDidChange(_:)),
            name: .init("AppleInterfaceThemeChangedNotification"),
            object: nil,
            suspensionBehavior: .deliverImmediately,
        )
        refreshAppearance(from: "Startup")
        PlaybackStore.post(.screenLockChanged(isScreenLockedNow()))

        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { _ in
            extensionLog("[Extension] Displays asleep")
            PlaybackStore.post(.displaysAsleepChanged(true))
        }
        workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { _ in
            extensionLog("[Extension] Displays awake")
            PlaybackStore.post(.displaysAsleepChanged(false))
            refreshAppearance(from: "Wake")
            ShuffleController.shared.noteWake()
        }

        // loginwindow reports the lock before WallpaperAgent updates any surface, which
        // is what lets the lock screen start playing without waiting on the agent.
        distributed.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { _ in
            extensionLog("[Extension] Screen locked")
            PlaybackStore.post(.screenLockChanged(true))
        }
        distributed.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { _ in
            extensionLog("[Extension] Screen unlocked")
            PlaybackStore.post(.screenLockChanged(false))
            refreshAppearance(from: "Unlock")
            ShuffleController.shared.noteWake()
        }
    }

    /// The lock state at launch, before any notification arrives.
    private static func isScreenLockedNow() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session["CGSSessionScreenIsLocked"] as? Bool ?? false
    }
}
