# Fullscreen games vs. Phosphene — findings, logs, and wine-game detection heuristics

Field report from Elysia's machine, 2026-08-25. Live reproduction with Genshin
Impact (Wine/Yaagl, borderless 3840×2160 window), Phosphene v1.4.1 release
build, three displays. Companion commit on this branch: Game Mode detection via
`gamepolicyd`'s Darwin notification (`bb361f8`).

## TL;DR

A video wallpaper playing under a fullscreen Wine game costs ~30–55 points of
WindowServer CPU plus a dedicated `VTDecoderXPCService`, and produces
reproducible 1–2 s input lag in the game. **None of Phosphene's three existing
defenses can catch this case**:

1. `isGameModeActive` was hardcoded `false` (dead code) — fixed on this branch,
   but see below: it can never fire for Wine games anyway.
2. The occlusion filter only counts **layer-0** windows. Wine puts the game's
   borderless fullscreen window at **layer 26** (above the menu bar's 24), so
   the covered display reads **0.0% coverage** while the game covers every
   pixel of it.
3. `computeDesktopOcclusion` requires **every** display ≥95% covered. On a
   multi-display setup a game covers one display, so the AND across displays
   never becomes true regardless of #2.

The fix that covers all observed cases: **per-display occlusion with a
layer-aware window filter**. The pause path itself is proven — manually hitting
Paused in the popover erased the entire cost while the game ran (numbers below).

## Observed behavior (live session, in order)

Baseline — Phosphene not running, no game:

```
WindowServer  39.3% CPU
```

Game launched (Wine, Game Mode forced on via gamepolicyctl), still no wallpaper:

```
GenshinImpact.exe  125–302% CPU (login → in-game)
WindowServer       ~39–95% (scene-dependent)
no Phosphene processes, no lag reported
```

Wallpaper set → **input lag reported by the player ~4 minutes later**:

```
PhospheneExtension.appex   5.3% CPU        (up 4:01)
VTDecoderXPCService        9.1% / spawned with the appex (pid 46308)
WindowServer               96.9%           (from 39%)
wineserver                 57.4%           (input path, elevated)
GenshinImpact.exe          302%
Phosphene.app (main app)   52.1%           (separate finding, see below)
```

User hits **Paused** in the menu bar popover (game left running):

```
PhospheneExtension.appex   0.0%
VTDecoderXPCService 46308  0.0%
GenshinImpact.exe          454%            (reclaimed headroom immediately)
```

Popover closed (its live preview was still rendering):

```
Phosphene.app              0.0%            (from 52–58%)
WindowServer               71.5%           (game still playing, healthy)
```

Same signature was seen on 2026-08-22 (68h-old wallpaper session, killing the
appex dropped WindowServer 90–104% → 72%, game 550 → 630%) and 2026-08-23
(fresh 4K wallpaper, kill → WindowServer 56–61%, game 132–165% → 273–300%).
Re-enabling a wallpaper re-arms the problem every time.

## Probe: how the game window presents to CGWindowList

While the game was fullscreen on the 4K display:

```
owner=wine  name="Genshin Impact"  layer=26  bounds={0, 0, 3840, 2160}
CGShieldingWindowLevel = 2147483628
```

Phosphene's occlusion math (grid rasterization, ≥95%), recomputed per display
at the same moment:

```
displayID 4  3840×2160   coverage   0.0%  ← the game is HERE, filtered out (layer 26 ≠ 0)
displayID 1  1728×1085   coverage 100.0%  (ordinary layer-0 windows)
displayID 2  1440×2560   coverage 100.0%
```

So even single-display users get no occlusion pause under a Wine game, and
multi-display users get no pause under any circumstances.

## Probe: Game Mode signals (why the Darwin notification can't cover Wine)

Names recovered from `strings /usr/libexec/gamepolicyd` (macOS 27 beta):

```
com.apple.gamepolicy.game-mode-session
com.apple.gamepolicy.game-session
com.apple.gamepolicy.fullscreenStateChanged
com.apple.gamepolicy.GameExited
com.apple.gamepolicy.game-mode-devices.Display / .HID
```

All are `notify_set_state`-carrying. A `notifyutil -w` watcher on the first
four ran across the entire game launch + play session, **with Game Mode forced
on** (`gamepolicyctl game-mode status` → "Game mode is on. … forced always
on"):

- Zero notifications posted.
- All states stayed `0` throughout.

Conclusion: forcing the *mode* does not create a game *session*; sessions are
what post these notifications, and gamepolicyd never recognizes a Wine process
as a game (no bundle, no `LSApplicationCategoryType`). The notification-based
`isGameModeActive` (commit `bb361f8`) is correct and cheap for **native**
games that macOS recognizes, and worst-case inert — but it cannot be the fix
for Wine/CrossOver/Whisky games.

## Heuristics for detecting wine (and other unrecognized) games

Ranked by recommendation:

1. **Layer-aware, per-display occlusion (recommended — catches everything
   without knowing what a "game" is).** Count a window as occluding when
   `0 <= layer < kCGPopUpMenuWindowLevel (101)` instead of `layer == 0`, and
   pause **per display** at ≥95% coverage of that display. Rationale: opaque
   fullscreen game/video windows land at 0 (native fullscreen Spaces cover the
   display anyway) or slightly above the menu bar (Wine: 26); transient system
   chrome above 100 (popup menus, Notification Center overlays) stays
   excluded. A wallpaper under a covered display is invisible — pausing it is
   always correct, game or not. This alone fixes the observed episodes: the 4K
   decode (the dominant cost) stops the moment the game covers its display.
2. **Drop the all-displays AND.** Independent of #1; without it multi-display
   setups can never pause. The extension already has per-display plumbing
   (`pausedDisplays` in the prefs file + `forRenderers(displayID:)`), so the
   app side can ship `occludedDisplays: Set<UInt32>` the same way.
3. **Keep the Game Mode Darwin notification** (`bb361f8`) as the native-game
   fast path — event-driven, pauses *all* displays, engages even for windowed
   native games in Game Mode. Note the session-state semantics (state != 0 =
   active) are inferred, not yet observed live — worth validating with a
   native game before relying on it.
4. **Wine-specific signals, if an explicit "game detected" badge is ever
   wanted** (all fragile, none needed for the pause decision):
   - `CGWindowListCopyWindowInfo` owner name in {`wine`, `wine64-preloader`,
     `wine-preloader`} — but CrossOver/Whisky/Yaagl rename their loaders.
   - Frontmost app with `bundleIdentifier == nil` + a full-display window at
     an elevated layer + sustained multi-core CPU.
5. **Things verified NOT to work:** `LSApplicationCategoryType` (Wine apps
   have none), reading `gamepolicyctl` (Xcode-only tool, not sandbox-callable,
   and forced-on state ≠ session anyway), waiting for
   `fullscreenStateChanged` (never fired), any assumption that a fullscreen
   game "captures" the display (modern games don't).

## Separate finding: popover live preview burns ~50% CPU (not thumbnails)

While the menu bar popover was open, the main app sat at 52–58% CPU. `sample`
shows the work on worker threads in `vImage` convolution and CoreGraphics
software compositing (`vConvolveCore_Planar8`, `conv4_8_A`,
`A8_image_mark_rgb32`, `vPremultipliedAlphaBlendWithPermute_RGBA8888_CV_vec`)
— i.e. CPU-side scaling/blur of video frames, not GPU. Closing the popover →
0.0% instantly, so it's the live preview path, not background thumbnail or
variant generation. Worth moving the preview onto
`AVSampleBufferDisplayLayer`/Metal or at least capping its frame rate; while a
game is running, an open popover adds a second, hidden competitor.

## Repro notes

- Per-display coverage + window-layer probes: small Swift CLIs replicating
  `OcclusionMonitor`'s exact math per display (see `Prototypes/occprobe.swift`
  in this branch).
- Darwin notification watch: `notifyutil -v -w com.apple.gamepolicy.game-mode-session -w com.apple.gamepolicy.game-session -w com.apple.gamepolicy.fullscreenStateChanged -w com.apple.gamepolicy.GameExited`
- Live lag probe on the test machine: `ps -Ao pid,%cpu,command | grep -iE "phosphene|VTDecoder|wineserver"` — appex + fresh VTDecoder + WindowServer delta is the whole signature.
