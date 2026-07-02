import Foundation
import os

enum SpiralRecovery {
    /// Darwin notification the main (unsandboxed) app listens for to `killall WallpaperAgent`.
    static let agentStuckNotification = "glass.kagerou.phosphene.agentStuck"

    /// Consecutive empty connections that trigger recovery. Normal operation never produces
    /// consecutive empties (every real connection serves a method, which resets the count),
    /// so this only fires on a genuine spiral. Kept low so we fire while the burst is still
    /// active (before RunningBoard suspends us).
    private static let emptyThreshold = 4
    /// Minimum spacing between recovery signals (an Agent kill+relaunch takes a few seconds).
    private static let recoveryCooldown: TimeInterval = 20.0

    /// Consecutive-empty counter. `withLock` returns the post-increment value so we act
    /// outside the lock.
    private static let counter = OSAllocatedUnfairLock(initialState: 0)

    private static var lastRecoveryURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("phosphene-last-recovery")
    }

    /// A connection served at least one method → the Agent is talking to us normally.
    static func noteHealthyConnection() {
        counter.withLock { $0 = 0 }
    }

    /// A connection was accepted then invalidated without any method call. Signals recovery
    /// synchronously once a run of these hits the threshold.
    static func noteEmptyConnection(pid: Int32) {
        let count = counter.withLock { n -> Int in n += 1; return n }
        guard count >= emptyThreshold else { return }
        recover(pid: pid, count: count)
    }

    private static func recover(pid: Int32, count: Int) {
        if let data = try? Data(contentsOf: lastRecoveryURL),
           let last = Double((String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) {
            let since = Date().timeIntervalSince1970 - last
            if since < recoveryCooldown {
                extensionLog("  [spiral] STUCK (agent pid \(pid), \(count) empty) but signaled \(Int(since))s ago (< \(Int(recoveryCooldown))s cooldown) — holding off")
                return
            }
        }
        try? Data("\(Date().timeIntervalSince1970)".utf8).write(to: lastRecoveryURL)
        extensionLog("  [spiral] STUCK — \(count) consecutive empty connections from agent pid \(pid), no acquire. Signaling app to killall WallpaperAgent.")
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(agentStuckNotification as CFString),
            nil, nil, true,
        )
    }
}
