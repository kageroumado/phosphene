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

    /// Evaluate all conditions and return the most restrictive applicable policy.
    ///
    /// `alwaysPauseDesktop`: when true, wallpaper only plays on the lock screen.
    /// On the desktop (unlocked), it pauses with a ramp animation.
    ///
    /// Lock screen never reduces FPS by itself — only power/thermal conditions do.
    static func compute(
        presentationMode: String,
        activityState: String,
        userPaused: Bool,
        alwaysPauseDesktop: Bool,
        pauseWhenOccluded: Bool,
        desktopOccluded: Bool,
        thermalState: ProcessInfo.ThermalState,
        isOnBattery: Bool,
        batteryLevel: Int,
        isGameModeActive: Bool,
        displayBrightness: Float = 1.0,
    ) -> PlaybackPolicy {
        var worst: PlaybackPolicy = .full

        // --- paused tier ---
        if userPaused { worst = max(worst, .paused) }
        if thermalState == .critical { worst = max(worst, .paused) }
        if batteryLevel < 10 { worst = max(worst, .paused) }
        if activityState.contains("suspended") { worst = max(worst, .paused) }
        if presentationMode == "idle" { worst = max(worst, .paused) }
        if isGameModeActive { worst = max(worst, .paused) }
        // User dimmed the backlight to ~zero. The display is technically still
        // "awake" so `screensDidSleep` doesn't fire and the WallpaperAgent never
        // switches to "idle", but the user can't see any of it.
        if displayBrightness < PowerMonitor.PowerState.brightnessPauseThreshold {
            worst = max(worst, .paused)
        }
        // Desktop occlusion is irrelevant on the lock screen — the wallpaper
        // is always fully visible there regardless of desktop window state.
        if pauseWhenOccluded, desktopOccluded, presentationMode != "locked" { worst = max(worst, .paused) }
        if alwaysPauseDesktop, presentationMode != "locked" { worst = max(worst, .paused) }

        // --- minimal tier ---
        if thermalState == .serious { worst = max(worst, .minimal) }
        if isOnBattery, batteryLevel < 20 { worst = max(worst, .minimal) }

        // --- reduced tier ---
        if thermalState == .fair { worst = max(worst, .reduced) }
        if isOnBattery { worst = max(worst, .reduced) }

        return worst
    }

    /// Generate FPS tiers by repeated halving from a source frame rate.
    ///
    /// Keeps halving until the result is at or below 15 fps. Always produces at least 2 tiers.
    /// Examples: 120 → [120, 60, 30, 15], 60 → [60, 30, 15], 30 → [30, 15], 24 → [24, 12].
    static func fpsTiers(from sourceFPS: Int) -> [Int] {
        guard sourceFPS > 0 else { return [] }
        var tiers = [sourceFPS]
        var current = sourceFPS
        while current > 15 {
            current /= 2
            tiers.append(current)
        }
        if tiers.count < 2 {
            tiers.append(current / 2)
        }
        return tiers
    }

    /// Convenience overload that unpacks a `PowerMonitor.PowerState`.
    static func compute(
        presentationMode: String,
        activityState: String,
        userPaused: Bool,
        alwaysPauseDesktop: Bool,
        pauseWhenOccluded: Bool,
        desktopOccluded: Bool,
        powerState: PowerMonitor.PowerState,
    ) -> PlaybackPolicy {
        compute(
            presentationMode: presentationMode,
            activityState: activityState,
            userPaused: userPaused,
            alwaysPauseDesktop: alwaysPauseDesktop,
            pauseWhenOccluded: pauseWhenOccluded,
            desktopOccluded: desktopOccluded,
            thermalState: powerState.thermalState,
            isOnBattery: powerState.isOnBattery,
            batteryLevel: powerState.batteryLevel,
            isGameModeActive: powerState.isGameModeActive,
            displayBrightness: powerState.displayBrightness,
        )
    }
}
