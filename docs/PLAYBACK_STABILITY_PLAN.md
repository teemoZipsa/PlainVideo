# Playback stability and soak plan

Date: 2026-07-19
Status: `Quick` verified on the local developer portable; `Full` release-candidate soak pending

## Purpose

PlainVideo must remain responsive while a real libmpv render context plays, changes media, resizes, minimizes, restores, and shuts down repeatedly. This plan defines the bounded local evidence required for that claim without adding a permanent diagnostic surface or a GitHub Actions workflow.

The executable is not built by the soak harness. Build or stage the exact candidate first, then run [verify-playback-soak.ps1](../scripts/verify-playback-soak.ps1) against it. Generated logs, settings, samples, and JSON stay under ignored `.runtime/validation` paths.

## Latest local result

The `Quick` profile passed all 8 bounded sessions on 2026-07-19: 2 steady-playback sessions and 6 replacement/startup/teardown sessions across `hwdec=auto-safe` and forced `hwdec=no`. The exact evidence is `.runtime/validation/playback-soak/20260719-022128-153/evidence.json`.

- Result: 8 `verified`, 0 `failed`
- Executable SHA-256: `16780501f18baf6d3fc0f4f72ccf9b3c6e702d809c8e4355d86335442bfc2f98`
- libmpv SHA-256: `5c876d79e070529128331591b48f87846fb30557f19c11280df9c6ee9b6dbafa`
- Normal policy observed hardware decode through `nvdec`; the forced `no` sessions observed software decode
- Every session recorded both resize targets plus minimize and restore, exited with code 0, and had no selected fatal log finding or app-error sidecar
- Source scope: base revision `49b0108f6c503ae127e46281425ddab48c276f95`, dirty with this quality pass at evidence time

This is useful regression evidence, but it is not the `Full` clean release-candidate result required by the completion gate below. It also does not replace a human audio/visual continuity pass.

## Profiles

| Profile | Steady playback per decode setting | Replacement sessions per decode setting | Session duration | Sampling |
|---|---:|---:|---:|---:|
| `Quick` | 12 seconds | 3 | 4 seconds | 500 ms |
| `Full` | 10 minutes | 60 | 5 seconds | 1 second |

Both profiles run `hwdec=auto-safe` and diagnostic `hwdec=no` by default. Durations and counts have bounded parameter ranges and can be overridden for a focused investigation. The script refuses evidence outside `.runtime/validation`, refuses to overwrite an earlier result, hashes its executable and media inputs, and kills only the process instance it started if the hard deadline is exceeded.

The steady phase passes the primary media path enough times to cover the requested duration. Its duration comes from `ffprobe` or an explicit `-PrimaryDurationSeconds` value. The churn phase starts the primary media, uses the existing `PLAINVIDEO_DIAGNOSTIC_REPLACE_PATH` timer to replace it after 700 ms, and exits through the existing diagnostic timer. Each churn cycle uses a fresh process so decoder/GPU teardown is exercised as well as replacement.

During every session a scoped Win32 helper operates only on that process's main window. It alternates 960×540 and 480×300 resizes, minimizes the window, restores it, and records the resulting rectangle and state. This is message-level automation, not a claim about visual quality.

## Commands

Generate the deterministic default inputs once, build the chosen executable separately, then run the quick profile:

```powershell
.\scripts\generate-smoke-media.ps1
cargo build --release
.\scripts\verify-playback-soak.ps1
```

Run the longer gate only after the quick profile passes:

```powershell
.\scripts\verify-playback-soak.ps1 -Profile Full
```

Target a staged portable directory and its exact runtime explicitly:

```powershell
.\scripts\verify-playback-soak.ps1 `
  -Profile Full `
  -Executable .\.runtime\portable\PlainVideo\plainvideo.exe `
  -AppRoot .\.runtime\portable\PlainVideo `
  -LibmpvPath .\.runtime\portable\PlainVideo\libmpv-2.dll
```

Run only one decoder policy when isolating a problem:

```powershell
.\scripts\verify-playback-soak.ps1 -HwdecModes auto-safe
.\scripts\verify-playback-soak.ps1 -HwdecModes no
```

## Evidence contract

Every result is a versioned JSON document with:

- SHA-256 and byte size for the executable, media fixtures, `mpv.conf`, Lua overlay, and an explicitly supplied libmpv DLL;
- current Git revision and dirty-worktree state when Git is available;
- resolved profile, timings, queue size, replacement delay, sample interval, and decoder settings;
- exit code, timeout/forced-termination state, first-frame count, observed decoder path, fatal-log findings, and app-error sidecar lines for every process;
- time-series working set, private memory, paged memory, handle count, thread count, CPU time, and window state;
- first/last/delta/peak resource summaries for each bounded process;
- every resize, minimize, and restore action with success state and resulting physical window rectangle;
- separate pass/fail checks and artifact paths for every steady and churn run.

A session passes only when it starts and exposes its window, exits with code 0 before the deadline, records the expected first frames and decoder mode, has no known fatal/Lua/render/load pattern or repeated render-stall warning, writes no app-error sidecar line, contains resource samples, and completes both resize sizes plus minimize and restore successfully. A single transient libmpv render-stall warning during a forced resize is recorded as an observation; two or more in one bounded session fail the run.

The JSON can be called release evidence only when its executable and runtime hashes match the candidate being evaluated and the source state is intentionally clean. A developer build from a dirty tree remains diagnostic evidence.

## Decoder claims

`auto-safe` is the normal product policy. It asks libmpv to choose a safe hardware path when available and permits libmpv's normal fallback behavior. A run may be recorded as hardware-decoded only when the exact log names `Using hardware decoding (...)`. Merely setting `auto-safe` is not hardware evidence, and a software result under `auto-safe` is not a failure by itself.

`PLAINVIDEO_DIAGNOSTIC_HWDEC=no` deliberately disables hardware decoding for that diagnostic process. A passing `no` run proves that the same executable, runtime, file, render surface, and shutdown path can play through a software decoder. It does **not** prove that an actual hardware-decoder failure was detected and automatically retried. That stronger claim needs a reproducible hardware-failure injection or a machine on which the selected hardware decoder fails, followed by evidence that PlainVideo recovers without user-visible corruption or a restart loop.

Neither setting generalizes to untested codecs, bit depths, profiles, GPUs, drivers, HDR paths, or the future redistributable Store runtime. Format claims continue to come from the generated compatibility ledger for the exact runtime.

## Interpretation and limits

- A bounded flat or settling resource trace is useful regression evidence, but one run cannot prove the absence of every leak. Compare repeated clean-build results and investigate monotonic working-set, private-memory, handle, or thread growth.
- Churn currently means one 700 ms replacement per process repeated across many fresh processes. It proves rapid replacement plus repeated startup/teardown. It does not yet prove hundreds of replacements inside a single libmpv instance; that requires a bounded multi-replacement diagnostic command in a later slice.
- Process counters do not measure GPU-resident allocations. GPU memory needs a separate vendor-neutral or ETW-based probe before a GPU-leak claim.
- A first-frame log proves decoder/render progress, not that every frame is visually correct. The harness does not judge corruption, subtitle placement, audio continuity, A/V sync, frame pacing, HDR correctness, thermals, or power use.
- Minimize/restore and resize messages prove that the app remained alive and accepted the operations. A short manual viewing pass is still required for black frames, stale frames, overlay clipping, and audible discontinuities.
- Diagnostic timer exits are deliberate clean exits. Unexpected libmpv shutdown, render-thread failure, and playback-error recovery need their own fault-injection evidence.

## Completion gate

Phase 5 is complete only when:

1. `Quick` passes from the current local release build;
2. `Full` passes from the exact staged portable candidate and approved libmpv runtime;
3. resource traces have been reviewed rather than accepted solely from exit code;
4. the candidate receives a manual picture/audio/minimize/restore check;
5. any observed hardware path and the forced software path are reported separately; and
6. the resulting evidence path, hashes, date, machine scope, and remaining limitations are linked from the release proof document.
