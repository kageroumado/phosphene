# phosphene reference

[Overview](README.md)

## Architecture

```
┌─────────────────────────┐         ┌──────────────────────────────┐
│  Phosphene.app          │         │  PhospheneExtension.appex     │
│  (menu bar UI)          │         │  (host: WallpaperAgent)       │
│                         │         │                              │
│  • Library management   │  Darwin │  • XPC handler                │
│  • Per-video metadata   │ ──────▶ │  • AVSampleBufferDisplayLayer │
│  • Optimization (HEVC)  │  notif. │  • Power / thermal monitor    │
│  • Preferences          │         │  • Snapshot generator         │
└─────────────────────────┘         └──────────────────────────────┘
                  │                              │
                  └──────────────┬───────────────┘
                                 ▼
                  Extension sandbox container
                  (~/Library/Containers/glass.kagerou.phosphene.extension
                       /Data/Documents)
                  • Video library + variants
                  • WallpaperPrefs.plist
                  • BMP snapshot cache
```

> **Storage model.** The extension is sandboxed; the menu-bar app is not. The
> app writes the shared library directly into the extension's sandbox container
> (the path above) and signals changes via a Darwin notification. This is a
> deliberate, documented contract rather than an App Group container — the app's
> only job is to populate the directory the extension reads from.

**App side** (`Phosphene/`) — SwiftUI menu-bar app. Manages the on-disk video library, transcodes optional lower-resolution variants via `VideoOptimizationService`, exposes preferences, and posts a Darwin notification when the library changes.

**Extension side** (`PhospheneExtension/`) — runs inside the system `WallpaperAgent` process when a Phosphene wallpaper is active. Loads `WallpaperExtensionKit.framework` at runtime, registers as a wallpaper provider, and renders frames into a remote `CAContext` via `AVSampleBufferDisplayLayer`. It receives XPC `acquire` / `update` / `invalidate` / `snapshot` calls from `WallpaperAgent` and routes presentation-mode changes through `PlaybackPolicy`.

**`PlaybackPolicy`** is the single source of truth for playback behavior. Inputs (thermal state, battery, presentation mode, user pause, occlusion, etc.) collapse to one of `full / reduced / minimal / paused`. Events reach it through a reducer and one observable target per surface; see [PLAYBACK-STATE.md](PLAYBACK-STATE.md).

**`VideoRenderer`** owns the decode pipeline. Instead of `AVPlayerLayer` — which silently fails inside a remote `CAContext` — it drives `AVSampleBufferDisplayLayer` manually: one `AVAssetReader` for the current loop, a preloaded one for the next, and a PTS offset that grows across loops to keep the timeline monotonically increasing. Result is glitch-free looping without flushing the renderer.

## Reporting

Release imports the existing `usageCounting` preference once. The explicit values `off`, `counting`, `crashesOnly`, and `crashReports` keep their meaning. Release keeps its statistics registration under `Application Support/Phosphene/Digoxin`. Digoxin's change from the combined tier to counting discards unsent crash reports on that registration. Already-sent reports on the combined registration can only be removed with that registration by turning off **Count this Mac**. An earlier separate crash registration under `CrashReports/Digoxin` is retired through the original `phosphene` route, which clears its queue and requests server deletion. New crash reporting starts at the migration or opt-in time, with its own registration under `phosphene-crashes/Digoxin`. Release requires a matching bundle ID and an executable slice UUID seen by a Release build during the current crash-reporting grant. This also accepts reports from previously seen Release slices after an update. Reports from unknown slices, including older Release builds that never recorded their UUID, are skipped.

Debug keeps its reporting choices, deletion state, and queues under `Application Support/Phosphene/Debug`. It asks for fresh consent and retires any earlier Debug queues tied to the shared preference. Both settings use `PHOSPHENE_DIGOXIN_URL` (default `http://127.0.0.1:9130/api/digoxin`). Debug skips macOS crash log discovery because both builds use the same bundle identifier.

### Digoxin service setup

Add `phosphene-crashes` to the service's `apps` map with the same `app_attest_id` as `phosphene` and a `crash_reports.min_trust` that accepts the intended release signatures. If the crash app uses DeviceCheck, use the team's key and leave its `device_check.registered_bit` unset. This permits device verification without marking the statistics registration bit. Leave the existing `phosphene` registration and its bit in place for statistics and deletion of historic data. For an isolated local service, configure both app slugs and omit DeviceCheck. The client uses Digoxin's normal attestation and transport in both builds.

An unknown app returns 404. Digoxin 0.3.0 reports the failure and retries queued data on the next launch, within its seven-day queue lifetime. Reports are claimed on disk before handoff to Digoxin. An interruption before enqueue can lose a report. An ambiguous HTTP response still needs a stable report ID accepted by Digoxin and deduplicated by the service to prevent duplicate uploads.

Digoxin 0.3.0 signs deletion once, destroys the identity, then drops the request when the server confirms or permanently rejects it. The server accepts these signatures for up to 30 days. A durable deletion outcome requires Digoxin to expose confirmation, rejection, and expiry to the app. Deletion after prolonged offline use also needs an authenticated retry mechanism whose authorization outlives the current signature window.

## Quirks worth knowing

- **`WallpaperSnapshotXPC` swizzle.** The system's snapshot encoder checks `type(of: coder) == NSXPCCoder.self`, but the real coder is a subclass. Without the runtime swizzle in `PhospheneExtension.swift`, snapshots silently encode to nothing and you get a grey lock screen during transitions.
- **Mirror-based XPC parsing.** Apple's request types (`WallpaperCreationRequestXPC` etc.) aren't part of any public SDK header. The extension reads them via `Mirror` reflection. If Apple renames fields, expect surgical breakage.
- **Variants are advisory.** A "1080p@30" variant won't be selected if Power-Monitor thinks we're on AC and idle — `PlaybackPolicy` always picks the highest tier that's still allowed.

## Troubleshooting

The extension writes a rotating log (1 MB × 3) to:

```
~/Library/Containers/glass.kagerou.phosphene.extension/Data/Documents/extension.log
```

By default it records only the meaningful events — wallpaper switches, presentation/state
changes, teardowns, spiral-of-death recovery, and errors. The high-volume internals
(per-frame feed ticks, renderer restart steps, per-connection XPC churn, snapshots) are
gated behind **verbose logging**.

### Enable verbose logging

Create a marker file in the extension's container, then restart the wallpaper agent so the
extension relaunches and picks it up:

```sh
touch ~/Library/Containers/glass.kagerou.phosphene.extension/Data/Documents/VERBOSE_LOG
killall WallpaperAgent
```

Disable it again by removing the marker and restarting the agent:

```sh
trash ~/Library/Containers/glass.kagerou.phosphene.extension/Data/Documents/VERBOSE_LOG   # or rm
killall WallpaperAgent
```

Attach the (verbose) log to a bug report — see `.github/ISSUE_TEMPLATE`.

### Wallpaper stuck, grey, or showing the wrong video

Rapidly switching video wallpapers in System Settings can wedge the system `WallpaperAgent`
(an Apple-side state desync, not Phosphene's renderer). Phosphene detects this and auto-heals
by restarting the agent, but if a wallpaper is ever stuck, grey, or showing the wrong clip,
use the menu bar → **Restart Wallpaper Agent** to recover immediately (equivalent to
`killall WallpaperAgent`).

### Settings preview shows the system default (Golden Gate) while a video is selected

`WallpaperAgent` caches the LaunchServices record of the extension it last launched. After
a rebuild or archive registers a new copy of `PhospheneExtension.appex` and that copy is
later deleted, the agent keeps launching the deleted path: every new acquire (the System
Settings preview, a new Space) fails with `Failed to create Wallpaper:
com.apple.extensionKit.errorDomain (2)` in the unified log and the resolver substitutes the
default Aerial. The desktop keeps playing because its surface was acquired earlier.
Re-register the installed app and restart the agent:

```sh
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Phosphene.app
killall WallpaperAgent
```
