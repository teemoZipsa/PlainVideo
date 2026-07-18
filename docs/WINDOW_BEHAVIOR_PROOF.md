# Windows window-behavior proof

Date: 2026-07-19
Status: locally verified on the current two-monitor Windows machine; pre-alpha, not distributable

## Scope

This pass ports the current PlainView window-behavior principles into PlainVideo's Rust/Win32 shell without copying image-viewer-specific behavior. PlainVideo remains opaque, borderless, content-first, and uses libmpv directly.

## Implemented behavior

- Window placement is stored as physical-pixel `x`, `y`, `width`, and `height` values. Startup validates the saved rectangle against current monitor work areas, applies position first, and applies size in a second `SetWindowPos` call.
- Minimized, maximized, fullscreen, and effectively off-screen rectangles never replace the last valid normal bounds. A window must retain at least a 48×48 physical-pixel overlap with one current work area to be restorable.
- Media-size resize preserves the current position first, fits the video within 90% of the current monitor work area, honors the DPI-scaled minimum, then clamps the result into that work area. Two physical pixels or less are treated as DPI rounding, not real overflow.
- The frameless window uses an opaque `WS_POPUP | WS_THICKFRAME` surface with minimize/maximize/system styles, no layered transparency, `DWMWA_BORDER_COLOR = DWMWA_COLOR_NONE`, a one-pixel `DwmExtendFrameIntoClientArea` margin, and `WM_NCCALCSIZE` client extension. This removes the visible DWM border while retaining native composition and shadow behavior.
- The top 56 logical pixels across the full client width are an invisible native `HTCAPTION` move zone. There is no dot handle or move button. The zone uses `IDC_SIZEALL`, and entering it reveals the transient overlays.
- Top-right theme, pin, minimize, and close controls, plus bottom play/pause, seek, mute, subtitle, and fullscreen controls, return `HTCLIENT` and cannot start a window drag. Control capture is released on client mouse-up, `WM_CAPTURECHANGED`, and `WM_CANCELMODE` so a boundary crossing cannot leave an interaction locked.
- The baseline minimum is 280×240 logical pixels and scales with `GetDpiForWindow`. Overlay geometry has a DPI-scaled maximum width, a compact seek-track fallback, and only two text tiers. Text scaling is capped progressively at narrow widths so a 200% preference does not clip the controls.

## Local evidence

The reproducible probe is `scripts/verify-window-behavior.ps1`. Its ignored runtime result is `.runtime/window-behavior/window-behavior-evidence.json`.

| Check | Result |
|---|---|
| Physical monitor movement | The 1280×720 window moved from `1920,336` on the 5120×1392 work area to `5760,360` on the 2560×1440 work area without coordinate virtualization. |
| Monitor boundary | The probe placed the window across the first monitor boundary, ended the native size/move cycle, then continued through minimize, maximize, fullscreen, and later moves without a stuck drag/capture state. |
| Save exclusions | Fullscreen, minimized, maximized, and `-32000,-32000` off-screen states all preserved the last valid normal bounds. |
| Restore ordering/result | Saved `96,84,1280,720` physical bounds relaunched as exactly `96,84,1280,720`; the implementation performs the position call before the size call. |
| Fullscreen double click | Client double click changed the window to the current monitor's exact `0,0,5120,1440` bounds; `Esc` restored the prior rectangle exactly. |
| Seek bar | A native pointer/click probe hit the transient seek track and the verbose libmpv log recorded the absolute-percent seek command. |
| Small video and 200% text | A 160×90 fixture produced a 427×240 window. The captured top and bottom controls remained separate, readable, and inside the client area with `PLAINVIDEO_TEXT_SCALE=2.0`; no Lua error was logged. |
| No border and native shadow | DWM composition was active, the window was opaque and non-layered, the thick native frame/shadow style remained, startup accepted the PlainView-matched DWM calls, and the local capture showed no colored frame with a composed exterior shadow. This Windows build does not expose the set border color through `DwmGetWindowAttribute` and returns `E_INVALIDARG` for that readback. |
| Portable playback | Rebuilt local portable MP4 and MKV runs exited 0, found the matching external SRT, shut down cleanly, and logged no Lua error. |

The two attached displays both reported 96 DPI. Therefore a real move between *different* physical DPI values was not available on this machine. The implementation and unit tests cover per-window DPI scaling, DPI-changed rectangles, 96→192 metric scaling, and physical-pixel persistence, but a distinct-DPI hardware transition remains an explicit physical test gap rather than a claimed pass.

## Quality gates

```powershell
cargo fmt --all -- --check
cargo test --all-targets
cargo clippy --all-targets -- -D warnings
cargo build --release
.\scripts\generate-smoke-media.ps1
.\scripts\build-portable.ps1 -SkipBuild
.\scripts\verify-window-behavior.ps1
git diff --check
```

All 14 Rust tests passed. All PowerShell scripts parsed. No GitHub Actions workflow was added, enabled, or run.
