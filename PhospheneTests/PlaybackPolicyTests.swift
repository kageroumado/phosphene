import Foundation
import Testing

/// Table tests for the policy state machine. Every input models a system signal,
/// but the decision itself is a pure function — this is where the field bugs
/// lived (the fullscreen-app tier, its lock-screen exemption, occlusion gating).
@MainActor
struct PlaybackPolicyTests {
    /// `compute` with the quiet-desktop defaults; tests override one axis each.
    private func policy(
        presentationMode: PresentationMode = .default,
        activityState: ActivityState = .active,
        userPaused: Bool = false,
        alwaysPauseDesktop: Bool = false,
        pauseWhenOccluded: Bool = false,
        desktopOccluded: Bool = false,
        displayHasFullscreenApp: Bool = false,
        screenSaverIsOurs: Bool = false,
        thermalState: ProcessInfo.ThermalState = .nominal,
        isOnBattery: Bool = false,
        batteryLevel: Int = 100,
        isGameModeActive: Bool = false,
        displayBrightness: Float = 1.0,
    ) -> PlaybackPolicy {
        PlaybackPolicy.compute(
            presentationMode: presentationMode,
            activityState: activityState,
            userPaused: userPaused,
            alwaysPauseDesktop: alwaysPauseDesktop,
            pauseWhenOccluded: pauseWhenOccluded,
            desktopOccluded: desktopOccluded,
            displayHasFullscreenApp: displayHasFullscreenApp,
            screenSaverIsOurs: screenSaverIsOurs,
            power: PowerState(
                thermalState: thermalState,
                isOnBattery: isOnBattery,
                batteryLevel: batteryLevel,
                isGameModeActive: isGameModeActive,
                displayBrightness: displayBrightness,
            ),
        )
    }

    @Test
    func `quiet desktop plays full`() {
        #expect(policy() == .full)
    }

    @Test
    func `user pause pauses`() {
        #expect(policy(userPaused: true) == .paused)
    }

    @Test
    func `game mode pauses`() {
        #expect(policy(isGameModeActive: true) == .paused)
    }

    // MARK: - Fullscreen app tier

    @Test
    func `fullscreen app pauses without the occlusion setting`() {
        #expect(policy(displayHasFullscreenApp: true) == .paused)
    }

    @Test
    func `fullscreen app is irrelevant on the lock screen`() {
        #expect(policy(presentationMode: .locked, displayHasFullscreenApp: true) == .full)
    }

    @Test
    func `fullscreen app is irrelevant when our screensaver presents`() {
        #expect(policy(presentationMode: .idle, displayHasFullscreenApp: true, screenSaverIsOurs: true) == .full)
    }

    // MARK: - Occlusion tier (gated by the setting)

    @Test
    func `occlusion alone does not pause`() {
        #expect(policy(desktopOccluded: true) == .full)
    }

    @Test
    func `occlusion pauses when the setting is on`() {
        #expect(policy(pauseWhenOccluded: true, desktopOccluded: true) == .paused)
    }

    @Test
    func `occlusion is irrelevant on the lock screen`() {
        #expect(policy(presentationMode: .locked, pauseWhenOccluded: true, desktopOccluded: true) == .full)
    }

    // MARK: - Lock-screen-only mode

    @Test
    func `lock screen only pauses on the desktop`() {
        #expect(policy(alwaysPauseDesktop: true) == .paused)
    }

    @Test
    func `lock screen only plays on the lock screen`() {
        #expect(policy(presentationMode: .locked, alwaysPauseDesktop: true) == .full)
    }

    // MARK: - Idle presentation (screensaver)

    @Test
    func `foreign screensaver pauses`() {
        #expect(policy(presentationMode: .idle) == .paused)
    }

    @Test
    func `our screensaver plays full`() {
        #expect(policy(presentationMode: .idle, screenSaverIsOurs: true) == .full)
    }

    // MARK: - Power tiers

    @Test
    func `thermal tiers`() {
        #expect(policy(thermalState: .fair) == .reduced)
        #expect(policy(thermalState: .serious) == .minimal)
        #expect(policy(thermalState: .critical) == .paused)
    }

    @Test
    func `battery tiers`() {
        #expect(policy(isOnBattery: true) == .reduced)
        #expect(policy(isOnBattery: true, batteryLevel: 19) == .minimal)
        #expect(policy(isOnBattery: true, batteryLevel: 9) == .paused)
    }

    @Test
    func `critical battery pauses even on mains`() {
        #expect(policy(batteryLevel: 9) == .paused)
    }

    @Test
    func `zeroed backlight pauses`() {
        #expect(policy(displayBrightness: 0.0) == .paused)
        #expect(policy(displayBrightness: PlaybackPolicy.brightnessPauseThreshold) == .full)
    }

    @Test
    func `suspended activity pauses`() {
        #expect(policy(activityState: .suspended) == .paused)
    }

    /// The tiers combine by severity: the worst applicable one wins.
    @Test
    func `worst condition wins`() {
        #expect(policy(thermalState: .fair, isGameModeActive: true) == .paused)
        #expect(policy(thermalState: .serious, isOnBattery: true) == .minimal)
    }

    // MARK: - Agent case names

    @Test
    func `agent case names map to typed states`() {
        #expect(PresentationMode(caseName: "locked") == .locked)
        #expect(PresentationMode(caseName: "idle") == .idle)
        #expect(PresentationMode(caseName: "default") == .default)
        #expect(ActivityState(caseName: "active") == .active)
        #expect(ActivityState(caseName: "suspendedWithoutRendering") == .suspended)
    }
}
