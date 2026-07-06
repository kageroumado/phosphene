# Contributing

Bug reports and fixes are welcome. Phosphene rides on top of Apple's private
`WallpaperExtensionKit`, so the most valuable contributions are the ones grounded
in what actually happens on real hardware — not what should happen in theory.

## Bugs

Open an issue with the Bug report template. The single most useful thing you can
attach is the extension log:

```
~/Library/Containers/glass.kagerou.phosphene.extension/Data/Documents/extension.log
```

If the default log is inconclusive, enable verbose logging, reproduce once, and
attach the fuller log:

```sh
touch ~/Library/Containers/glass.kagerou.phosphene.extension/Data/Documents/VERBOSE_LOG
killall WallpaperAgent            # relaunches the extension so it picks up the flag
# ... reproduce ...
trash ~/Library/Containers/glass.kagerou.phosphene.extension/Data/Documents/VERBOSE_LOG
killall WallpaperAgent
```

Security-sensitive issues shouldn't go in public issues — report them privately
to [@kageroumado on X](https://x.com/kageroumado).

## Build

Open in Xcode and Run the **Phosphene** scheme:

```sh
open Phosphene.xcodeproj
```

Or a headless compile check without local signing identities:

```sh
xcodebuild -project Phosphene.xcodeproj -scheme Phosphene -configuration Debug \
  -destination 'generic/platform=macOS' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' build
```

The project uses synchronized filesystem groups, so adding or removing files in
`Phosphene/` or `PhospheneExtension/` needs no pbxproj edits.

## Style

SwiftFormat (`.swiftformat`) and SwiftLint (`.swiftlint.yml`). Run both before
committing:

```sh
swiftformat .
swiftlint
```

## Layout

- `Phosphene/` — the SwiftUI menu-bar app. Manages the on-disk video library,
  transcodes optional lower-resolution variants, exposes preferences, and posts
  a Darwin notification when the library changes. Not sandboxed; it writes
  directly into the extension's container.
- `PhospheneExtension/` — the wallpaper extension that runs inside the system
  `WallpaperAgent` process. Loads `WallpaperExtensionKit` at runtime, registers
  as a provider, and renders frames into a remote `CAContext`. Sandboxed.
- `PlaybackPolicy` — the single source of truth for playback behavior. Thermal
  state, battery, presentation mode, occlusion, and user pause collapse to one
  of `full / reduced / minimal / paused`. Route new behavior through here rather
  than special-casing it in the renderer.
- `VideoRenderer` — the decode pipeline. Drives `AVSampleBufferDisplayLayer`
  manually (not `AVPlayerLayer`, which fails silently in a remote `CAContext`)
  with a preloaded next-loop reader and a growing PTS offset for gapless loops.

The runtime quirks that keep this working — the `WallpaperSnapshotXPC` encoder
swizzle, the `Mirror`-based XPC parsing, advisory variants — are documented in
the README's "Quirks worth knowing". Read those before touching acquire,
teardown, or snapshot code.

## Pull requests

Use the template. Reference the issue you fix and keep it focused. Because
Phosphene drives Apple's `WallpaperAgent`, behavior is hard to unit-test —
**exercise it on real hardware, not just a build**: fresh agent restart, rapid
switching in System Settings, sleep/wake, and multi-display / per-Space if the
change could touch those. `swiftformat --lint .` must pass. Fill in the
Authorship section: agent, model, and whether the session was attended or
automatic.

Contributions are MIT-licensed.
