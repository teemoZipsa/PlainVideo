# Quality pass 1-6

Date: 2026-07-19
Scope: local developer build; product polish before Store packaging

This document closes the first implementation pass across playback recovery, controls, Windows layout, media navigation, stability evidence, and format/accessibility baselines. It does not turn the current developer runtime into an approved redistributable release. Microsoft Store packaging remains planned in [STORE_RELEASE_PLAN.md](STORE_RELEASE_PLAN.md), and no GitHub Actions workflow was added or run.

## 1. Recoverable playback failures

PlainVideo now distinguishes normal end-of-file from a media load/decode failure. A bad file leaves the window alive on a localized error surface instead of terminating the app. Retry, Open, file drop, and previous/next queue navigation can recover the same process; unexpected libmpv core shutdown and render-thread failure remain fatal.

Local evidence: `.runtime/validation/integrated/20260719-021643-917/playback-recovery.json` is `verified` for a Korean invalid-media survival case and an English invalid-media-to-valid-replacement case. Both runs loaded the bundled configuration and exited cleanly; the replacement reached its first video frame. The verifier does not use OCR or a screen reader to prove the rendered sentence.

## 2. Playback, seek, volume, subtitle, and audio UX

The transient control bar now has a real volume slider beside the speaker icon, separate subtitle and audio-track handling, live/unseekable feedback, and visible hover, pressed, tooltip, and keyboard-focus states. Seek dragging uses bounded non-exact updates while moving and one exact seek on release. Keyboard routes include small/large seek, volume, mute, subtitle/audio cycling, focus traversal, and focused activation. The context menu exposes secondary track and queue actions without adding permanent chrome.

The native window owns input; the bundled mpv input file intentionally contains no parallel bindings. This prevents stale Alt-drag or duplicated playback actions from bypassing the Windows hit-test rules.

## 3. Small-window, scaling, and Windows behavior hardening

The playback geometry has a bounded maximum width and compact fallbacks. Primary and secondary are the only text tiers. Layout calculation separates logical viewport size, per-monitor DPI, and Windows text scale. Native hit testing and rendered hover/focus states share the same control rectangles, and capture/cancel/global mouse-up paths clear active drags.

Current evidence:

- 23 Rust tests passed, including control bounds at 96, 120, 144, 192, and 240 DPI, visible-track endpoint mapping, and the two-physical-pixel rounding tolerance.
- `.runtime/validation/integrated/20260719-021643-917/window-behavior.json` records physical-pixel save/restore, position-before-size restoration, two-monitor moves, fullscreen and minimized-state exclusion, 56 logical-pixel top move hit testing, seek interaction, DWM composition/style checks, and a 427×240 small-media window at 200% text scale.
- The paired `.runtime/validation/integrated/20260719-021643-917/small-video-text-200-percent.png` shows the focused top and bottom controls inside that small window without clipping or overlap.

Both connected monitors reported 96 DPI. Synthetic multi-DPI layout coverage passed, but a real 100%-to-150%/200% monitor transition remains pending. The screenshot shows a borderless edge and visible shadow, while the native checks establish opaque, non-layered DWM composition; neither alone proves every Windows theme or driver combination.

## 4. Open, drop, and previous/next flow

A folder-scoped media queue now uses deterministic natural-number ordering. Opening or dropping multiple explicit media paths preserves their supplied order; opening one file discovers eligible siblings in its folder. Normal EOF advances when another queued item exists. PageUp/PageDown and the context menu move backward or forward. Dropping a single subtitle adds and selects it instead of replacing the current video. libmpv autoload is disabled so there is one queue owner.

Queue ordering, extension classification, subtitle detection, and boundary behavior are covered by Rust tests. The soak replacement sessions and normal-EOF format runs exercise process-level load/finish paths, while exhaustive Explorer shell integration remains outside this pass.

## 5. Stability and replacement soak

The bounded soak harness samples process resources while resizing, minimizing, restoring, replacing media, and repeatedly starting and stopping the exact executable. The 2026-07-19 `Quick` run passed 8/8 sessions: two steady sessions and six churn sessions across normal `hwdec=auto-safe` and diagnostic forced software decode.

Evidence: `.runtime/validation/playback-soak/20260719-022128-153/evidence.json`. The normal-policy sessions observed `nvdec`; the forced `no` sessions observed software decoding. All eight sessions confirmed that the bundled configuration was loaded, and none recorded a render-stall warning. This is dirty-tree developer evidence, not proof of leak absence or a clean release candidate. The 10-minute/60-cycle-per-policy `Full` profile and a human audio/visual continuity review remain pending.

## 6. Exact format matrix and accessibility baseline

The generated format matrix passed 10/10 rows with 0 skips and 0 failures against the same hashed developer portable: MP4 H.264/AAC/SRT, Matroska H.264/FLAC/SRT, WebM VP9/Opus/VTT, MOV ProRes/PCM, AVI MPEG-4 Part 2/MP3, MPEG-PS MPEG-2/MP2, M2TS H.264/AAC, WMV WMV2/WMA2, Matroska FFV1/PCM software decode, and MP4 10-bit HEVC/AAC.

Evidence: `.runtime/validation/integrated/20260719-021643-917/format-matrix/playback-matrix.json`. All ten rows confirmed that the bundled `mpv.conf` was loaded. Exact artifact hashes and claim limits are in [FORMAT_COMPATIBILITY_LEDGER.md](FORMAT_COMPATIBILITY_LEDGER.md). AV1, HDR/tone mapping, Dolby Vision, VVC, protected content, network sources, damaged-media recovery, and profile-wide codec guarantees are not implied.

Keyboard reachability, visible focus, two-tier scaling, complete Korean/English locale sets, and native menu/file-picker use form the current accessibility baseline. Custom UI Automation/MSAA, Narrator, High Contrast, contrast measurement, and a complete both-language 100-200% manual matrix remain pending; see [ACCESSIBILITY_BASELINE.md](ACCESSIBILITY_BASELINE.md).

## Exact evidence boundary and next gate

The format, recovery, window, and soak checks all passed locally against executable SHA-256 `16780501f18baf6d3fc0f4f72ccf9b3c6e702d809c8e4355d86335442bfc2f98`, but they were produced while the quality-pass source was uncommitted. `scripts/run-local-validation.ps1` now composes the 13 checks into one future batch. The integrated run reached the soak step, where an earlier harness rule treated one transient resize warning as a permanent stall; the corrected soak then passed 8/8 separately against the unchanged portable. This is exact-artifact component evidence, not one fully green clean-source invocation.

The next release-quality gate is therefore:

1. repeat the integrated `Quick` batch from a deliberate clean candidate;
2. perform a real mixed-DPI monitor transition and both-locale manual scaling pass;
3. run the `Full` soak and review the resource traces plus picture/audio continuity;
4. implement and verify the missing accessibility provider and High Contrast behavior;
5. settle libmpv redistribution/licensing, then build and validate the first MSIX without broadening Store claims beyond exact packaged evidence.
