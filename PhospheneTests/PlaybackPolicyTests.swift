import Foundation
import Testing

/// Table tests for the policy state machine. Every input models a system signal,
/// but the decision itself is a pure function — this is where the field bugs
/// lived (the fullscreen-app tier, its lock-screen exemption, occlusion gating).
@MainActor
struct PlaybackPolicyTests {
    /// `compute` with the quiet-desktop defaults; tests override one axis each.
    private func policy(
        presentationMode: String = "desktop",
        activityState: String = "active",
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
            thermalState: thermalState,
            isOnBattery: isOnBattery,
            batteryLevel: batteryLevel,
            isGameModeActive: isGameModeActive,
            displayBrightness: displayBrightness,
        )
    }

    @Test func quietDesktopPlaysFull() {
        #expect(policy() == .full)
    }

    @Test func userPausePauses() {
        #expect(policy(userPaused: true) == .paused)
    }

    @Test func gameModePauses() {
        #expect(policy(isGameModeActive: true) == .paused)
    }

    // MARK: - Fullscreen app tier

    @Test func fullscreenAppPausesWithoutTheOcclusionSetting() {
        #expect(policy(displayHasFullscreenApp: true) == .paused)
    }

    @Test func fullscreenAppIsIrrelevantOnTheLockScreen() {
        #expect(policy(presentationMode: "locked", displayHasFullscreenApp: true) == .full)
    }

    @Test func fullscreenAppIsIrrelevantWhenOurScreensaverPresents() {
        #expect(policy(presentationMode: "idle", displayHasFullscreenApp: true, screenSaverIsOurs: true) == .full)
    }

    // MARK: - Occlusion tier (gated by the setting)

    @Test func occlusionAloneDoesNotPause() {
        #expect(policy(desktopOccluded: true) == .full)
    }

    @Test func occlusionPausesWhenTheSettingIsOn() {
        #expect(policy(pauseWhenOccluded: true, desktopOccluded: true) == .paused)
    }

    @Test func occlusionIsIrrelevantOnTheLockScreen() {
        #expect(policy(presentationMode: "locked", pauseWhenOccluded: true, desktopOccluded: true) == .full)
    }

    // MARK: - Lock-screen-only mode

    @Test func lockScreenOnlyPausesOnTheDesktop() {
        #expect(policy(alwaysPauseDesktop: true) == .paused)
    }

    @Test func lockScreenOnlyPlaysOnTheLockScreen() {
        #expect(policy(presentationMode: "locked", alwaysPauseDesktop: true) == .full)
    }

    // MARK: - Idle presentation (screensaver)

    @Test func foreignScreensaverPauses() {
        #expect(policy(presentationMode: "idle") == .paused)
    }

    @Test func ourScreensaverPlaysFull() {
        #expect(policy(presentationMode: "idle", screenSaverIsOurs: true) == .full)
    }

    // MARK: - Power tiers

    @Test func thermalTiers() {
        #expect(policy(thermalState: .fair) == .reduced)
        #expect(policy(thermalState: .serious) == .minimal)
        #expect(policy(thermalState: .critical) == .paused)
    }

    @Test func batteryTiers() {
        #expect(policy(isOnBattery: true) == .reduced)
        #expect(policy(isOnBattery: true, batteryLevel: 19) == .minimal)
        #expect(policy(isOnBattery: true, batteryLevel: 9) == .paused)
    }

    @Test func criticalBatteryPausesEvenOnMains() {
        #expect(policy(batteryLevel: 9) == .paused)
    }

    @Test func zeroedBacklightPauses() {
        #expect(policy(displayBrightness: 0.0) == .paused)
        #expect(policy(displayBrightness: PlaybackPolicy.brightnessPauseThreshold) == .full)
    }

    @Test func suspendedActivityPauses() {
        #expect(policy(activityState: "suspended") == .paused)
    }

    /// The tiers combine by severity: the worst applicable one wins.
    @Test func worstConditionWins() {
        #expect(policy(thermalState: .fair, isGameModeActive: true) == .paused)
        #expect(policy(thermalState: .serious, isOnBattery: true) == .minimal)
    }
}
