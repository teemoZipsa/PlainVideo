# Playback startup stability — first pass

Date: 2026-09-22
State: local development candidate; not published, installed, or release-approved.

## Problem and behavior

Opening media and adding/removing the RIFE filter previously issued synchronous
libmpv commands from the window thread. A slow core could therefore delay window
input and status updates. This is a concrete blocking path, not proof of the
reported intermittent black screen's complete cause under concurrent workloads.

The shell now submits file loads and RIFE transitions asynchronously. Filter
commands form one ordered transaction: submit one command, receive its matching
reply, then submit the next. RIFE state becomes active only after completion;
failed preparation removes partial filters and preserves the user's preference
for a subsequent file or explicit retry. Property reads use cached values during
these transitions so polling cannot immediately introduce a synchronous wait.

New open requests supersede pending requests. Late events from an older request
cannot restore its subtitles or mark the latest request ready. File-loaded,
video-configuration, playback-restart and EOF events are retained across filter
transactions. Resume writes are skipped while the active media is changing.

Source playback is prepared first. If the user selected an eligible RIFE mode,
its initialization is scheduled 200 ms after playback readiness. This delay is a
startup policy, not an interpolation performance improvement or a first-scanout
guarantee. RIFE remains optional and defaults off.

## Transient UI and diagnostics

- Opens shorter than 700 ms do not flash a loading notice.
- Slower opens show a native, non-interactive notice independently of mpv's OSD.
- After 10 seconds, the notice explains `R` to retry and `Ctrl+O` to choose a file.
  This is a recoverable waiting state, not an automatic playback failure.
- Readiness, error and end-of-file hide the notice. No permanent controls were added.
- Korean/English, light/dark and text scaling use the current shell preferences.
- Closing hides the window before GPU cleanup; cleanup itself may still wait.

Local startup logs contain generation, elapsed milliseconds and stage, without
media names or paths. Normal logs live in `%LOCALAPPDATA%\PlainVideo\diagnostics`
with bounded retention (approximately 16 files, 256 KiB each). Writes use a bounded
background channel and may be dropped under pressure. With
`PLAINVIDEO_DIAGNOSTIC_LOG`, the trace is the sibling `.startup.log` file.

`playback-ready` records mpv's playback-restart event. It does **not** prove physical
display scanout or absence of a black decoded frame. The libmpv diagnostic log's
first-frame marker is checked separately.

## Local validation

Build and stage the candidate before invoking these tools. They do not publish or
invoke GitHub Actions. Evidence remains under ignored `.runtime` directories.

```powershell
cargo test --locked --all-targets
cargo clippy --locked --all-targets -- -D warnings
cargo build --locked --release

python scripts\verify-playback-start.py `
  --portable-root .runtime\startup-stability\PlainVideo `
  --media .runtime\fixtures\plainvideo-smoke.mp4 `
  --evidence .runtime\startup-stability\new-startup-run

.\scripts\verify-playback-soak.ps1 -Profile Quick `
  -Executable .runtime\startup-stability\PlainVideo\plainvideo.exe `
  -AppRoot .runtime\startup-stability\PlainVideo `
  -LibmpvPath .runtime\startup-stability\PlainVideo\libmpv-2.dll
```

The startup probe delays **local named-pipe reads**, using isolated settings and
history. It verifies UI message replies within a 200 ms probe timeout, first-frame
progress, notice dismissal, retry generation, and two rapid replacement requests
ending on a different filename. Captures are limited to the process's own notice;
the capture helper is bounded separately. Delayed pipes simulate slow reads, not
CPU/GPU saturation, and require the seek-independent smoke MP4 fixture.

Validated during this pass:

- Rust: 82 passed, 1 explicitly ignored runtime thumbnail test; Clippy clean.
- Startup: three cases including Korean/dark, English/light at 360×300 with 200%
  text, a delay over 10 seconds followed by retry, and latest-request replacement.
- Playback: Quick hardware-policy/software-decoder runs, resize/minimize/restore,
  repeated replacement and shutdown; separate 24→48 RIFE generation/replacement.
- Invalid-file recovery and external SAMI subtitle selection/restoration.
- Injected invalid RIFE DLL in the isolated candidate: preparation failure handled,
  partial filters removed, no playback-error event, process exited successfully.
  The DLL was restored and its hash matched the baseline.

Use the development `portable-manifest.json` for the final executable hash and
evidence paths. Earlier iterations remain separate; they are not evidence for a
different executable. The runtime/model/license files are copied unchanged from
the local 0.2.6 portable artifact; the new executable and overlay are development
outputs. This is not a Full release soak or a performance benchmark.

## Next boundary

The native RIFE filter still waits for its queued interpolation result without a
separate output deadline. The inference timeout is evaluated after inference
returns, and native reset/teardown still waits for active work. The next pass must
separate output deadlines from worker lifetime, return source frames while late
work completes, and reject stale results without freeing resources still in use.

Folder enumeration, subtitle preparation and ordinary steady-state synchronous
property/command calls also remain outside this first pass. The original heavy
workload symptom still needs correlation with these startup logs and a controlled
CPU/GPU contention test. Actual generated/source-fallback counters are not yet
shown in the UI.

## API references

The ordered command transaction follows the async ordering notes in the exact
[mpv 0.41 client API](https://github.com/mpv-player/mpv/blob/v0.41.0/include/mpv/client.h).
The native notice is protected from parent drawing with
[WS_CLIPCHILDREN](https://learn.microsoft.com/en-us/windows/win32/winmsg/window-styles).
