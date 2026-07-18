# UI/UX polish proof

Date: 2026-07-18
Status: locally verified UI refinement, pre-alpha, not distributable

> Historical note: the 96×44 six-dot move handle described in this proof was replaced on 2026-07-19 by a full-width invisible 56 px native move zone and responsive playback controls. See [Windows window-behavior proof](WINDOW_BEHAVIOR_PROOF.md) for the current implementation and evidence.

## Baseline and intent

Slice 0B was first frozen in commit `27d7a23` (`Embed libmpv in native playback shell`). This pass deliberately postpones physical cross-DPI testing, the long replacement/resize soak, and redistribution closure. It changes only the playback shell's presentation, localization, and pointer behavior while preserving the borderless, content-first surface.

The direction follows Microsoft's current Windows guidance: keep the experience calm and decluttered, use layering to communicate hierarchy, keep secondary commands in a context menu, and use the Windows system typeface. References checked on 2026-07-18:

- [Windows 11 design principles](https://learn.microsoft.com/windows/apps/design/design-principles)
- [Menus and context menus](https://learn.microsoft.com/windows/apps/develop/ui/controls/menus-and-context-menus)
- [Typography in Windows](https://learn.microsoft.com/windows/apps/design/signature-experiences/typography)

## Implemented behavior

- The empty surface now uses a restrained play glyph, a clear primary instruction, and a secondary `Ctrl+O` route instead of one low-contrast line.
- Play/pause uses a short-lived centered translucent tile. Seek uses a short-lived bottom progress capsule with separated current and total time. Volume uses a short-lived top capsule with a localized label, percentage, and thin meter.
- Overlay typography uses only two responsive semantic sizes: primary instructions and secondary labels/timing.
- There is still no title bar, border, fixed toolbar, or permanently visible playback control.
- The pointer hides 1.6 seconds after mouse activity while media is loaded, reappears on mouse movement or before menus/dialogs, and is restored during shutdown.
- A PlainView-style invisible `96×44` top-center move zone reveals a `64×28` six-dot handle on hover. Dragging that handle invokes the native Windows move loop without turning an ordinary video click into a window drag.
- The native context menu keeps `Open video`/`영상 열기` and `Close`/`닫기` at the first level. A contextual `Subtitles`/`자막` submenu reads libmpv's current track list and selection, checks the active item, and provides off and external subtitle-file commands.
- A PlainView-matched top-right group appears only after pointer activity: theme, always-on-top, minimize, and close in that order. The four `34×34` buttons use a 10 px edge inset and 6 px gaps, expose localized hover labels, and disappear with the pointer chrome after 1.6 seconds.
- Theme switching updates the empty surface, transient feedback, move handle, window controls, and libmpv background. Always-on-top uses the native `HWND_TOPMOST`/`HWND_NOTOPMOST` path and is also available through `T`.
- Theme and always-on-top state persist in `%LOCALAPPDATA%\PlainVideo\settings.ini`; the diagnostic-only `PLAINVIDEO_SETTINGS_PATH` override keeps portable verification from changing the user's preference file.
- `OFN_EXPLORER` is enabled for the native file chooser, and its app-provided title and filter names use the selected language.

## Locale boundary

PlainVideo has exactly two UI resource sets. Locale tags beginning with `ko` select Korean; every other locale selects English. The detected choice is canonicalized to `ko-KR` or `en-US` and passed to the Lua overlay, so the Rust shell and playback feedback cannot choose different languages. The debug-only `PLAINVIDEO_LOCALE` override follows the same path.

Covered app copy includes the empty state, volume label, context-menu and subtitle commands, media/subtitle file-dialog titles and filters, top-right hover labels, and the fatal-error dialog. Raw technical error detail is sent to the Windows debugger rather than mixed into the localized dialog.

## Local evidence

| Check | Result |
|---|---|
| Korean empty state | `.runtime/ui-polish-idle-ko.png` showed `여기에 영상을 놓으세요` and `또는 Ctrl+O로 열기` with no English UI copy. |
| English empty state | `.runtime/ui-polish-idle-en-2.png` showed `Drop a video here` and `or press Ctrl+O to open` with no Korean UI copy. |
| Top move handle | `.runtime/plainview-style-move-handle-2.png` showed the transient six-dot handle over real playback. A native input probe dragged the window from `1920,360` to `2041,440`, a `+121,+80` move. |
| Native context menu | `.runtime/context-menu-without-move.png` showed only localized open and close commands with aligned shortcuts; the redundant move command was absent. |
| Subtitle runtime | The integrated MP4 and MKV portable logs both recorded the matching external SRT as selected. The submenu code reads `track-list`, compares `sid`, sends synchronous `sid=no`/`sid=<ID>`, and uses `sub-add ... cached` for an external file. |
| PlainView top-right state | The integrated portable run loaded a light-theme, always-on-top diagnostic preference. Both MP4 and MKV logs recorded the light background and the localized Lua control state; both reached their first frame and exited 0 without a Lua error. |
| Playback feedback | Seek, volume, and pause captures showed the intended translucent hierarchy with no permanent toolbar. |
| Pointer lifecycle | A real `GetCursorInfo` probe reported the pointer hidden after the 1.6-second playback delay; clean shutdown restored it. |
| Locale tests | Rust tests cover Korean selection, English fallback for all non-Korean tags, and completeness of both native resource sets. |
| Portable regression | The rebuilt developer portable directory played both MP4 and MKV, selected the matching external SRT, showed the first frame, applied light/pinned control state, and exited 0 for both. The four-control minimize regression also exited 0 without a Lua error. The copied Lua asset SHA-256 is `e5cb32c9ee3a9ce8c391949cc6f7d5ec96f08c5f62d5f0bcfe913d7340c8b0d0`. |

The `.runtime` captures and logs are local ignored evidence, not release files.

## Quality gates

```powershell
cargo fmt --all -- --check
cargo test --all-targets
cargo clippy --all-targets -- -D warnings
cargo build --release
git diff --check
```

All ten Rust tests pass. No GitHub Actions workflow was added, enabled, or run.

## Still deferred

- Physical movement between displays with different DPI scaling
- Long replacement/resize decoder and GPU-resource soak
- Complete libmpv/FFmpeg redistribution inventory and public portable release decision
- User study beyond the focused visual and input proof above
