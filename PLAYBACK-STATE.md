# Playback state

How the extension decides whether each wallpaper surface plays, and how that decision reaches the video pipeline.

## Shape

```
 sources ──PlaybackEvent──▶ PlaybackStore.send  (main actor, serial)
                              │
                              ├─ PlaybackReducer.reduce(state, event) -> state      pure
                              ├─ PlaybackReducer.targets(state) -> [SurfaceKey: SurfaceTarget]   pure
                              │     └─▶ one SurfaceTargetCell per surface (@Observable)
                              │            └─▶ Observations ─▶ VideoRenderer.apply  (renderer queue)
                              └─ PlaybackReducer.published(state) ─▶ Observations ─▶ phosphene-state.json
```

| File | Role |
|---|---|
| `PlaybackPolicy.swift` | `PlaybackPolicy.compute`: the leaf decision from one surface's presentation plus environment. Typed `PresentationMode`, `ActivityState`, `PowerState`. |
| `PlaybackModel.swift` | `PlaybackState`, `PlaybackEvent`, `SurfaceTarget`, `PublishedState`, and `PlaybackReducer`. Pure, compiled into the test target. |
| `PlaybackStore.swift` | The only owner of `PlaybackState`. Runs the reducer, keeps one observable target cell per surface, makes renderers follow their cell, publishes the state file. |
| `SystemEvents.swift`, `PrefsSource.swift`, `PowerMonitor.swift` | Event sources: display sleep/wake, loginwindow lock/unlock, the app's prefs file, power/thermal/Game Mode/backlight. |
| `WallpaperXPCHandler.swift` | The agent protocol. Emits `surfaceAcquired`, `agentUpdate`, `surfaceRemoved`, `shufflePicked`, `videoRemoved`. |
| `SurfaceRegistry.swift` | Resources only: remote `CAContext`, root layer, renderer per surface, and the WallpaperID → surface map. |
| `VideoRenderer.swift` | The AVFoundation pipeline. Its pause, ramp, and deep-pause state is confined to its own serial queue. |

## Rules the design enforces

- **One writer.** `PlaybackState` changes only in `PlaybackReducer.reduce`, called only from `PlaybackStore.send` on the main actor. Sources on other threads use `PlaybackStore.post`, which is FIFO per thread.
- **Presentation is per surface.** Each WallpaperID (Space, lock screen, Settings preview) keeps its own `mode` and `activity`, taken from the `update` addressed to it. A preview's `idle` cannot pause the desktop.
- **Everything is an input to the policy.** Display sleep, the loginwindow lock, per-display prefs and power are all read by `PlaybackReducer.target`, so no path can resume playback that another input requires paused.
- **Level-triggered renderers.** A renderer never receives commands, only its surface's current target, via `Observations`. `PlaybackStore.follow` applies the current target before `start()`, so a renderer attached after a lock, pause or sleep starts in the right state. Bursts coalesce: the renderer sees the latest target, not every intermediate one.
- **Ramps are part of the target.** The event that changed a surface decides whether the change ramps: a presentation change in lock-screen-only mode, or a window-coverage change. Everything else cuts.
- **Published state is derived.** The current video is the choice of the newest live desktop surface, falling back to the last one seen. The agent does not send `selectedChoicesDidChange` to third-party providers on macOS 27.

## Threads

- Main actor: the store, target cells, follower tasks, the publisher.
- `Lifecycle.queue`: all agent lifecycle XPC (acquire, update, invalidate, removal), serialized so an invalidate cannot interleave with an acquire.
- Each renderer's `DispatchQueue`: AVFoundation media requests, flush callbacks, ramp and deep-pause timers. `apply` and `switchVideo` hop onto it; `start()` bridges to async with a checked continuation that resumes once the first frame is on screen, which is what the deferred acquire reply awaits.

## Testing

`PhospheneTests/PlaybackReducerTests.swift` replays event sequences through the pure reducer, one test per field report or defect of the previous model. New behavior starts there: write the event sequence that reproduces it, then change the reducer or `PlaybackPolicy.compute`.
