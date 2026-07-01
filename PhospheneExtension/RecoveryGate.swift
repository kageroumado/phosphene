// Cross-process debounce for the last-resort recovery exit.
//
// When the extension genuinely loses its live desktop render (the WallpaperAgent
// connection drops with no live context left), the only lever to force a fresh
// acquire is to exit so RunningBoard relaunches us and WallpaperAgent re-resolves
// the wallpaper. WallpaperAgent never re-acquires on connection loss by itself —
// acquisition is gated on a desired-state diff that connection liveness isn't part
// of (confirmed by disassembly of WallpaperAgent on macOS 27).
//
// The catch: RunningBoard enforces an exit-loop relaunch backoff (~2 exits within
// ~30s and it stops relaunching the jobspec). That throttle is external and not
// tunable. If we ever exit repeatedly we brick the wallpaper until the user runs
// `killall WallpaperAgent` — which is exactly issue #13's tail. So the recovery
// exit must fire at most once per cooldown window, persisted across the relaunch
// it triggers (an in-memory flag can't survive our own exit).

import Foundation

enum RecoveryGate {
    /// Minimum spacing between recovery exits. Comfortably above RunningBoard's
    /// exit-loop window so a genuine recovery never trips the relaunch throttle.
    private static let cooldown: TimeInterval = 60

    private static var stampURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("phosphene-recovery.timestamp")
    }

    /// Returns `true` if a recovery exit is allowed right now, recording the
    /// attempt so the next one within `cooldown` is suppressed. Returns `false`
    /// when we exited too recently — the caller should stay alive and wait for a
    /// natural rebuild (display/presentation/user change) to re-acquire instead.
    static func shouldExitForRecovery() -> Bool {
        let now = Date()
        if let data = try? Data(contentsOf: stampURL),
           let previous = try? JSONDecoder().decode(Date.self, from: data),
           now.timeIntervalSince(previous) < cooldown {
            return false
        }
        if let data = try? JSONEncoder().encode(now) {
            try? data.write(to: stampURL, options: .atomic)
        }
        return true
    }
}
