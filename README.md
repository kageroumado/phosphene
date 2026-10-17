# Phosphene

[English](README.md) · [简体中文](README.zh-CN.md)

Phosphene adds your videos to System Settings → Wallpaper through the same wallpaper pipeline as Apple’s Aerials. macOS plays them on the desktop and lock screen, even after you quit the app.

<a href="https://kagerou.glass/get/phosphene?from=readme"><img src=".github/download.svg" alt="Download Phosphene for Mac" width="360" height="80"></a>

![Phosphene videos in System Settings → Wallpaper](.github/phosphene-settings.png)

## Highlights

- Select personal videos alongside Apple’s wallpapers in System Settings.
- Keep desktop and lock-screen playback running after quitting Phosphene.
- Pause playback under covered desktops and adjust decoding to power and thermal conditions.
- Turn Wallpaper Engine wallpapers from the Steam Workshop into looping videos.

<details>
<summary>Full feature list</summary>

- Import videos in the **Library** window and select them in **System Settings → Wallpaper**.
- Wallpaper selection per display or Space, plus a **Lock Screen**-only playback mode.
- Desktop and lock-screen playback through the macOS wallpaper pipeline.
- MP4, MOV, and other AVFoundation-readable inputs; gapless looping and lock/unlock transitions.
- Menu-bar preview, pause, display switching, and launch at login.
- Visibility, power, and thermal-aware playback; optional lower-resolution variants.
- **Restart Wallpaper Agent** from the menu bar for stuck playback.
- A **Wallpaper Engine** section that finds Steam Workshop downloads in Sevoflurane, CrossOver or Whisky and renders scenes and videos into looping HEVC or H.264 videos, with the loop length found automatically.

</details>

## Wallpaper Engine

Wallpaper Engine's Workshop has hundreds of thousands of animated wallpapers, made for a Windows program. Phosphene reads the downloads and makes a looping video of each scene with Wallpaper Engine's own shaders, which then plays like any other video wallpaper. Wallpaper Engine itself runs in Windows Steam: [Sevoflurane](https://kagerou.glass/sevoflurane/?from=phosphene-readme) runs that Steam on a Mac, free, from the same developer. Subscribe to wallpapers there, and they appear in Phosphene's library. How it works and what it leaves out: [WALLPAPER-ENGINE.md](WALLPAPER-ENGINE.md).

Wallpaper Engine is a trademark of Wallpaper Engine Team; Steam is a trademark of Valve Corporation. Phosphene is an independent app.

## Counting

Nothing is sent unless you say so. The menu bar asks once whether to count this Mac; if you count yourself in, Phosphene sends one anonymous check-in on each day you use it: the Phosphene and macOS versions, chip family and memory size, language and date, how many of the last 7 days you used it, whether you have your own videos, and how many displays. It never includes which videos you use, and nothing in it names you. A second tier adds a scrubbed report when Phosphene itself crashes. Turning it off deletes everything this Mac sent. Every field is listed in the [Digoxin reference](https://github.com/kageroumado/digoxin/blob/main/REFERENCE.md).

## Notes

- macOS 26+ · Apple silicon or Intel.
- Homebrew: `brew install --cask phosphene`.
- Uses private `WallpaperExtensionKit` APIs, which macOS updates can change. [Troubleshooting and implementation](REFERENCE.md).
