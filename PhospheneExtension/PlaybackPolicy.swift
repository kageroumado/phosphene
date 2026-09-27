import Foundation

/// How WallpaperAgent is presenting one surface, from the `presentationMode` of an
/// `update` request.
nonisolated enum PresentationMode: Equatable, Sendable, CustomStringConvertible {
    /// The ordinary desktop.
    case `default`
    /// The lock screen.
    case locked
    /// The screensaver slot: ours when a Phosphene choice is the screensaver, a
    /// foreign screensaver covering us otherwise.
    case idle
    case other(String)

    /// Map the agent's enum case name (read via `Mirror`) to a mode.
    init(caseName: String) {
        switch caseName {
        case "default": self = .default
        case "locked": self = .locked
        case "idle": self = .idle
        default: self = .other(caseName)
        }
    }

    var description: String {
        switch self {
        case .default: "default"
        case .locked: "locked"
        case .idle: "idle"
        case let .other(name): name
        }
    }
}

/// Whether WallpaperAgent considers one surface active, from the `activityState` of
/// an `update` request.
nonisolated enum ActivityState: Equatable, Sendable, CustomStringConvertible {
    case active
    /// Every suspended variant: the surface is not being composited.
    case suspended
    case other(String)

    init(caseName: String) {
        if caseName == "active" {
            self = .active
        } else if caseName.contains("suspended") {
            self = .suspended
        } else {
            self = .other(caseName)
        }
    }

    var description: String {
        switch self {
        case .active: "active"
        case .suspended: "suspended"
        case let .other(name): name
        }
    }
}

/// Power, thermal, Game Mode and backlight conditions, sampled by `PowerMonitor`.
nonisolated struct PowerState: Equatable, Sendable, CustomStringConvertible {
    var thermalState: ProcessInfo.ThermalState = .nominal
    var isOnBattery = false
    var batteryLevel: Int = 100
    var isGameModeActive = false
    /// Backlight brightness of the built-in display, 0.0–1.0. 1.0 when there is no
    /// backlit display to read.
    var displayBrightness: Float = 1.0

    var description: String {
        "thermal \(thermalState.rawValue), battery \(isOnBattery ? "\(batteryLevel)%" : "off"), gameMode \(isGameModeActive), brightness \(displayBrightness)"
    }
}

/// How hard one surface may play.
nonisolated enum PlaybackPolicy: Int, Comparable, Sendable {
    case full = 0
    case reduced = 1
    case minimal = 2
    case paused = 3

    static func < (lhs: PlaybackPolicy, rhs: PlaybackPolicy) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Below this brightness the screen is effectively invisible even though
    /// `screensDidSleepNotification` hasn't fired, so playback pauses.
    static let brightnessPauseThreshold: Float = 0.05

    /// Evaluate all conditions and return the most restrictive applicable policy.
    ///
    /// `alwaysPauseDesktop`: the wallpaper plays only on the lock screen (and our own
    /// screensaver); on the desktop it pauses.
    ///
    /// `screenSaverIsOurs`: a Phosphene choice is the active screensaver, so idle
    /// presentation means we are what's on screen and play like the lock screen.
    /// Otherwise idle means a foreign screensaver covers us, and we pause.
    ///
    /// The lock screen never reduces FPS by itself; only power and thermal do.
    static func compute(
        presentationMode: PresentationMode,
        activityState: ActivityState,
        userPaused: Bool,
        alwaysPauseDesktop: Bool,
        pauseWhenOccluded: Bool,
        desktopOccluded: Bool,
        displayHasFullscreenApp: Bool = false,
        screenSaverIsOurs: Bool,
        power: PowerState = PowerState(),
    ) -> PlaybackPolicy {
        var worst: PlaybackPolicy = .full

        // Presentations where the wallpaper fills the screen with nothing over it:
        // the lock screen, and the screensaver when the screensaver is ours.
        let fullScreenPresentation = presentationMode == .locked
            || (presentationMode == .idle && screenSaverIsOurs)

        // --- paused tier ---
        if userPaused {
            worst = max(worst, .paused)
        }
        if power.thermalState == .critical {
            worst = max(worst, .paused)
        }
        if power.batteryLevel < 10 {
            worst = max(worst, .paused)
        }
        if activityState == .suspended {
            worst = max(worst, .paused)
        }
        if presentationMode == .idle, !screenSaverIsOurs {
            worst = max(worst, .paused)
        }
        if power.isGameModeActive {
            worst = max(worst, .paused)
        }
        // The user dimmed the backlight to ~zero. The display is technically awake, so
        // `screensDidSleep` doesn't fire and the agent never switches to idle.
        if power.displayBrightness < Self.brightnessPauseThreshold {
            worst = max(worst, .paused)
        }
        // Desktop occlusion is irrelevant on full-screen presentations.
        if pauseWhenOccluded, desktopOccluded, !fullScreenPresentation {
            worst = max(worst, .paused)
        }
        // A fullscreen app owning the display pauses unconditionally: the wallpaper is
        // invisible and the app wants the hardware. Catches what Game Mode can't —
        // gamepolicyd never recognizes Wine games.
        if displayHasFullscreenApp, !fullScreenPresentation {
            worst = max(worst, .paused)
        }
        if alwaysPauseDesktop, !fullScreenPresentation {
            worst = max(worst, .paused)
        }

        // --- minimal tier ---
        if power.thermalState == .serious {
            worst = max(worst, .minimal)
        }
        if power.isOnBattery, power.batteryLevel < 20 {
            worst = max(worst, .minimal)
        }

        // --- reduced tier ---
        if power.thermalState == .fair {
            worst = max(worst, .reduced)
        }
        if power.isOnBattery {
            worst = max(worst, .reduced)
        }

        return worst
    }
}
