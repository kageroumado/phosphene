<!-- Thanks for contributing to Phosphene! Fill in what's relevant; delete what isn't. -->

## Summary

<!-- One or two sentences: what this changes, and why. -->

## Related issue(s)

<!-- e.g. "Fixes #12" or "Relates to #12". Delete if none. -->

## Changes

<!-- Bullet the key changes. Keep it skimmable. -->

-

## How it was tested

<!-- Phosphene drives Apple's WallpaperAgent, so behavior is hard to unit-test — say what you actually exercised on real hardware, not just that it builds. -->

- **macOS / hardware**: <!-- e.g. macOS 26.1, M4 MacBook Air -->
- **Displays / Spaces**: <!-- single? multiple? per-Space wallpapers? clip sizes? -->
- **Scenarios exercised**: <!-- e.g. fresh WallpaperAgent restart, rapid switching in System Settings, sleep/wake, multi-display -->
- **Result**: <!-- what you observed; screenshots / screen recordings welcome -->

<!-- If the change touches acquire / teardown / presentation policy, capture the extension log while reproducing, ideally with verbose logging on (see the bug-report template for the VERBOSE_LOG flag):
     ~/Library/Containers/glass.kagerou.phosphene.extension/Data/Documents/extension.log -->

## Risk / regressions

<!-- What could this break? Any behavior that changed that a reviewer should double-check (e.g. seamless switching, cold-start, sleep/wake, per-Space contexts). -->

## Checklist

- [ ] Builds (`xcodebuild … build`)
- [ ] `swiftformat --lint .` passes
- [ ] Exercised on real hardware (not just a compile)
- [ ] No unrelated changes bundled in

---

## Authorship

<!-- These PRs are usually written by an agent — record who wrote it and how. -->

- **Agent**: <!-- the agent's name (e.g. Sora), or the human author -->
- **Model**: <!-- the model the agent runs on, e.g. Opus 4.8 (1M context) — leave blank if human-authored -->
- **Session**: <!-- "attended" (a human participated / reviewed live) or "automatic" (unattended agent run) -->
