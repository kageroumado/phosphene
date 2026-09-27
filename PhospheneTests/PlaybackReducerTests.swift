import Foundation
import Testing

/// Event sequences replayed through the pure reducer. Each test is a field report or a
/// defect of the edge-triggered model this replaced, stated as inputs and the target
/// the renderer must end up following.
@MainActor
struct PlaybackReducerTests {
    private let desktop = SurfaceKey(displayID: 1, surfaceUUID: UUID())
    private let newDesktop = SurfaceKey(displayID: 1, surfaceUUID: UUID())
    private let otherDisplay = SurfaceKey(displayID: 2, surfaceUUID: UUID())
    private let preview = SurfaceKey(displayID: 1, surfaceUUID: UUID())

    private func run(_ events: [PlaybackEvent], from state: PlaybackState = PlaybackState()) -> PlaybackState {
        events.reduce(state, PlaybackReducer.reduce)
    }

    private func policy(_ key: SurfaceKey, _ state: PlaybackState) -> PlaybackPolicy? {
        PlaybackReducer.targets(state)[key]?.policy
    }

    private func ramps(_ key: SurfaceKey, _ state: PlaybackState) -> Bool? {
        PlaybackReducer.targets(state)[key]?.ramps
    }

    private func prefs(_ configure: (inout PlaybackPrefs) -> Void) -> PlaybackEvent {
        var prefs = PlaybackPrefs()
        configure(&prefs)
        return .prefsLoaded(prefs)
    }

    private func acquire(_ key: SurfaceKey, _ choice: String = "A", role: SurfaceRole = .desktop) -> PlaybackEvent {
        .surfaceAcquired(key, displayID: key.displayID, role: role, choice: choice)
    }

    // MARK: - Display sleep

    /// Sleep used to pause renderers directly while the policy ignored it, so the next
    /// recompute of any kind resumed playback on sleeping displays.
    @Test
    func `sleep holds through every other input`() {
        let state = run([
            acquire(desktop),
            .displaysAsleepChanged(true),
            prefs { _ in },
            .powerChanged(PowerState()),
            .agentUpdate(desktop, mode: .default, activity: .active),
            .screenLockChanged(true),
        ])
        #expect(policy(desktop, state) == .paused)
    }

    @Test
    func `wake restores the policy`() {
        let state = run([acquire(desktop), .displaysAsleepChanged(true), .displaysAsleepChanged(false)])
        #expect(policy(desktop, state) == .full)
    }

    // MARK: - Per-surface presentation

    /// A Settings preview's `idle` used to overwrite the one global presentation mode and
    /// pause the lock screen.
    @Test
    func `preview updates do not reach the desktop`() {
        let state = run([
            prefs { $0.alwaysPauseDesktop = true },
            acquire(desktop),
            acquire(preview, role: .preview),
            .agentUpdate(desktop, mode: .locked, activity: .active),
            .agentUpdate(preview, mode: .idle, activity: .active),
        ])
        #expect(policy(desktop, state) == .full)
        #expect(policy(preview, state) == .paused)
    }

    @Test
    func `update for an unknown surface applies to all`() {
        let state = run([
            prefs { $0.alwaysPauseDesktop = true },
            acquire(desktop),
            acquire(otherDisplay),
            .agentUpdate(nil, mode: .locked, activity: .active),
        ])
        #expect(policy(desktop, state) == .full)
        #expect(policy(otherDisplay, state) == .full)
    }

    // MARK: - Lock screen

    /// loginwindow reports the lock before the agent updates any surface; playback
    /// starts on the notification, with a ramp.
    @Test
    func `lock notification plays before the agent updates`() {
        let state = run([
            prefs { $0.alwaysPauseDesktop = true },
            acquire(desktop),
            .screenLockChanged(true),
        ])
        #expect(policy(desktop, state) == .full)
        #expect(ramps(desktop, state) == true)
    }

    @Test
    func `unlock ramps back to paused`() {
        let state = run([
            prefs { $0.alwaysPauseDesktop = true },
            acquire(desktop),
            .screenLockChanged(true),
            .screenLockChanged(false),
        ])
        #expect(policy(desktop, state) == .paused)
        #expect(ramps(desktop, state) == true)
    }

    /// An agent update between lock and unlock used to clear the lock flag, so the
    /// lock screen paused whenever the desktop surface was told `default`.
    @Test
    func `agent default during lock keeps playing`() {
        let state = run([
            prefs { $0.alwaysPauseDesktop = true },
            acquire(desktop),
            .screenLockChanged(true),
            .agentUpdate(desktop, mode: .default, activity: .active),
        ])
        #expect(policy(desktop, state) == .full)
    }

    /// A foreign screensaver over the lock screen still pauses us.
    @Test
    func `lock does not override A foreign screensaver`() {
        let state = run([
            acquire(desktop),
            .screenLockChanged(true),
            .agentUpdate(desktop, mode: .idle, activity: .active),
        ])
        #expect(policy(desktop, state) == .paused)
    }

    /// The field report: a new wallpaper picked while the desktop is hidden, then the
    /// screen locked. The new surface must play on the lock screen.
    @Test
    func `new wallpaper picked while hidden plays on lock`() {
        let hidden = run([
            prefs {
                $0.pauseWhenOccluded = true
                $0.desktopOccluded = true
            },
            acquire(desktop, "A"),
            acquire(newDesktop, "B"),
            .surfaceRemoved(desktop),
        ])
        #expect(policy(newDesktop, hidden) == .paused)

        let locked = run([.screenLockChanged(true)], from: hidden)
        #expect(policy(newDesktop, locked) == .full)
    }

    @Test
    func `new wallpaper picked in lock screen only mode plays on lock`() {
        let state = run([
            prefs { $0.alwaysPauseDesktop = true },
            acquire(desktop, "A"),
            acquire(newDesktop, "B"),
            .screenLockChanged(true),
        ])
        #expect(policy(newDesktop, state) == .full)
    }

    /// A surface acquired while its predecessor is on the lock screen starts locked,
    /// rather than on the desktop default it would otherwise assume.
    @Test
    func `surface acquired mid lock starts locked`() {
        let state = run([
            prefs { $0.alwaysPauseDesktop = true },
            acquire(desktop),
            .agentUpdate(desktop, mode: .locked, activity: .active),
            acquire(newDesktop),
        ])
        #expect(policy(newDesktop, state) == .full)
    }

    // MARK: - Ramps

    @Test
    func `presentation change ramps only in lock screen only mode`() {
        let plain = run([
            acquire(desktop),
            .agentUpdate(desktop, mode: .locked, activity: .active),
        ])
        #expect(ramps(desktop, plain) == false)

        let lockOnly = run([
            prefs { $0.alwaysPauseDesktop = true },
            acquire(desktop),
            .agentUpdate(desktop, mode: .locked, activity: .active),
        ])
        #expect(ramps(desktop, lockOnly) == true)
    }

    @Test
    func `suspended activity cuts`() {
        let state = run([
            prefs { $0.alwaysPauseDesktop = true },
            acquire(desktop),
            .agentUpdate(desktop, mode: .locked, activity: .suspended),
        ])
        #expect(policy(desktop, state) == .paused)
        #expect(ramps(desktop, state) == false)
    }

    @Test
    func `coverage changes ramp and other prefs cut`() {
        let base = run([acquire(desktop), prefs { $0.pauseWhenOccluded = true }])
        let covered = run([prefs {
            $0.pauseWhenOccluded = true
            $0.occludedDisplays = [1]
        }], from: base)
        #expect(policy(desktop, covered) == .paused)
        #expect(ramps(desktop, covered) == true)

        let userPaused = run([prefs {
            $0.pauseWhenOccluded = true
            $0.userPaused = true
        }], from: base)
        #expect(policy(desktop, userPaused) == .paused)
        #expect(ramps(desktop, userPaused) == false)
    }

    @Test
    func `power changes cut`() {
        let state = run([
            prefs { $0.alwaysPauseDesktop = true },
            acquire(desktop),
            .agentUpdate(desktop, mode: .locked, activity: .active),
            .powerChanged(PowerState(thermalState: .critical)),
        ])
        #expect(policy(desktop, state) == .paused)
        #expect(ramps(desktop, state) == false)
    }

    // MARK: - Per-display prefs

    @Test
    func `per display pause leaves other displays playing`() {
        let state = run([acquire(desktop), acquire(otherDisplay), prefs { $0.pausedDisplays = [1] }])
        #expect(policy(desktop, state) == .paused)
        #expect(policy(otherDisplay, state) == .full)
    }

    // MARK: - Published state

    /// The agent never sends `selectedChoicesDidChange` to us on macOS 27, so the
    /// current video comes from the newest desktop surface.
    @Test
    func `current video follows the newest desktop surface`() {
        let state = run([acquire(desktop, "A"), acquire(preview, "C", role: .preview), acquire(newDesktop, "B")])
        let published = PlaybackReducer.published(state)
        #expect(published.currentVideoID == "B")
        #expect(published.isActive)
        #expect(published.displays == [PublishedState.Display(displayID: 1, videoID: "B")])
    }

    @Test
    func `current video outlives teardown`() {
        let state = run([acquire(desktop, "A"), .surfaceRemoved(desktop)])
        let published = PlaybackReducer.published(state)
        #expect(published.currentVideoID == "A")
        #expect(!published.isActive)
    }

    @Test
    func `removed video is forgotten`() {
        let state = run([acquire(desktop, "A"), .surfaceRemoved(desktop), .videoRemoved("A")])
        #expect(PlaybackReducer.published(state).currentVideoID == nil)
    }

    @Test
    func `shuffle resolves to the pick`() {
        let state = run([.shufflePicked("X"), acquire(desktop, shuffleChoiceID), .shufflePicked("Y")])
        #expect(PlaybackReducer.published(state).currentVideoID == "Y")
        #expect(state.lastVideoID == "Y")
    }

    @Test
    func `repeated lock state leaves state unchanged`() {
        let locked = run([acquire(desktop), .screenLockChanged(true)])
        #expect(run([.screenLockChanged(true)], from: locked) == locked)
    }
}
