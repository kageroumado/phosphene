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

Turn on **Phosphene → Settings → General → Debug Logging**, reproduce the issue once,
then turn the switch off. Review the relevant lines before attaching them. They can
include video filenames.

## Recovery note

If a wallpaper is stuck, grey, or showing the wrong clip, menu bar → **Restart Wallpaper
Agent** recovers it immediately (this often happens after rapidly switching wallpapers in
System Settings, which can wedge the system `WallpaperAgent`).
