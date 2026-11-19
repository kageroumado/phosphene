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
- Pair light and dark versions of the same animation to show them as one wallpaper. In Wallpaper settings, choose **Automatic** to follow the system appearance, or select **Light** or **Dark**.
- Wallpaper selection per display or Space, plus a **Lock Screen**-only playback mode.
- Desktop and lock-screen playback through the macOS wallpaper pipeline.
- MP4, MOV, and other AVFoundation-readable inputs; gapless looping and lock/unlock transitions.
- Menu-bar preview, pause, display switching, and launch at login.
- **Optimize** creates lower-power versions of a video or light/dark pair. HLG and PQ videos keep HDR by default. Select **Convert to SDR** before choosing a preset to create SDR versions. The originals stay in the Library.
- **Tools → Custom Conversion** exports a video from the Library or a file as SDR, HLG, or PQ. **Light/Dark Pair Converter** converts two sources to the same dimensions, frame rate, duration, and color format, then adds the validated pair to the Library.
- In Phosphene, **Settings → Playback → Dynamic Range** controls the wallpaper and Library previews. Choose **Constrained High** for more subdued highlights or **Automatic** to restore the system preference.
- **Restart Wallpaper Agent** from the menu bar for stuck playback.
- A **Wallpaper Engine** section: Steam Workshop downloads from Sevoflurane, CrossOver or Whisky become looping videos.

</details>

## Wallpaper Engine

![Phosphene’s library at its Wallpaper Engine section, with Steam Workshop downloads ready to become videos](.github/phosphene-library.png)

The Steam Workshop has hundreds of thousands of animated wallpapers made for Wallpaper Engine, a Windows program. Phosphene turns them into video wallpapers: subscribe in Steam, pick them in the library's Wallpaper Engine section, and choose Make Videos.

Wallpaper Engine runs in Windows Steam. [Sevoflurane](https://kagerou.glass/sevoflurane/?from=phosphene-readme) brings that Steam to your Mac, free, from the same developer. What a video keeps and what it leaves out: [WALLPAPER-ENGINE.md](WALLPAPER-ENGINE.md).

Wallpaper Engine is a trademark of Wallpaper Engine Team; Steam is a trademark of Valve Corporation. Phosphene is an independent app.

## Privacy

Choose **Count Me In** in the menu bar to enable anonymous usage statistics. You can change either option independently in **Settings → Privacy**. Both start off.

- **Send crash reports** sends the app's crash log and basic system details after a Phosphene crash. Account names, Mac names, and home folder paths are redacted before upload.
- **Count this Mac** sends one anonymous check-in per day of use. It includes the date, app and macOS versions, chip, memory, language, display count, days active in the last week, and whether you imported videos. Video names and files are excluded.

Turning both options off requests deletion of this Mac's submissions. Offline deletion requests retry when the service becomes available. [Digoxin field reference](https://github.com/kageroumado/digoxin/blob/main/REFERENCE.md).

## Notes

- macOS 26+ · Apple silicon or Intel.
- Homebrew: `brew install --cask phosphene`.
- Uses private `WallpaperExtensionKit` APIs, which macOS updates can change. [Troubleshooting and implementation](REFERENCE.md).
