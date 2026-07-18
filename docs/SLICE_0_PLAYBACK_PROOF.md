# Slice 0A playback-surface proof

Date: 2026-07-18
Status: locally verified, pre-alpha, not distributable

## What this slice proves

PlainVideo can keep the screen almost entirely video while using a real native playback engine. The proof is a small Rust launcher plus a pinned mpv executable and an isolated PlainVideo configuration.

The launcher supplies product-defining window options after mpv's pseudo-GUI profile, loads only PlainVideo's input map and overlay script, forwards media paths after an option terminator, and reports startup failures with a native Windows error dialog.

## Locked developer runtime

- Source build project: `shinchiro/mpv-winbuild-cmake`
- Release: `20260610`
- Asset: `mpv-x86_64-20260610-git-304426c.7z`
- SHA-256: `facac536baa73c7b925771af5e39a3c9cb16b8d75b59a6e9800de89799dffca7`
- Runtime report: mpv `v0.41.0-744-g304426c39`, libplacebo `v7.365.0`, FFmpeg `N-124930-g2576e0943`

This binary is treated conservatively as GPL-2.0-or-later and is downloaded only for development. It is not a PlainVideo release artifact.

## Deterministic fixtures

`scripts/generate-smoke-media.ps1` produces:

- a 30-second, 1280×720, 30 fps H.264/AAC MP4;
- a stream-copy Matroska remux;
- a same-name external SRT file;
- FFprobe metadata JSON.

Generated files stay under `.runtime/` and are not committed.

## Verified behavior

| Behavior | Evidence |
|---|---|
| Borderless surface | Window opened at 1280×720 with no native title bar or permanent toolbar. |
| Play/pause | A single click froze the fixture's frame timer; a short custom pause glyph appeared and cleared. |
| Seek | Right arrow moved the paused timer forward exactly 5 seconds and showed a thin progress line with elapsed/total time. |
| Fullscreen | Double click entered the current 5120×1440 display only; `Esc` restored the 1280×720 window. A second connected display begins at X=5120 and was not covered. |
| Empty surface | Only the localized Korean drop hint remained; mpv's logo and generic idle copy were absent. |
| External subtitle | The same-name SRT was discovered and rendered. |
| Decode smoke | Both MP4 and MKV fixtures decoded through the pinned runtime; the interactive Windows run reported `d3d11va-copy` hardware decoding. |
| Local quality gates | Rust tests, formatting, Clippy with warnings denied, release build, PowerShell parsing, manifest parsing, and diff whitespace checks passed locally. |

## Deliberate limits

- mpv is a child process in Slice 0A. Direct libmpv render-API embedding is the next architecture gate.
- Drag-and-drop replacement is configured but has not yet received a recorded end-to-end UI proof.
- Only the fixture codecs, containers, subtitle path, and observed hardware-decoder path above are verified. No exhaustive format, HDR, tone-mapping, or software-fallback claim is made.
- There is no portable bundle, installer, file association, Store package, or release binary.
- Display-resample is disabled. No generated-frame interpolation or RIFE runtime is present.
- The developer runtime still needs a complete build-component inventory, source/notice plan, and redistribution decision.

## Next gate

Slice 0B has now embedded libmpv in a PlainVideo-owned window, preserved the interaction proof, validated real drag/drop replacement, and produced a local developer portable directory. See [the Slice 0B libmpv proof](SLICE_0B_LIBMPV_PROOF.md) for the exact evidence and remaining cross-DPI, soak, and redistribution limits. A generated format matrix comes after the exact release runtime is licensed and locked. Display synchronization and experimental RIFE-based 2× interpolation remain later, separately measured slices.
