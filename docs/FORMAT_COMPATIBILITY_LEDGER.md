# Format compatibility ledger

## Claim boundary

PlainVideo reports a format as **verified** only when the exact developer portable directory plays a generated file, reaches its first video frame, exposes the expected video/audio/subtitle tracks, reaches natural end-of-file (`EOF code 1`, finish reason `0`), records no selected fatal pattern, and exits cleanly. Encoder availability, an FFmpeg or mpv help listing, and a generated fixture are not playback proof.

The checked-in specification is [`scripts/format-fixtures.json`](../scripts/format-fixtures.json). Per-run evidence stays under ignored `.runtime/format-matrix` or `.runtime/validation` directories so generated media and machine-specific logs are never committed accidentally.

## Status vocabulary

| Status | Meaning |
| --- | --- |
| `verified` | The exact portable EXE, adjacent `libmpv-2.dll`, copied mpv configuration, copied overlay, and matching fixture hash passed every row check. |
| `skipped` | The local fixture generator lacked a required executable, encoder, or muxer. This is neither verified support nor a PlainVideo playback failure. The evidence records the exact reason. |
| `failed` | Fixture generation failed unexpectedly, evidence hashes changed, PlainVideo failed to reach the first frame or expected tracks, playback did not complete, a fatal log pattern appeared, the run timed out, or the process returned nonzero. |
| `specified` | The row exists in the checked-in plan but has no current playback-matrix result. It must not be advertised as verified. |

## Latest local developer result

On 2026-07-19 all 10 specified rows passed against one exact developer portable directory: 10 `verified`, 0 `skipped`, and 0 `failed`. Every row also confirmed that the bundled `mpv.conf` was actually loaded. The evidence is `.runtime/validation/integrated/20260719-021643-917/format-matrix/playback-matrix.json`.

- PlainVideo executable SHA-256: `16780501f18baf6d3fc0f4f72ccf9b3c6e702d809c8e4355d86335442bfc2f98`
- libmpv SHA-256: `5c876d79e070529128331591b48f87846fb30557f19c11280df9c6ee9b6dbafa`
- libmpv source recorded by the portable manifest: `mpv-winbuild-cmake` build `20260610-git-304426c`
- Host scope: Windows `10.0.26200.0`, NVIDIA GeForce RTX 5070 plus AMD Radeon Graphics
- Source scope: base revision `49b0108f6c503ae127e46281425ddab48c276f95`, with the quality-pass changes still dirty at validation time

This closes the first matrix as **local developer evidence**, not as a redistributable release or Store support statement. The runtime redistribution decision is still open, and a clean release candidate must repeat the matrix with matching source and package hashes.

## Historical verified baseline

The current checked-in proof documents only these real playback combinations:

| Container | Video | Audio | Subtitle | Scope |
| --- | --- | --- | --- | --- |
| MP4 | H.264 8-bit 4:2:0 | AAC | Same-name external SRT | Verified by the current embedded developer portable on the development machine. |
| Matroska | The same H.264 stream remuxed from the MP4 fixture | The same AAC stream | Same-name external SRT | Verified as a container/remux path; this is not an independent codec combination. |

The exact historical evidence and limits are in [`SLICE_0B_LIBMPV_PROOF.md`](SLICE_0B_LIBMPV_PROOF.md) and [`WINDOW_BEHAVIOR_PROOF.md`](WINDOW_BEHAVIOR_PROOF.md). The observed `nvdec` selection is a result for one NVIDIA machine, not a guarantee for other GPUs.

## Checked-in matrix specification and latest result

The JSON file remains the durable specification. The result column below describes only the exact local developer run identified above; it does not make future builds automatically verified.

| Row | Intended combination | Special assertion | 2026-07-19 local result |
| --- | --- | --- | --- |
| `mp4-h264-aac-srt` | MP4 / H.264 / AAC / external SRT | Same-name external subtitle discovery | `verified` |
| `mkv-h264-flac-srt` | Matroska / H.264 / FLAC / embedded SRT | Embedded subtitle track | `verified` |
| `webm-vp9-opus-vtt` | WebM / VP9 / Opus / external WebVTT | External VTT discovery | `verified` |
| `mov-prores-pcm` | QuickTime / ProRes Proxy / PCM | Editing-oriented intra codec and uncompressed audio | `verified` |
| `avi-mpeg4-mp3` | AVI / MPEG-4 Part 2 / MP3 | Legacy container path | `verified` |
| `mpeg-mpeg2-mp2` | MPEG program stream / MPEG-2 Video / MP2 | MPEG-PS path | `verified` |
| `m2ts-h264-aac` | M2TS / H.264 / AAC | Blu-ray-style transport-stream muxing | `verified` |
| `wmv-wmv2-wmav2` | ASF/WMV / WMV2 / WMA2 | Legacy Windows media path | `verified` |
| `mkv-ffv1-pcm-software` | Matroska / FFV1 / PCM | Must report software decoding under `hwdec=auto-safe` | `verified` |
| `mp4-hevc10-aac` | MP4 / 10-bit HEVC / AAC | 10-bit decode path; hardware use is observed, not required | `verified` |

AV1, HDR metadata and tone mapping, Dolby Vision, VVC, optical media, network protocols, damaged-file recovery, multi-angle media, and protected content are outside this first matrix. Their absence is intentional and must not be rewritten as support or failure.

## Local reproduction

Use a freshly built developer portable directory. The verifier deliberately has no fallback to `target/release`; it validates hashes from the portable manifest before launching anything.

```powershell
Set-Location C:\Users\Seonkyu\Myproject\PlainVideo

# Build preparation is separate from the matrix run.
.\scripts\bootstrap-mpv.ps1
cargo build --release
.\scripts\build-portable.ps1 -SkipBuild

# Prefer a pinned generator under .runtime\ffmpeg\bin, or pass exact paths.
.\scripts\generate-format-fixtures.ps1 `
  -FfmpegPath .runtime\ffmpeg\bin\ffmpeg.exe `
  -FfprobePath .runtime\ffmpeg\bin\ffprobe.exe

.\scripts\verify-format-matrix.ps1 -RequireAllRows
```

When explicit paths are omitted, the generator checks `.runtime\ffmpeg` first and then PATH. In every case it records each tool's absolute path, SHA-256, and version. A release-candidate matrix should use an intentionally pinned generator path; PATH fallback is suitable only for developer evidence.

`generate-format-fixtures.ps1` writes fixture hashes, exact FFmpeg arguments, FFprobe metadata, and `skipped` reasons to `.runtime/format-matrix/fixtures/fixture-evidence.json`. `verify-format-matrix.ps1` creates a timestamped directory containing:

- `playback-matrix.json` with artifact, environment, expected and observed fields;
- `playback-matrix.md` as a compact human-readable summary;
- one verbose libmpv log and isolated settings file per generated row.

Use `-RequireAllRows` for a closure run. Without it, unavailable generator capabilities remain honest `skipped` rows while genuine generation or playback failures still return a nonzero result.

## Interpretation rules

- A passed container/codec pair does not prove every profile, bit depth, resolution, frame rate, channel layout, subtitle encoding, or damaged-file variant.
- Hardware decoder names listed by the runtime are capabilities to attempt, not evidence that the local GPU accepted a row.
- `hardwarePath` is recorded when selected. The FFV1 row specifically requires software decoding; other rows may pass through hardware or software.
- The generator's FFprobe metadata describes the test input. PlainVideo's libmpv log is the playback observation. Neither substitutes for the other.
- Only rows whose evidence hashes match the exact portable artifact may inform file associations, Store copy, README claims, or support documentation.
