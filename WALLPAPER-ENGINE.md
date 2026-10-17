# Wallpaper Engine wallpapers

Phosphene makes video wallpapers out of Wallpaper Engine wallpapers. Wallpaper Engine itself is a
Windows program and never runs: Steam downloads the wallpapers you subscribe to, and Phosphene
turns each one into a looping video, which then plays like any other video in your library.

## How to use it

1. Subscribe to wallpapers on the Steam Workshop, in a Windows Steam on your Mac. Sevoflurane
   runs one (free, from the same developer); CrossOver and Whisky work too.
2. Open Phosphene's library. The **Wallpaper Engine** section in the sidebar lists the downloads
   it found, with a preview, the type and whether a video can be made.
3. Select wallpapers and choose **Make Videos**. The sheet sets the size (your display's, 4K,
   1440p or 1080p), the frame rate (30 or 60), the format (HEVC or H.264) and the loop length
   (automatic, or a fixed number of seconds).
4. Each video appears in the library and in **System Settings › Wallpaper** as it finishes.

A wallpaper shows **Made** once its video exists. If its author updates it on the Workshop, it
shows **Updated since**; **Make Video Again** renders it again and swaps the video into the same
entry, so a wallpaper chosen in System Settings keeps playing, now with the new version.

Phosphene looks for downloads in Sevoflurane's, CrossOver's and Whisky's Steam folders and in
Steam for Mac, and watches them, so a new subscription appears on its own. **Add Folder…** adds
any other Steam folder or a plain folder of wallpapers.

## What comes through

- **Video wallpapers** are added as they are (MP4, MOV, M4V).
- **Scenes** are drawn with Wallpaper Engine's own shaders: image layers, their effects (waves,
  ripples, blur, glow, shake, and most Workshop effects), particles including refraction, blend
  modes, animated layers and video textures.
- The **loop length** is found by rendering the scene for 30 seconds and picking the length at
  which it comes back to its start. A scene that never repeats (particles, mixed waves) gets a
  one-second crossfade into its own opening.
- What a video leaves out is listed for each wallpaper: sound, text and clocks, 3D models, audio
  visualizers (a video wallpaper hears nothing), and any effect whose shader Phosphene could not
  translate.

**Not yet:** puppet-warp characters and 3D scenes (refused, since they would draw wrong), text
layers and clocks, bloom and camera parallax, web and application wallpapers, and WebM videos.

## How it works

Everything a wallpaper ships is treated as untrusted input: the Workshop is open to anyone.

- `WorkshopDiscovery` finds the Steam libraries and reads each download's `project.json`;
  `WorkshopLibrary` keeps the list, the status of each item and the queue of videos to make.
- A scene renders in a helper copy of Phosphene (`Phosphene --bake`), so a shader that hangs the
  GPU ends the helper, and the library reports a failed video.
- `WEScene` reads the scene and its materials; `WEShaderSource` turns Wallpaper Engine's GLSL
  dialect into GLSL 4.10; `WERenderer` draws the layers, effects and particles offscreen through
  OpenGL (`GL.swift` loads it at runtime); `WELoopFinder` picks the loop; `WEVideoEncoder` writes
  the file with VideoToolbox.
- Every size, count and path a package names is bounded (`WELimit`): paths stay inside the
  wallpaper's folder (`PathSafety.contained`), numbers that are not finite are dropped, textures
  and render targets have byte budgets, shaders have a size and include-depth cap, and previews
  are decoded as thumbnails. A texture that fails draws as black, as it does in Wallpaper Engine.
- `workshop.json` beside a library entry records which Workshop item it came from, when that
  download was last changed and the settings used, which is how the library knows a video is
  made or outdated.

Wallpaper Engine is a trademark of Wallpaper Engine Team; Steam is a trademark of Valve
Corporation. Phosphene is an independent app.
