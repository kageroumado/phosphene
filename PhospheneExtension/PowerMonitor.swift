import Foundation
import IOKit.ps
import notify
import os

final class PowerMonitor: Sendable {
    static let shared = PowerMonitor()

    private let state = OSAllocatedUnfairLock(initialState: PowerState())
    private let continuations = OSAllocatedUnfairLock(initialState: [UUID: AsyncStream<PowerState>.Continuation]())
    private nonisolated(unsafe) var _batteryScheduler: NSBackgroundActivityScheduler?
    private let gameModeToken = OSAllocatedUnfairLock(initialState: NOTIFY_TOKEN_INVALID)

    /// gamepolicyd's state-carrying Darwin notification for Game Mode sessions
    /// (name recovered from the gamepolicyd binary; posted with notify_set_state).
    private static let gameModeNotification = "com.apple.gamepolicy.game-mode-session"

    struct PowerState: Equatable {
        var thermalState: ProcessInfo.ThermalState = .nominal
        var isOnBattery = false
        var batteryLevel: Int = 100
        var isGameModeActive: Bool = false
        /// Backlight brightness of the built-in display, 0.0–1.0. Defaults to 1.0
        /// when the value can't be read (external displays, headless, etc.).
        var displayBrightness: Float = 1.0

        var shouldPause: Bool {
            if thermalState == .critical || thermalState == .serious { return true }
            if isOnBattery, batteryLevel < 20 { return true }
            if displayBrightness < PlaybackPolicy.brightnessPauseThreshold { return true }
            return false
        }
    }

    private init() {}

    /// Current power state snapshot.
    var currentState: PowerState {
        state.withLock { $0 }
    }

    /// Whether power conditions require pausing playback.
    var shouldPause: Bool {
        state.withLock { $0.shouldPause }
    }

    /// AsyncStream that yields whenever any component of power state changes.
    /// Yields the current value immediately upon subscription.
    func stateChanges() -> AsyncStream<PowerState> {
        let (stream, continuation) = AsyncStream.makeStream(of: PowerState.self)
        let id = UUID()
        continuations.withLock { $0[id] = continuation }

        continuation.onTermination = { [weak self] _ in
            self?.continuations.withLock { $0[id] = nil }
        }

        continuation.yield(currentState)
        return stream
    }

    /// Start monitoring power state. Call once at extension startup.
    func startMonitoring() {
        state.withLock {
            $0.thermalState = ProcessInfo.processInfo.thermalState
        }
        updateBatteryState()
        updateBrightnessState()

        // Thermal state — event-driven via notification
        NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil, queue: nil,
        ) { [weak self] _ in
            self?.handleThermalChange()
        }

        // Battery + brightness — OS-managed periodic check.
        // Brightness needs polling because IODisplay doesn't broadcast a
        // notification when the user drags the slider, and `screensDidSleep`
        // doesn't fire when brightness is held at zero manually.
        let scheduler = NSBackgroundActivityScheduler(
            identifier: "glass.kagerou.phosphene.powerCheck",
        )
        scheduler.interval = 30
        scheduler.tolerance = 15
        scheduler.repeats = true
        scheduler.qualityOfService = .utility
        nonisolated(unsafe) let capturedScheduler = scheduler
        scheduler.schedule { [weak self] completion in
            guard let self else {
                completion(.finished)
                return
            }
            if capturedScheduler.shouldDefer {
                completion(.deferred)
                return
            }
            updateBatteryState()
            updateBrightnessState()
            completion(.finished)
        }
        _batteryScheduler = scheduler

        // Game Mode — event-driven via gamepolicyd's state-carrying notification.
        // Reaches the sandboxed extension: com.apple.* notify names aren't filtered.
        var token = NOTIFY_TOKEN_INVALID
        let status = notify_register_dispatch(
            Self.gameModeNotification, &token,
            DispatchQueue.global(qos: .utility),
        ) { [weak self] token in
            self?.updateGameModeState(token: token)
        }
        if status == UInt32(NOTIFY_STATUS_OK) {
            let registered = token
            gameModeToken.withLock { $0 = registered }
            updateGameModeState(token: registered)
        } else {
            extensionLog("[PowerMonitor] Game Mode notify registration failed (status \(status))")
        }

        let thermal = ProcessInfo.processInfo.thermalState.rawValue
        extensionLog("[PowerMonitor] Started (thermal: \(thermal))")
    }

    // MARK: - Private

    private func handleThermalChange() {
        let previous = state.withLock { $0 }
        state.withLock { $0.thermalState = ProcessInfo.processInfo.thermalState }
        let current = state.withLock { $0 }
        guard previous != current else { return }
        extensionLog("[PowerMonitor] Thermal → shouldPause: \(current.shouldPause)")
        yieldToSubscribers(current)
    }

    private func updateBatteryState() {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [Any],
              let first = sources.first,
              let desc = IOPSGetPowerSourceDescription(snapshot, first as CFTypeRef)?.takeUnretainedValue() as? [String: Any]
        else { return }

        let isOnBattery: Bool = if let powerSource = desc[kIOPSPowerSourceStateKey] as? String {
            powerSource == kIOPSBatteryPowerValue
        } else {
            false
        }
        let batteryLevel = desc[kIOPSCurrentCapacityKey] as? Int ?? 100

        let previous = state.withLock { $0 }
        state.withLock { s in
            s.isOnBattery = isOnBattery
            s.batteryLevel = batteryLevel
        }
        let current = state.withLock { $0 }
        guard previous != current else { return }
        extensionLog("[PowerMonitor] Battery → shouldPause: \(current.shouldPause)")
        yieldToSubscribers(current)
    }

    /// Read the built-in display backlight via IORegistry. On systems without a
    /// backlight (Mac mini, Mac Studio, external-only setups) this returns 1.0
    /// so the policy never demotes to paused.
    private func updateBrightnessState() {
        let brightness = Self.readBuiltInBrightness() ?? 1.0
        let previous = state.withLock { $0 }
        state.withLock { $0.displayBrightness = brightness }
        let current = state.withLock { $0 }
        guard previous != current else { return }
        extensionLog("[PowerMonitor] Brightness → \(brightness), shouldPause: \(current.shouldPause)")
        yieldToSubscribers(current)
    }

    /// Returns the built-in backlight brightness in 0.0–1.0, or nil if there is
    /// no backlit display attached.
    private static func readBuiltInBrightness() -> Float? {
        let matching = unsafe IOServiceMatching("AppleBacklightDisplay")
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iter) }

        var brightness: Float?
        while case let service = IOIteratorNext(iter), service != IO_OBJECT_NULL {
            defer { IOObjectRelease(service) }
            guard let propsRef = unsafe IORegistryEntryCreateCFProperty(
                service,
                "IODisplayParameters" as CFString,
                kCFAllocatorDefault,
                0,
            ) else { continue }
            guard let params = unsafe propsRef.takeRetainedValue() as? [String: Any],
                  let brightnessParam = params["brightness"] as? [String: Any],
                  let value = brightnessParam["value"] as? Int,
                  let min = brightnessParam["min"] as? Int,
                  let max = brightnessParam["max"] as? Int,
                  max > min
            else { continue }
            brightness = Float(value - min) / Float(max - min)
            break
        }
        return brightness
    }

    /// A Game Mode session is active while the notification's state is non-zero.
    private func updateGameModeState(token: Int32) {
        var sessionState: UInt64 = 0
        guard notify_get_state(token, &sessionState) == UInt32(NOTIFY_STATUS_OK) else { return }
        let isActive = sessionState != 0
        let previous = state.withLock { $0 }
        state.withLock { $0.isGameModeActive = isActive }
        let current = state.withLock { $0 }
        guard previous != current else { return }
        extensionLog("[PowerMonitor] Game Mode → \(isActive ? "active" : "inactive"), shouldPause via policy")
        yieldToSubscribers(current)
    }

    private func yieldToSubscribers(_ state: PowerState) {
        continuations.withLock { continuations in
            for continuation in continuations.values {
                continuation.yield(state)
            }
        }
    }
}

extension PlaybackPolicy {
    /// Convenience overload that unpacks a `PowerMonitor.PowerState`.
    static func compute(
        presentationMode: String,
        activityState: String,
        userPaused: Bool,
        alwaysPauseDesktop: Bool,
        pauseWhenOccluded: Bool,
        desktopOccluded: Bool,
        displayHasFullscreenApp: Bool = false,
        screenSaverIsOurs: Bool,
        powerState: PowerMonitor.PowerState,
    ) -> PlaybackPolicy {
        compute(
            presentationMode: presentationMode,
            activityState: activityState,
            userPaused: userPaused,
            alwaysPauseDesktop: alwaysPauseDesktop,
            pauseWhenOccluded: pauseWhenOccluded,
            desktopOccluded: desktopOccluded,
            displayHasFullscreenApp: displayHasFullscreenApp,
            screenSaverIsOurs: screenSaverIsOurs,
            thermalState: powerState.thermalState,
            isOnBattery: powerState.isOnBattery,
            batteryLevel: powerState.batteryLevel,
            isGameModeActive: powerState.isGameModeActive,
            displayBrightness: powerState.displayBrightness,
        )
    }
}
