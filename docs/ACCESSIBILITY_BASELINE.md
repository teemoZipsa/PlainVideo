# Accessibility Baseline

Last updated: 2026-07-19

This document records PlainVideo's keyboard, scaling, and accessibility baseline. It is not a screen-reader conformance claim. The current developer build has source checks, automated layout tests, and a focused-control capture at 200% text scale, but still needs manual assistive-technology verification before any item can be promoted to release accessibility evidence.

## Latest local evidence

The 2026-07-19 local quality pass recorded 23 passing Rust tests, including playback-layout bounds at 96, 120, 144, 192, and 240 DPI with the two-physical-pixel rounding tolerance. `.runtime/validation/integrated/20260719-021643-917/window-behavior.json` records a 427×240 physical-pixel small-media window at 96 DPI with `PLAINVIDEO_TEXT_SCALE=2.0`; its paired `small-video-text-200-percent.png` shows the keyboard-focused transient controls within the client area.

That run also moved the window between two physical monitors, but both reported 96 DPI. It therefore does **not** close the requested real mixed-DPI transition check. The capture is a visual layout record, not OCR, UI Automation, Narrator, High Contrast, or contrast-ratio evidence.

## Current source baseline

- Playback and window controls remain visually transient, but can be revealed and traversed with the keyboard.
- A visible focus treatment is drawn for the focused transient control.
- The native context menu and Windows file picker retain their standard operating-system keyboard and accessibility behavior.
- The custom video overlay uses two text tiers, primary and secondary, and receives both per-monitor DPI scale and Windows text scale.
- A media-file playback failure stays inside the player as a recoverable error surface. The user can retry, open or drop another file, or move to another queued file.
- Korean and English strings are selected as complete locale sets; the interface must not mix the two languages in one session.

PlainVideo's custom-drawn ASS overlay does not yet expose a custom UI Automation or MSAA control tree. Consequently, keyboard reachability and a visible focus ring do not by themselves make the transient controls screen-reader accessible.

## Keyboard matrix

| Area | Action | Key | Source-level expectation |
| --- | --- | --- | --- |
| File | Open video | `Ctrl+O` | Opens the native Windows file picker. |
| Playback | Play or pause | `Space` | Toggles playback when no transient control has keyboard focus. |
| Information | Show or hide media details | `Tab` | Toggles a left-aligned playback information overlay without dimming video or changing play/pause state. |
| Controls | Move focus forward/back | `F6` / `Shift+F6` | Reveals the overlay and cycles through playback and window controls. |
| Controls | Activate focused control | `Enter` or `Space` | Invokes the focused button or control. |
| Seek | Small seek | `Left` / `Right` | Seeks backward/forward five seconds. |
| Seek | Large seek | `Shift+Left` / `Shift+Right` | Seeks backward/forward thirty seconds. |
| Volume | Adjust volume | `Up` / `Down` | Changes volume in two-point steps; increasing volume clears mute. |
| Volume | Toggle mute | `M` | Toggles mute without adding a permanent button. |
| Queue | Previous video | `PageUp` | Opens the previous available video; otherwise has no destructive effect. |
| Queue | Next video | `PageDown` | Opens the next available video; otherwise has no destructive effect. |
| Tracks | Cycle audio track | `A` | Cycles available audio tracks and shows the selected track. |
| Tracks | Cycle subtitle track | `V` | Cycles subtitle tracks and the off state. |
| Fullscreen | Enter/leave fullscreen | `F` | Toggles fullscreen. |
| Fullscreen | Enter fullscreen or activate | `Enter` | Activates focus when present; otherwise toggles fullscreen. |
| Escape | Leave fullscreen/clear focus | `Esc` | Leaves fullscreen immediately, clearing control focus at the same time; while windowed, clears transient control focus. |
| Error | Retry current video | `R` | Available while the recoverable playback-error surface is visible. |
| Window | Toggle always-on-top | `T` | Changes the pinned state. |
| Capture | Save screenshot | `S` | Requests a video screenshot from libmpv. |
| App | Close | `Q` or `Alt+F4` | Closes PlainVideo. |

Pointer equivalents remain available: click the video to play or pause, double-click for fullscreen, use the mouse wheel for volume, drag the seek bar, click the speaker icon to mute, click or drag the adjacent volume track, and right-click for open, retry, previous/next, audio, subtitle, and close actions.

## 100-200% scaling expectations

- The minimum client target remains 280×240 logical pixels and scales to the current monitor DPI in physical pixels.
- The full-width window-move region remains 56 logical pixels high. Visible playback and window controls must stay client hit targets rather than drag targets.
- Window buttons use a 34 logical-pixel tile. Playback buttons use a 36 logical-pixel tile, and the combined speaker/volume target is 64×36 logical pixels.
- The playback bar has a bounded maximum width. At compact sizes, secondary time labels and nonessential hints may disappear before any functional control is clipped or overlapped.
- Primary and secondary are the only text-size tiers. Text sizing is calculated from logical viewport size, per-monitor DPI, and Windows text scale rather than treating physical pixels as logical pixels.
- Both Korean and English layouts must remain within the client area at 100%, 125%, 150%, 175%, and 200% scale. A difference of at most two physical pixels is rounding, not a layout overflow.
- Hover, pressed, and keyboard-focus visuals must use the same layout rectangles as native hit testing.

These are acceptance expectations, not a statement that every scale and language combination has already passed manual visual inspection.

## Pending accessibility work

| Capability | Status | Release requirement |
| --- | --- | --- |
| Keyboard traversal and visible focus | Partial runtime evidence at 427×240 and 200% text; full matrix pending | Verify every control at minimum size, both locales, and 100-200% scale. |
| Native menus and file picker | Uses standard Windows controls | Verify keyboard navigation and cancellation in the packaged build. |
| Custom UI Automation tree | **Pending** | Expose names, roles, focus, toggle state, seek value, and offscreen state for custom overlay controls. |
| Narrator | **Pending** | Verify control order, names, state changes, error announcements, and seek/volume values with the shipped build. |
| High Contrast | **Pending** | Add system-color/high-contrast handling and verify every icon, focus indicator, tooltip, and error surface. |
| Automated screen-reader evidence | **Pending** | Inspect the runtime automation tree after the custom provider exists; do not infer support from source strings. |

## Static invariant check

Run the lightweight source/document check with:

```powershell
.\scripts\verify-accessibility.ps1
```

The script verifies that localization fields, shortcut routes, layout constants, two-tier text scaling, focus state, recoverable-error routing, and the pending-status wording remain present. It does not launch PlainVideo, inspect a UI Automation tree, drive Narrator, test High Contrast, measure contrast, or prove that controls are readable at runtime.

Before a release claim, complete keyboard-only passes in both locales, visual checks from 100% through 200% text/display scale, Accessibility Insights inspection, Narrator verification, and High Contrast verification using the exact packaged build.
