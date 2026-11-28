import Foundation

/// Choice identifier of the native "Shuffle All" tile. Acquires carrying it mean
/// "rotate through the library" rather than one fixed video.
let shuffleChoiceID = "shuffle-all"

/// Identifies one hosted wallpaper surface: a distinct `CAContext` that WallpaperAgent
/// hosts in one `CALayerHost`. There is one per WallpaperID UUID, i.e. one per Space,
/// per lock-screen surface, and per Settings preview. A `CAContext` can be hosted in
/// only one `CALayerHost` at a time, so two surfaces sharing one context black each
/// other out; `displayID` is kept for per-display prefs.
nonisolated struct SurfaceKey: Hashable, Sendable, CustomStringConvertible {
    let displayID: UInt32
    let surfaceUUID: UUID

    var description: String {
        "display \(displayID)/\(surfaceUUID.uuidString.prefix(8))"
    }
}

/// Who looks at a surface: the live desktop and lock screen, or a Settings preview.
nonisolated enum SurfaceRole: Equatable, Sendable {
    case desktop
    case preview
}

/// Playback preferences written by the app to `phosphene-prefs.json`.
nonisolated struct PlaybackPrefs: Decodable, Equatable, Sendable {
    var hdrMode: HDRMode = .automatic
    var frameMatchedTransitions = false
    var userPaused = false
    var alwaysPauseDesktop = false
    var pauseWhenOccluded = false
    /// Every display is covered. Written by app versions that predate per-display
    /// occlusion, and still set when all displays are covered.
    var desktopOccluded = false
    var occludedDisplays: Set<UInt32> = []
    /// Displays owned by one fullscreen app (native fullscreen Space or a borderless
    /// fullscreen game).
    var fullscreenDisplays: Set<UInt32> = []
    var pausedDisplays: Set<UInt32> = []
    var screenSaverIsOurs = false

    init() {}

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hdrMode = (try? container.decode(String.self, forKey: .hdrMode)).flatMap(HDRMode.init(rawValue:)) ?? .automatic
        frameMatchedTransitions = try container.decodeIfPresent(Bool.self, forKey: .frameMatchedTransitions) ?? false
        userPaused = try container.decodeIfPresent(Bool.self, forKey: .userPaused) ?? false
        alwaysPauseDesktop = try container.decodeIfPresent(Bool.self, forKey: .alwaysPauseDesktop) ?? false
        pauseWhenOccluded = try container.decodeIfPresent(Bool.self, forKey: .pauseWhenOccluded) ?? false
        desktopOccluded = try container.decodeIfPresent(Bool.self, forKey: .desktopOccluded) ?? false
        occludedDisplays = try container.decodeIfPresent(Set<UInt32>.self, forKey: .occludedDisplays) ?? []
        fullscreenDisplays = try container.decodeIfPresent(Set<UInt32>.self, forKey: .fullscreenDisplays) ?? []
        pausedDisplays = try container.decodeIfPresent(Set<UInt32>.self, forKey: .pausedDisplays) ?? []
        screenSaverIsOurs = try container.decodeIfPresent(Bool.self, forKey: .screenSaverIsOurs) ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case hdrMode
        case frameMatchedTransitions
        case userPaused
        case alwaysPauseDesktop
        case pauseWhenOccluded
        case desktopOccluded
        case occludedDisplays
        case fullscreenDisplays
        case pausedDisplays
        case screenSaverIsOurs
    }

    /// A surface with no known display falls back to the all-displays signals.
    func isUserPaused(displayID: UInt32?) -> Bool {
        userPaused || displayID.map { pausedDisplays.contains($0) } ?? false
    }

    func isOccluded(displayID: UInt32?) -> Bool {
        desktopOccluded || displayID.map { occludedDisplays.contains($0) } ?? false
    }

    func hasFullscreenApp(displayID: UInt32?) -> Bool {
        displayID.map { fullscreenDisplays.contains($0) } ?? !fullscreenDisplays.isEmpty
    }

    /// Whether the window-coverage inputs differ, which is what makes a prefs change
    /// ramp (a window uncovering the desktop) instead of cutting.
    func coverageDiffers(from other: PlaybackPrefs) -> Bool {
        desktopOccluded != other.desktopOccluded
            || occludedDisplays != other.occludedDisplays
            || fullscreenDisplays != other.fullscreenDisplays
    }
}

nonisolated enum PairAppearanceMode: String, CaseIterable, Sendable {
    case automatic
    case light
    case dark

    static let optionID = "appearanceMode"

    func usesDark(systemDark: Bool) -> Bool {
        switch self {
        case .automatic: systemDark
        case .light: false
        case .dark: true
        }
    }
}

/// One surface as the playback model sees it.
nonisolated struct Surface: Equatable, Sendable {
    var displayID: UInt32?
    var role: SurfaceRole
    /// The choice identifier as the agent sent it; `shuffleChoiceID` for shuffle.
    var choice: String?
    var appearance: PairAppearanceMode = .automatic
    var mode: PresentationMode
    var activity: ActivityState
    var awaitingReacquire = false
    /// Whether the event that last touched this surface ramps a policy change it
    /// causes, as opposed to cutting to it.
    var ramps = false
    /// Acquire order. The newest desktop surface is the one the user picked last.
    var generation: Int
}

/// Everything playback depends on. Mutated only by `PlaybackReducer.reduce`.
nonisolated struct PlaybackState: Equatable, Sendable {
    var surfaces: [SurfaceKey: Surface] = [:]
    /// loginwindow's lock state (`com.apple.screenIsLocked`/`Unlocked`).
    var screenLocked = false
    var systemDark = false
    var displaysAsleep = false
    var prefs = PlaybackPrefs()
    var power = PowerState()
    /// The video the shuffle choice currently resolves to.
    var shufflePick: String?
    /// The video of the most recently acquired desktop surface. Outlives the surface,
    /// so the menu bar and snapshot requests still have an answer while every display
    /// is asleep and torn down.
    var lastVideoID: String?
    var nextGeneration = 0
}

/// Every input to playback.
nonisolated enum PlaybackEvent: Sendable, CustomStringConvertible {
    case surfaceAcquired(SurfaceKey, displayID: UInt32?, role: SurfaceRole, choice: String?, appearance: PairAppearanceMode = .automatic)
    case systemAppearanceChanged(dark: Bool)
    case appearanceSelected(SurfaceKey, PairAppearanceMode)
    case surfaceInvalidated(SurfaceKey, isPaired: Bool)
    case surfaceRemoved(SurfaceKey)
    /// A WallpaperAgent presentation update. An unaddressed update applies to all surfaces.
    case agentUpdate(SurfaceKey?, mode: PresentationMode, activity: ActivityState)
    case screenLockChanged(Bool)
    case displaysAsleepChanged(Bool)
    case prefsLoaded(PlaybackPrefs)
    case powerChanged(PowerState)
    case shufflePicked(String?)
    case videoRemoved(String)

    static func agentUpdate(wallpaperUUID: UUID?, resolved key: SurfaceKey?, mode: PresentationMode, activity: ActivityState) -> Self? {
        guard wallpaperUUID == nil || key != nil else { return nil }
        return .agentUpdate(key, mode: mode, activity: activity)
    }

    var description: String {
        switch self {
        case .systemAppearanceChanged: "systemAppearanceChanged"
        case let .appearanceSelected(key, mode): "appearanceSelected(\(key), \(mode))"
        case let .surfaceInvalidated(key, isPaired): "surfaceInvalidated(\(key), paired: \(isPaired))"
        case let .surfaceAcquired(key, _, role, choice, _): "surfaceAcquired(\(key), \(role), \(choice ?? "nil"))"
        case let .surfaceRemoved(key): "surfaceRemoved(\(key))"
        case let .agentUpdate(key, mode, activity): "agentUpdate(\(key.map(\.description) ?? "all"), \(mode), \(activity))"
        case let .screenLockChanged(locked): "screenLockChanged(\(locked))"
        case let .displaysAsleepChanged(asleep): "displaysAsleepChanged(\(asleep))"
        case .prefsLoaded: "prefsLoaded"
        case let .powerChanged(power): "powerChanged(\(power))"
        case let .shufflePicked(id): "shufflePicked(\(id ?? "none"))"
        case let .videoRemoved(id): "videoRemoved(\(id))"
        }
    }
}

/// What one surface's renderer should be doing.
nonisolated struct SurfaceTarget: Equatable, Sendable {
    var policy: PlaybackPolicy
    /// Reach `policy` with a rate ramp rather than a cut.
    var ramps: Bool
    var hdrMode: HDRMode = .automatic
    var frameMatchedTransitions: Bool = false

    var wantsDark = false
    var renderingSuspended = false
    /// A visible lock-screen-only desktop may ease to a stop if the outgoing wallpaper is moving.
    var allowsSelectionPlayback = false

    static let paused = SurfaceTarget(policy: .paused, ramps: false)
}

/// What the extension tells the app through `phosphene-state.json`.
nonisolated struct PublishedState: Equatable, Sendable {
    struct Display: Equatable, Sendable {
        let displayID: UInt32
        let videoID: String?
    }

    var isActive: Bool
    var currentVideoID: String?
    var displays: [Display]
}

/// The pure core: state transitions and everything derived from state.
nonisolated enum PlaybackReducer {
    static func reduce(_ state: PlaybackState, _ event: PlaybackEvent) -> PlaybackState {
        var next = state
        switch event {
        case let .systemAppearanceChanged(dark):
            next.systemDark = dark
        case let .appearanceSelected(key, appearance):
            next.surfaces[key]?.appearance = appearance
        case let .surfaceAcquired(key, displayID, role, choice, appearance):
            next.acquire(key, displayID: displayID, role: role, choice: choice)
            next.surfaces[key]?.appearance = appearance
        case let .surfaceInvalidated(key, isPaired):
            if isPaired {
                next.surfaces[key]?.awaitingReacquire = true
            }
        case let .surfaceRemoved(key):
            next.surfaces[key] = nil
        case let .agentUpdate(key, mode, activity):
            next.update(key, mode: mode, activity: activity)
        case let .screenLockChanged(locked):
            next.setScreenLocked(locked)
        case let .displaysAsleepChanged(asleep):
            next.displaysAsleep = asleep
            next.setRamps { _ in false }
        case let .prefsLoaded(prefs):
            next.load(prefs)
        case let .powerChanged(power):
            next.power = power
            next.setRamps { _ in false }
        case let .shufflePicked(id):
            next.pickShuffle(id)
        case let .videoRemoved(id):
            next.forget(videoID: id)
        }
        return next
    }

    /// The target of every surface.
    static func targets(_ state: PlaybackState) -> [SurfaceKey: SurfaceTarget] {
        state.surfaces.mapValues { target(for: $0, in: state) }
    }

    static func predecessor(of key: SurfaceKey, in state: PlaybackState) -> (key: SurfaceKey, surface: Surface)? {
        guard let current = state.surfaces[key], let displayID = current.displayID,
              let previous = state.surfaces.lazy.filter({ $0.key != key && $0.value.displayID == displayID && $0.value.role == current.role })
                  .max(by: { $0.value.generation < $1.value.generation }),
              previous.value.generation < current.generation, previous.value.activity == .active,
              current.activity == .active, previous.value.mode == current.mode else { return nil }
        return (previous.key, previous.value)
    }

    static func selectionPredecessor(of key: SurfaceKey, in state: PlaybackState) -> SurfaceKey? {
        guard let current = state.surfaces[key], current.role == .desktop,
              target(for: current, in: state).allowsSelectionPlayback,
              let choice = current.choice, let previous = predecessor(of: key, in: state),
              let previousChoice = previous.surface.choice, previousChoice != choice,
              !previous.surface.awaitingReacquire else { return nil }
        return previous.key
    }

    static func target(for surface: Surface, in state: PlaybackState) -> SurfaceTarget {
        let prefs = state.prefs
        let wantsDark = surface.appearance.usesDark(systemDark: state.systemDark)
        if state.displaysAsleep || surface.awaitingReacquire {
            return SurfaceTarget(
                policy: .paused, ramps: false, hdrMode: prefs.hdrMode,
                frameMatchedTransitions: prefs.frameMatchedTransitions, wantsDark: wantsDark, renderingSuspended: true,
            )
        }
        // loginwindow reports the lock before the agent updates the surfaces, and the
        // agent may leave a hidden desktop surface on `default` for the whole lock.
        // An idle (screensaver) presentation stays idle.
        let mode: PresentationMode = state.screenLocked && surface.mode == .default ? .locked : surface.mode
        let lockOnlyDesktop = prefs.alwaysPauseDesktop && mode == .default
        let policy = PlaybackPolicy.compute(
            presentationMode: mode,
            activityState: surface.activity,
            userPaused: prefs.isUserPaused(displayID: surface.displayID),
            alwaysPauseDesktop: prefs.alwaysPauseDesktop && !lockOnlyDesktop,
            pauseForOcclusion: prefs.pauseWhenOccluded && prefs.isOccluded(displayID: surface.displayID),
            displayHasFullscreenApp: prefs.hasFullscreenApp(displayID: surface.displayID),
            screenSaverIsOurs: prefs.screenSaverIsOurs,
            power: state.power,
        )
        return SurfaceTarget(
            policy: lockOnlyDesktop ? .paused : policy, ramps: surface.ramps, hdrMode: prefs.hdrMode,
            frameMatchedTransitions: prefs.frameMatchedTransitions, wantsDark: wantsDark,
            allowsSelectionPlayback: lockOnlyDesktop && policy != .paused && surface.role == .desktop && surface.activity == .active,
        )
    }

    static func published(_ state: PlaybackState) -> PublishedState {
        let desktop = state.surfaces.values.filter { $0.role == .desktop }
        let newest = desktop.max { $0.generation < $1.generation }
        var newestPerDisplay: [UInt32: Surface] = [:]
        for surface in desktop {
            guard let displayID = surface.displayID else { continue }
            if let current = newestPerDisplay[displayID], current.generation > surface.generation {
                continue
            }
            newestPerDisplay[displayID] = surface
        }
        return PublishedState(
            isActive: !desktop.isEmpty,
            currentVideoID: newest.flatMap { resolve($0.choice, in: state) } ?? state.lastVideoID,
            displays: newestPerDisplay
                .sorted { $0.key < $1.key }
                .map { PublishedState.Display(displayID: $0.key, videoID: resolve($0.value.choice, in: state)) },
        )
    }

    /// The video a choice plays: the shuffle choice resolves to the current pick.
    static func resolve(_ choice: String?, in state: PlaybackState) -> String? {
        choice == shuffleChoiceID ? state.shufflePick : choice
    }
}

/// The per-event transitions `PlaybackReducer.reduce` dispatches to.
private nonisolated extension PlaybackState {
    mutating func acquire(_ key: SurfaceKey, displayID: UInt32?, role: SurfaceRole, choice: String?) {
        if var surface = surfaces[key] {
            if surface.awaitingReacquire {
                surface.awaitingReacquire = false
                surface.activity = .active
            }
            surface.displayID = displayID
            surface.role = role
            surface.choice = choice
            surfaces[key] = surface
        } else {
            // A fresh WallpaperID starts in the presentation its predecessor on the same
            // display was in, so a surface acquired mid-lock starts locked.
            let predecessor = surfaces.values
                .filter { $0.role == role && $0.displayID == displayID }
                .max { $0.generation < $1.generation }
            let activity: ActivityState = if let predecessor, !predecessor.awaitingReacquire {
                predecessor.activity
            } else {
                .active
            }
            surfaces[key] = Surface(
                displayID: displayID,
                role: role,
                choice: choice,
                mode: predecessor?.mode ?? .default,
                activity: activity,
                generation: nextGeneration,
            )
            nextGeneration += 1
        }
        if role == .desktop, let video = PlaybackReducer.resolve(choice, in: self) {
            lastVideoID = video
        }
        setRamps { _ in false }
    }

    /// An agent update ramps only a presentation change in lock-screen-only mode, and
    /// only while the surface is active: a suspended surface cuts.
    mutating func update(_ key: SurfaceKey?, mode: PresentationMode, activity: ActivityState) {
        let affected = key.map { [$0] } ?? Array(surfaces.keys)
        let rampsPresentation = prefs.alwaysPauseDesktop && activity == .active
        for key in affected {
            guard var surface = surfaces[key] else { continue }
            surface.ramps = rampsPresentation && surface.mode != mode
            surface.mode = mode
            surface.activity = activity
            surfaces[key] = surface
        }
    }

    mutating func setScreenLocked(_ locked: Bool) {
        guard screenLocked != locked else { return }
        screenLocked = locked
        let lockScreenOnly = prefs.alwaysPauseDesktop
        setRamps { lockScreenOnly && $0.activity == .active }
    }

    mutating func load(_ newPrefs: PlaybackPrefs) {
        let coverageChanged = newPrefs.coverageDiffers(from: prefs)
        prefs = newPrefs
        setRamps { _ in coverageChanged }
    }

    mutating func pickShuffle(_ id: String?) {
        guard id == nil || shufflePick != id else { return }
        shufflePick = id
        if surfaces.values.contains(where: { $0.role == .desktop && $0.choice == shuffleChoiceID }) {
            lastVideoID = id
        }
        setRamps { _ in false }
    }

    mutating func forget(videoID id: String) {
        if lastVideoID == id {
            lastVideoID = nil
        }
        if shufflePick == id {
            shufflePick = nil
        }
        setRamps { _ in false }
    }

    mutating func setRamps(_ ramps: (Surface) -> Bool) {
        for (key, surface) in surfaces {
            surfaces[key]?.ramps = ramps(surface)
        }
    }
}
