# Delete candidates

Looks dead; scope or origin unverified. Kiri confirms → it goes.

## `PhospheneExtension/WallpaperXPCHandler.swift:584-638` — `removeChoiceRequest(withChoiceRequest:reply:)` body
- **What**: `removeChoiceRequestBody`, which parses a video id out of the request, deletes it from the library and tears down its surfaces
- **Looks dead because**: the Settings pane sends it only for `.removable` items with a `choiceRequest`; video tiles are `.none` and never carried one, and no `REMOVE CHOICE REQUEST` line appears in the logs of either test Mac
- **Not deleted because**: the XPC method itself must stay (protocol conformance), and it is unverified whether WallpaperAgent calls it on other paths (e.g. cleanup after the app deletes a video); it is also the hook a working Settings delete would need
- **To confirm**: RE the agent's `removeChoiceRequest` callers, or ship with a log line and check field reports
- **Found**: 2026-09-27
