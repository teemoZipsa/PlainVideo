# Slice 0B libmpv embedding proof

Date: 2026-07-18
Status: locally verified architecture slice, pre-alpha, not distributable

> Historical note: the right-click move command and `Alt`+drag path in this Slice 0B snapshot were removed by the later PlainView window-behavior port. See [Windows window-behavior proof](WINDOW_BEHAVIOR_PROOF.md) for the current move zone, DWM, DPI, and responsive-control behavior.

## What this slice proves

PlainVideo now owns the Windows playback window, input routing, fullscreen state, DPI handling, and OpenGL presentation surface. Playback runs in-process through `libmpv-2.dll`; no `mpv.exe` child process owns the window.

libmpv's render and update functions run on a dedicated render thread with the WGL context current there. The UI thread sends playback commands and drains client events. Shutdown stops playback, releases the idle video output while the render thread is still active, consumes the final render callback, frees the render context on its owning thread, and only then destroys the libmpv core.

## Locked developer runtime

- Source build project: `shinchiro/mpv-winbuild-cmake`
- Release: `20260610`
- Runtime asset retained for the historical Slice 0A launcher: `mpv-x86_64-20260610-git-304426c.7z`
- Runtime asset SHA-256: `facac536baa73c7b925771af5e39a3c9cb16b8d75b59a6e9800de89799dffca7`
- Slice 0B development asset: `mpv-dev-x86_64-20260610-git-304426c.7z`
- Development asset SHA-256: `8cbb25ea784f01afbb3f904217cab1317430a8bcfd5680fd827a866367f71cc9`
- Embedded library: `libmpv-2.dll`
- Runtime report: mpv `v0.41.0-744-g304426c39`, libplacebo `v7.365.0`, FFmpeg `N-124930-g2576e0943`

`scripts/bootstrap-mpv.ps1 -Force` re-extracted both verified archives and wrote matching provenance records on 2026-07-18. These binaries remain developer dependencies and are conservatively treated as GPL-2.0-or-later.

## Verified behavior

| Behavior | Evidence |
|---|---|
| In-process render API | The runtime log identifies `vo/libmpv`, OpenGL 4.6, `NVIDIA Corporation`, and `NVIDIA GeForce RTX 5070/PCIe/SSE2`; the Rust process loads `libmpv-2.dll` dynamically and does not start `mpv.exe`. |
| PlainVideo-owned surface | A window-handle capture was exactly 1280×720 with video filling the borderless client area and no title bar or permanent toolbar. |
| Empty surface | With `PLAINVIDEO_LOCALE=ko-KR` and no media, the render target showed only `영상을 끌어 놓으세요` on black. The idle VO is enabled only after the render context exists. |
| Play, seek, and volume input | Native click and arrow-key messages reached the `plainvideo` Lua bindings. The log recorded pause, exact +5-second seek, and volume commands; a capture showed `00:05 / 00:30` and the thin transient progress line. |
| Fullscreen and restore | After moving the window to the display beginning at X=5120, double-click changed the rectangle from `5200,100–6480,820` to that monitor's exact `5120,0–7680,1440` bounds. `Esc` restored the original rectangle. |
| Contextual window actions | Right click creates a native, non-persistent menu for opening media, moving the window, and closing. `Alt`+drag is the direct movement path. |
| External subtitle | Both MP4 and MKV loads opened the same-name `plainvideo-smoke.srt`. |
| Hardware decode observation | Both fixture loads reported `Using hardware decoding (nvdec)` on this machine. This is the observed Slice 0B path; the Slice 0A `d3d11va-copy` observation is not reused as a claim for this build. |
| Rapid replacement | Real `WM_DROPFILES` payloads replaced MP4 with MKV after 150 ms. Both files opened, and the MKV reached its first video frame; a later replacement back to MP4 also reached its first frame. |
| DPI message path | Both attached displays currently report 96 DPI, so a physical cross-DPI transition was unavailable. A synchronous `WM_DPICHANGED` probe applied the suggested `5300,140–6500,815` rectangle exactly. |
| Clean teardown | Final playback and replacement logs show decoder uninitialization, successful end-of-file handling, and shader-cache flush with exit code 0. The earlier `mpv_render_context_render() not being called or stuck` warning was eliminated by the ordered shutdown handshake. |
| Developer portable proof | `scripts/build-portable.ps1` produced `.runtime/portable/PlainVideo` with the executable, `libmpv-2.dll`, isolated assets, notices, pinned-runtime manifest, provenance, and per-file SHA-256 manifest. The copied directory played MKV + external SRT and exited 0 without using the repository runtime path. |

## Local quality gates

The final source is checked with:

```powershell
cargo fmt --all -- --check
cargo test --all-targets
cargo clippy --all-targets -- -D warnings
cargo build --release
```

PowerShell parser checks cover all scripts, the runtime and portable JSON manifests parse, `git diff --check` passes, and the portable directory receives its own playback smoke. No GitHub Actions workflow was added or run.

## Deliberate limits

- The two connected displays have the same 96-DPI scale. The message handler is covered, but a real transition between different scaling factors still needs physical evidence.
- The observed hardware path is `nvdec` on this NVIDIA machine. No claim is made for other GPUs, decoder modes, codecs, HDR, tone mapping, or software fallback.
- The OpenGL/WGL render path is the proven backend. Direct D3D11 composition, ANGLE, Vulkan, and zero-copy claims remain unproven.
- The right-click file picker and movement menu exist, but broader first-time-user usability has not been tested.
- Replacement received a focused three-load proof, not a long-duration decoder/GPU resource soak.
- The portable directory is a local developer proof only. The full component inventory, corresponding-source plan, notices, and redistribution decision are not complete, so it must not be published.

## Next gate

The remaining closure work is a cross-DPI physical test, a longer rapid-replacement and resize soak, and the complete libmpv/FFmpeg redistribution inventory. After those are recorded, the next product slice can add track selection, folder navigation, broader generated format evidence, and crash recovery without changing the borderless default surface.
