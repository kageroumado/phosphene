---
name: Bug report
about: Report a problem with Phosphene (wallpaper stuck, grey, wrong video, crash, etc.)
title: ""
labels: ""
assignees: kageroumado
---

## Summary

<!-- One or two sentences: what happens, and when. -->

## Environment

- **Phosphene**: <!-- e.g. 1.2 (from GitHub Release) -->
- **macOS**: <!-- e.g. 26.1 (Build 25B?) -->
- **Hardware**: <!-- e.g. M4 MacBook Air, built-in display + 1 external -->
- **Library size**: <!-- e.g. 2 videos (.mp4, 3840×2160) -->
- **Displays / Spaces**: <!-- single display? multiple? per-Space wallpapers? -->

## Steps to reproduce

1.
2.
3.

## Expected behavior

<!-- What you expected to happen. -->

## Actual behavior

<!-- What actually happened. Screenshots/screen recording welcome. -->

## State (optional but helpful)

After reproducing, note any of these:

- `~/Library/Containers/glass.kagerou.phosphene.extension/Data/Documents/phosphene-state.json`
- Is the extension process running? (`pgrep -fl PhospheneExtension`)
- Is `WallpaperAgent` running? (`pgrep -x WallpaperAgent`)

## Log excerpt

Attach or paste the relevant lines from:

```
~/Library/Containers/glass.kagerou.phosphene.extension/Data/Documents/extension.log
```

This log records wallpaper switches, presentation/state changes, teardowns, and errors.

### If the log is inconclusive — enable verbose logging and re-capture

The normal log omits high-volume internals (per-frame ticks, renderer restart steps,
per-connection XPC churn, snapshots). If the issue isn't clear from the log above, turn on
verbose logging, reproduce once, and attach the fuller log:

```sh
touch ~/Library/Containers/glass.kagerou.phosphene.extension/Data/Documents/VERBOSE_LOG
killall WallpaperAgent            # relaunches the extension so it picks up the flag
# ... reproduce the problem ...
# then attach extension.log

# disable verbose logging afterwards:
trash ~/Library/Containers/glass.kagerou.phosphene.extension/Data/Documents/VERBOSE_LOG
killall WallpaperAgent
```

## Recovery note

If a wallpaper is stuck, grey, or showing the wrong clip, menu bar → **Restart Wallpaper
Agent** recovers it immediately (this often happens after rapidly switching wallpapers in
System Settings, which can wedge the system `WallpaperAgent`).
