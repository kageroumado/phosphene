# Phosphene

[English](README.md) · [简体中文](README.zh-CN.md)

Phosphene adds your videos to System Settings → Wallpaper through the same wallpaper pipeline as Apple’s Aerials. macOS plays them on the desktop and lock screen, even after you quit the app. It also turns **Wallpaper Engine** wallpapers from the Steam Workshop into video wallpapers.

<a href="https://kagerou.glass/get/phosphene?from=readme"><img src=".github/download.svg" alt="Download Phosphene for Mac" width="360" height="80"></a>

![Phosphene videos in System Settings → Wallpaper](.github/phosphene-settings.png)

## Highlights

- Use Wallpaper Engine wallpapers from the Steam Workshop: subscribe in Steam, and Phosphene makes a looping video of each.
- Select personal videos alongside Apple’s wallpapers in System Settings.
- Keep desktop and lock-screen playback running after quitting Phosphene.
- Pause playback under covered desktops and adjust decoding to power and thermal conditions.

<details>
<summary>Full feature list</summary>

- Import videos in the **Library** window and select them in **System Settings → Wallpaper**.
- Wallpaper selection per display or Space, plus a **Lock Screen**-only playback mode.
- Desktop and lock-screen playback through the macOS wallpaper pipeline.
- MP4, MOV, and other AVFoundation-readable inputs; gapless looping and lock/unlock transitions.
- Menu-bar preview, pause, display switching, and launch at login.
- Visibility, power, and thermal-aware playback; optional lower-resolution variants.
- **Restart Wallpaper Agent** from the menu bar for stuck playback.
- A **Wallpaper Engine** section: Steam Workshop downloads from Sevoflurane, CrossOver or Whisky become looping videos.

</details>

## Light and dark wallpapers

Select two videos in the Library to create a light/dark pair. Compatible videos keep their original files. The pair converter can give two clips matching dimensions, frame timing, color format, and keyframes. The resulting pair appears as one choice in System Settings → Wallpaper. **Automatic** follows the Mac’s appearance, while **Light** and **Dark** pin the selected version. Splitting a pair restores the two individual Library entries.

HDR playback supports HLG and PQ. **Dynamic Range** controls highlight brightness at playback time. When creating optimized versions, **Convert to SDR** tone-maps the output to Rec. 709 and keeps the HDR original.

## Wallpaper Engine

![Phosphene’s library at its Wallpaper Engine section, with Steam Workshop downloads ready to become videos](.github/phosphene-library.png)

The Steam Workshop has hundreds of thousands of animated wallpapers made for Wallpaper Engine, a Windows program. Phosphene turns them into video wallpapers: subscribe in Steam, pick them in the library's Wallpaper Engine section, and choose Make Videos.

Wallpaper Engine runs in Windows Steam. [Sevoflurane](https://kagerou.glass/sevoflurane/?from=phosphene-readme) brings that Steam to your Mac, free, from the same developer. What a video keeps and what it leaves out: [WALLPAPER-ENGINE.md](WALLPAPER-ENGINE.md).

Wallpaper Engine is a trademark of Wallpaper Engine Team; Steam is a trademark of Valve Corporation. Phosphene is an independent app.

## Counting

Nothing is sent unless you say so. The menu bar asks once whether to count this Mac; if you count yourself in, Phosphene sends one anonymous check-in on each day you use it: the Phosphene and macOS versions, chip family and memory size, language and date, how many of the last 7 days you used it, whether you have your own videos, and how many displays. It never includes which videos you use, and nothing in it names you. A second tier adds a scrubbed report when Phosphene itself crashes. Turning it off requests deletion of what this Mac sent. Every field is listed in the [Digoxin reference](https://github.com/kageroumado/digoxin/blob/main/REFERENCE.md).

## Notes

- macOS 26+ · Apple silicon or Intel.
- Homebrew: `brew install --cask phosphene`.
- Uses private `WallpaperExtensionKit` APIs, which macOS updates can change. [Troubleshooting and implementation](REFERENCE.md).
