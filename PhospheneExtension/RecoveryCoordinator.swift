// Owns the single pending recovery task armed after a live-render loss.
//
// When our connection to WallpaperAgent drops mid-render we tear the context down
// immediately (so the Agent falls back to its own cached BMP snapshot, its normal
// bridge) and arm a delayed recovery: if nothing re-acquires within the grace
// window — the genuine quiescent case (deep standby / hibernation), where the
// Agent won't re-acquire on its own — we exit so RunningBoard relaunches us into a
// fresh acquire (issue #2).
//
// There is at most ONE pending task. A newer loss supersedes the previous
// (cancel), and a new live render cancels it outright. `try await Task.sleep`
// throws on cancellation, so a superseded task aborts at the sleep instead of
// waking to contend — and a monotonic token stops a task that already passed its
// sleep from acting after it was superseded.

import Foundation
import os

final class RecoveryCoordinator: Sendable {
    static let shared = RecoveryCoordinator()

    private struct State {
        var task: Task<Void, any Error>?
        var token = 0
    }
    private let lock = OSAllocatedUnfairLock(initialState: State())

    /// Arm `recover` to run after `grace`, superseding any pending recovery.
    func arm(grace: Duration, recover: @escaping @Sendable () -> Void) {
        let oldTask = lock.withLock { state -> Task<Void, any Error>? in
            let previous = state.task
            state.token += 1
            let token = state.token
            state.task = Task<Void, any Error> {
                try await Task.sleep(for: grace)
                guard RecoveryCoordinator.shared.claim(token) else { return }
                recover()
            }
            return previous
        }
        oldTask?.cancel()
    }

    /// Cancel any pending recovery — a live render is up, so no recovery is needed.
    func cancel() {
        let task = lock.withLock { state -> Task<Void, any Error>? in
            let t = state.task
            state.task = nil
            state.token += 1 // invalidate any task already past its sleep
            return t
        }
        task?.cancel()
    }

    /// A task calls this after its grace elapses. Returns `true` only if it is
    /// still the current task (not superseded or cancelled), in which case the
    /// slot is cleared and the caller proceeds with the recovery decision.
    private func claim(_ token: Int) -> Bool {
        lock.withLock { state in
            guard state.token == token else { return false }
            state.task = nil
            return true
        }
    }
}
