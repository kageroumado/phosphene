# Wallpaper Engine wallpapers (prototype)

The library's **Wallpaper Engine** section turns Steam Workshop downloads into looping videos in
Phosphene's library. Wallpaper Engine itself never runs: Windows Steam (in Sevoflurane, CrossOver
or Whisky) downloads what the user subscribes to, Phosphene finds the downloads, draws scene
wallpapers offscreen with Wallpaper Engine's own shaders from that install, and encodes them.

Format notes, the measurements behind the design, and the options weighed are in
`~/Developer/Research/wallpaper-engine-in-phosphene.md`.

## Flow

1. **Find** (`WorkshopDiscovery`): Steam folders in the bottles of Sevoflurane, CrossOver and
   Whisky, Steam for Mac, extra libraries from `libraryfolders.vdf` (Windows paths resolved through
   each bottle's `dosdevices`), and folders the user adds with the section's Add Folder tile. Each
   library gives `steamapps/workshop/content/431960` (the downloads) and
   `steamapps/common/wallpaper_engine/assets` (the base shaders and textures scenes draw with).
   A vnode watcher rescans when Steam adds a download.
2. **Judge** (`WorkshopDiscovery.assess`): videos are ready as they are; scenes parse their
   `scene.pkg` and report what a video leaves out (sound, text and clocks) or why they cannot be
   made (puppet-warp characters, 3D cameras, web and application wallpapers, WebM).
3. **Stage**: clicking a tile selects it; the toolbar's **Make Videos** opens a sheet for size,
   frame rate, format and loop length.
4. **Render** (`WEBaker`, on its own thread with its own OpenGL context):
   - `WEScene` reads `scene.json`, models, materials and effect chains.
   - `WERenderer` draws each image layer through its material into a layer buffer, runs its effect
     passes (named buffers, `bind` lists), and composites it onto the scene, with blend modes from
     the install's `common_blending.h`. Particles are a CPU simulation drawn as instanced sprites,
     refraction included. Video textures decode with `AVAssetReader`.
   - `WEShaderSource` compiles Wallpaper Engine's GLSL dialect as GLSL 4.10: includes, combos from
     annotations and texture formats, HLSL spellings mapped by a prelude, early uniforms hoisted.
   - `WELoopFinder` renders small frames for 30 s and picks the length whose end best matches its
     start. A loop that does not close on its own (particles, incommensurate waves) starts one second
     in and fades into its own opening; a second particle simulation keeps every frame in time order.
   - `WEVideoEncoder` writes HEVC or H.264 at constant quality 0.8.
5. **Add**: the video joins the library like an imported one. `workshop.json` beside it records
   the Workshop id, the download's date and the settings, which is how a tile knows it is made or
   that the author has updated it since. **Make Video Again** swaps the file inside the same entry,
   so a wallpaper selected in System Settings keeps playing.

Workshop packages are untrusted downloads, and every number in them is treated as one. The bounds
live in `WELimit` (`WEFileSystem.swift`); the rules, by layer:

- **Paths** (`file`, `preview`, textures, `#include`): resolved only inside the wallpaper's folder
  or the install's `assets/`, through `PathSafety.contained` (symlinks and `..` resolved, trailing
  separator compared). A path that leaves its root reads as missing.
- **Numbers**: `WEJSON` drops infinities and NaN (`"inf"` parses as a `Float`; JSON `1e300`
  overflows one), `WEJSON.int` and `Int(clamping:to:)` hold every count and pixel size inside its
  range, so no `Int(Float)` conversion can trap. Scene size, layer buffers (8192 a side), texture
  slots (16), effects per layer, passes and buffers per effect, particle counts (20 000) and
  pre-simulation time (60 s) are capped.
- **Textures**: `WETexture` bounds every size a `.tex` header claims (16384 a side, mip and image
  counts, one 1 GiB LZ4 budget per texture) and requires each raw mip's bytes to cover its
  format's size before anything reaches OpenGL; embedded images must be PNG or JPEG and are
  size-checked before decoding. The cache keys by normalized path and stops at 2 GiB per scene.
  A texture that fails draws as black, as a missing one does in Wallpaper Engine.
- **Shaders**: source after includes is capped at 512 KB and 32 include levels; the translator's
  patterns are linear in the file (`[ \t]*`, never `\s*` across lines; one tokenizing pass finds
  early uniform uses).
- **Render targets**: 2 GiB per scene across layer pairs (shared by size) and effect buffers.
- **Previews** (`preview.gif/jpg`): decoded as ImageIO thumbnails (720 px tiles, 1280 px inspector),
  animated only when under 4096² and 300 frames.
- **The app**: bake settings read from defaults are normalized; the render's GL context is held
  for the whole bake (`withExtendedLifetime`); a remade video is copied beside the old file and
  swapped in with `replaceItemAt`, so a failed copy leaves the entry playing.

- **The bake process**: each scene renders in a helper copy of Phosphene (`main.swift` runs
  `WEBakeHelper` when launched with `--bake <request.json>`, see `WEBakeProcess.swift`). Shader
  compile time and GPU execution are the driver's, and a fragment shader can hang either; that now
  ends the helper, and the app reports a failed video. The helper reports progress as JSON lines
  on its standard output, stops on SIGTERM between frames, and exits when the app is gone.

OpenGL is loaded with `dlsym`: its symbols are deprecated (the app treats warnings as errors), and
a macOS without OpenGL then reports that scenes are unavailable instead of failing to launch.

## The funnel to Sevoflurane

The Wallpaper Engine section is always in the sidebar. With no Steam found, its empty state says
what the feature is and that Wallpaper Engine runs in Windows Steam, with **Get Sevoflurane**
(`kagerou.glass/sevoflurane/?from=phosphene`) as the one prominent button and **Add Folder…** for
CrossOver, Whisky or a plain folder. With Sevoflurane installed, the button becomes **Open Steam
Workshop**, a `steam://` link Sevoflurane handles; without any `steam://` handler the Workshop
opens on the web. The menu bar's empty state has a **Wallpaper Engine…** button that opens the
library at that section. The site's Phosphene page has a §03 on it that links to Sevoflurane, and
both Sevoflurane pages have a "Wallpapers, too" card that links back. Every link carries `?from=`
so the distribution dashboard can tell the two directions apart.

## Measured on the 17 Workshop items in Sevoflurane's bottle

- 3 videos: added as they are.
- 12 of 13 scenes render. Left out: sound (8), text and clocks (2), one workshop effect whose shader
  relies on HLSL's implicit vector truncation (`cutout_vignette`).
- 1 scene is refused: its character is a puppet-warp mesh.
- 4K30 renders take 10–20 s per scene on an M1 Max. A 20 s 4K30 HEVC loop is about 33 MB.
- Loop seams on raw frames equal an ordinary frame step; after encoding, the wrap is no larger than
  a keyframe boundary.

## Missing before a release

- Puppet-warp (`.mdl` meshes, bones, animation layers) and 3D scenes.
- Text layers and SceneScript (clocks, day/night switches by the hour; Phosphene variants could
  carry a bake per time of day).
- Bloom (`general.bloom`), camera parallax and shake, audio-reactive effects.
- A GLSL translation step for workshop shaders that lean on HLSL semantics.
- zh-Hans strings for the new UI.
- WebM video wallpapers (AVFoundation cannot open WebM).

## Running the prototype without disturbing the installed app

A Debug build launched from DerivedData registers its own copy of the wallpaper extension, which
can leave WallpaperAgent pointing at a deleted path (see REFERENCE.md). To try the library only,
make a copy without the extension, under its own bundle id, signed by the team that owns the
extension container (an ad-hoc copy cannot read it), and open the library at launch:

```sh
APP="/Volumes/Ugreen/Scratch/phosphene-wedev/Phosphene WE Prototype.app"
cp -R /Volumes/Ugreen/Build/phosphene-wedev/Build/Products/Debug/Phosphene.app "$APP"
trash "$APP/Contents/Extensions"
plutil -replace CFBundleIdentifier -string glass.kagerou.phosphene.wedev "$APP/Contents/Info.plist"
plutil -remove CFBundleURLTypes "$APP/Contents/Info.plist"
codesign --force --deep -s "Developer ID Application: Elysia Muñoz (52K336H235)" "$APP"
defaults write glass.kagerou.phosphene.wedev launchAtLogin -bool false
defaults write glass.kagerou.phosphene.wedev autoInstallUpdates -bool false
open -n "$APP" --args -PHOSPHENE_OPEN_LIBRARY YES
```

Videos it makes go into the real library and appear in System Settings through the installed
extension.

**Unregister every Debug build** (`lsregister -u <path to the built Phosphene.app>`). Xcode registers
each app it builds with LaunchServices, and WallpaperAgent may launch a registered debug
`PhospheneExtension.appex` for new wallpapers. A build made without signing cannot start there, so
acquires time out after 32 s: a newly selected video does nothing, or a stale snapshot shows. The fix
is the one REFERENCE.md gives for a deleted copy: unregister the stray copies,
`lsregister -f /Applications/Phosphene.app`, `killall WallpaperAgent`. A release archive (`kagerou publish`) registers its own copy under `…/ArchiveIntermediates/…/Phosphene.app` the same way, so the same three steps follow every release.

**Reading the extension's log**: its container refuses every process not signed by its team,
terminals included. A Debug build signed as above copies the log and a listing of the library to
`/tmp/phosphene-diagnostics` when launched with `--args -PHOSPHENE_EXPORT_DIAGNOSTICS YES`.
