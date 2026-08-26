import Foundation

/// Central decision-maker for wallpaper playback behavior.
/// Replaces scattered shouldPause boolean checks with a graduated policy system.
enum PlaybackPolicy: Int, Comparable {
    case full = 0
    case reduced = 1
    case minimal = 2
    case paused = 3

    static func < (lhs: PlaybackPolicy, rhs: PlaybackPolicy) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Below this brightness, the screen is effectively invisible to the user
    /// even though `screensDidSleepNotification` hasn't fired. We treat this
    /// as paused so the renderer stops burning battery.
    static let brightnessPauseThreshold: Float = 0.05

    /// Evaluate all conditions and return the most restrictive applicable policy.
    ///
    /// `alwaysPauseDesktop`: when true, wallpaper only plays on the lock screen.
    /// On the desktop (unlocked), it pauses with a ramp animation.
    ///
    /// `screenSaverIsOurs`: a Phosphene choice is the active screensaver, so idle
    /// presentation means WE are what's on screen — play full, like the lock screen.
    /// Without it, idle means a foreign screensaver covers us — pause.
    ///
    /// Lock screen never reduces FPS by itself — only power/thermal conditions do.
    static func compute(
        presentationMode: String,
        activityState: String,
        userPaused: Bool,
        alwaysPauseDesktop: Bool,
        pauseWhenOccluded: Bool,
        desktopOccluded: Bool,
        displayHasFullscreenApp: Bool = false,
        screenSaverIsOurs: Bool,
        thermalState: ProcessInfo.ThermalState,
        isOnBattery: Bool,
        batteryLevel: Int,
        isGameModeActive: Bool,
        displayBrightness: Float = 1.0,
    ) -> PlaybackPolicy {
        var worst: PlaybackPolicy = .full

        // Presentations where the wallpaper fills the screen with nothing over it:
        // the lock screen, and the screensaver when the screensaver is ours.
        let fullScreenPresentation = presentationMode == "locked"
            || (presentationMode == "idle" && screenSaverIsOurs)

        // --- paused tier ---
        if userPaused { worst = max(worst, .paused) }
        if thermalState == .critical { worst = max(worst, .paused) }
        if batteryLevel < 10 { worst = max(worst, .paused) }
        if activityState.contains("suspended") { worst = max(worst, .paused) }
        if presentationMode == "idle", !screenSaverIsOurs { worst = max(worst, .paused) }
        if isGameModeActive { worst = max(worst, .paused) }
        // User dimmed the backlight to ~zero. The display is technically still
        // "awake" so `screensDidSleep` doesn't fire and the WallpaperAgent never
        // switches to "idle", but the user can't see any of it.
        if displayBrightness < Self.brightnessPauseThreshold {
            worst = max(worst, .paused)
        }
        // Desktop occlusion is irrelevant on full-screen presentations — the
        // wallpaper is fully visible there regardless of desktop window state.
        if pauseWhenOccluded, desktopOccluded, !fullScreenPresentation { worst = max(worst, .paused) }
        // A fullscreen app owning the display pauses unconditionally: the wallpaper
        // is invisible (or a menu bar sliver) and the app wants the hardware.
        // Catches what Game Mode can't — gamepolicyd never recognizes Wine games.
        if displayHasFullscreenApp, !fullScreenPresentation { worst = max(worst, .paused) }
        if alwaysPauseDesktop, !fullScreenPresentation { worst = max(worst, .paused) }

        // --- minimal tier ---
        if thermalState == .serious { worst = max(worst, .minimal) }
        if isOnBattery, batteryLevel < 20 { worst = max(worst, .minimal) }

        // --- reduced tier ---
        if thermalState == .fair { worst = max(worst, .reduced) }
        if isOnBattery { worst = max(worst, .reduced) }

        return worst
    }

}
