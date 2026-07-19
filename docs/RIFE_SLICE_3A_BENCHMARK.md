# RIFE Slice 3A performance spike

Date: 2026-07-19

Status: native in-memory spike implemented and locally measured; **activation gate failed**

Release state: developer-only, not connected to mpv, not included in portable or Store artifacts

## Outcome

PlainVideo now has a separate Windows x64 benchmark boundary for RIFE 4.25-lite
on ncnn/Vulkan. The DLL accepts two caller-owned `1920x1080` BGRA8 SDR frames
and writes the `t=0.5` intermediate frame into caller-owned memory. It does not
write PNG frames, launch a per-frame process, or run after libmpv's Render API.

The current RTX 5070 result is not fast enough for either proposed cadence.
Consequently, `Frame doubler 2x` must remain absent from the product UI and
disabled in playback. mpv's separate display-resample path is unchanged and is
not described as generated-frame interpolation.

## Spike boundary

Tracked implementation:

- `native/rife-benchmark/include/plainvideo_rife.h`: versioned C ABI;
- `native/rife-benchmark/src/checked_rife_v4.cpp`: checked RIFE v4 model,
  shader, pipeline, extractor, allocation, and Vulkan submission path;
- `native/rife-benchmark/src/plainvideo_rife.cpp`: persistent GPU context,
  BGRA8 adapter, counters, and immediate fallback;
- `native/rife-benchmark/src/benchmark.cpp`: deterministic in-memory frames,
  cold initialization, warm-up, percentile reporting, and fallback proof;
- `scripts/bootstrap-rife-spike.ps1`: exact source/submodule/model verification;
- `scripts/build-rife-spike.ps1`: isolated `/MT` DLL and CLI build;
- `scripts/verify-rife-spike.ps1`: 24-to-48 and 30-to-60 evidence capture.

All cloned sources, model files, binaries, and evidence stay below ignored
`.runtime/rife-spike`. The regular Cargo build, local playback validation,
developer portable staging, and current mpv configuration do not depend on the
spike.

The ABI deliberately supports only:

- Windows x64;
- 1920x1080 BGRA8 SDR input and output with explicit strides;
- two input frames and one caller-owned output frame;
- RIFE 4.25-lite, TTA off, 128-pixel model padding;
- exactly `t=0.5`, corresponding to 2x frame doubling;
- one synchronous call at a time per context.

Scene-cut detection and seek/discontinuity knowledge belong to the future mpv
filter/scheduler. The DLL accepts explicit scene-change, discontinuity, and
overload signals. Each signal bypasses inference and copies the previous source
frame into the intermediate slot immediately. Queue depth above one also
bypasses. The benchmark verifies these outputs byte-for-byte and records
generated, bypassed, processing-error, and deadline-fallback counts. Destruction
requires external lifecycle synchronization: all calls must have returned before
the caller destroys a context.

## Pinned prototype inputs

| Component | Pin | Role |
| --- | --- | --- |
| VapourSynth-RIFE-ncnn-Vulkan | `r9_mod_v33`, `c3ec6aabc07c8fa37a4f58d7fed9e2ad1fc1b13f` | Maintained MIT reference RIFE/ncnn core and converted model |
| ncnn | `20250503`, `305837fd4a722ebc47c5d72e72d8ec9ae970e932` | Reference plugin's tested BSD-3-Clause submodule |
| glslang | `a9ac7d5f307e5db5b8c4fbf904bdba8fca6283bc` | ncnn online Vulkan shader compilation submodule |
| RIFE 4.25-lite `flownet.bin` | SHA-256 `350a15e464bea5ad378e06c0fb43996e90a0d35653d5a6ef6bc980d832538fb7` | Prototype ncnn weights |

The exact manifest is `third_party/rife-spike.json`.

There is an unresolved provenance gate: Practical-RIFE publishes the official
4.25-lite PyTorch weight, while the reference plugin contains an ncnn
`param/bin` conversion without a reproducible conversion recipe or a manifest
proving equivalence to that official weight. The converted model is valid only
as a performance-spike input. It must not enter a release until the conversion
is reproduced and compared against the official model on a locked frame corpus.

## Local measurement

Machine:

- Windows 11 Pro build 26200;
- AMD Ryzen 7 7800X3D;
- NVIDIA GeForce RTX 5070, Vulkan 1.4.341;
- Quick profile: 10 warm-up frames and 60 measured frames per cadence.

The timer reported by the DLL splits CPU input conversion, the checked core path,
and CPU output conversion. The checked core path includes host ncnn Mat
allocation and a second planar copy as well as GPU upload, RIFE inference,
synchronized download, and host copy. It is therefore a conservative integration
measurement, not a pure model-kernel timing claim. The requested gate is this
core-path p95 at or below 33 ms for 24 fps and 27 ms for 30 fps. Product
qualification is deliberately explicit rather than a hidden
maximum-frame rule: the verifier also requires end-to-end p95 within the same
budget, permits at most the slowest 5 percent to fall back (3 of 60 in Quick),
requires zero processing errors, and requires all safety proofs to pass.

| Cadence | Core-path p95 limit | Core path p95 | End-to-end p95 | Generated / overload bypass / processing error | Deadline fallbacks (allowed) | Result |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| 24 to 48 fps | 33 ms | 69.501 ms | 127.833 ms | 0 / 60 / 0 | 60 (3) | Fail |
| 30 to 60 fps | 27 ms | 58.757 ms | 113.935 ms | 0 / 60 / 0 | 60 (3) | Fail |

Every measured call exceeded its end-to-end deadline. The DLL therefore copied
the previous source frame back into the output for the same call and correctly
classified all 60 calls per cadence as overload bypasses rather than generated
frames. All 120 measured fallback outputs matched the previous source frame
byte-for-byte, and an additional one-microsecond-deadline call forced and proved
the same post-inference path for each profile. There were no processing-error
misses. The explicit signal fallback proof also passed with one scene-change
bypass, one discontinuity bypass, and two overload bypasses per profile.
Non-finite timestep rejection, overlapping-buffer rejection, unchanged inputs,
unchanged invalid-request output, and output guard regions all passed.

A Full run is intentionally not used to rescue this result: the Quick profile
already exceeds both core-path limits by a large margin. A follow-up
implementation has now eliminated the duplicate host preparation and measured
both persistent host and persistent staged Vulkan buffers. The complete
product-equivalent boundary still fails. Exact A-B-C evidence and the Windows
GPU-native boundary decision are recorded in
[`RIFE_SLICE_3A_BUFFER_OPTIMIZATION.md`](RIFE_SLICE_3A_BUFFER_OPTIMIZATION.md).

Evidence for this run is stored locally at
`.runtime/rife-spike/evidence/20260719-094830-360/summary.json`. Its SHA-256 is
`1fefb1bd0a76c308e7be8c3fd0fc69ca5e5abe4dc13e72aafdf5286fd7d14983`. It records the
dirty repository state honestly because unrelated Store/icon work was present.

## Reproduction

```powershell
.\scripts\bootstrap-rife-spike.ps1
.\scripts\build-rife-spike.ps1 -Configuration Release
.\scripts\verify-rife-spike.ps1 -Profile Quick -GpuIndex 0 -SkipBuild
```

The verifier exits `0` only when both cadence performance gates pass and `2`
when a measurement completes but either gate fails. A Quick pass is only a
candidate result. `Full` increases the run to 60 warm-up and 600 measured frames
per cadence and is required before `activationEligible` can become true; it is
not useful after this conclusive Quick rejection.

## Next technical decision

Do not connect this implementation to mpv yet. Persistent host/Vulkan reuse is
implemented, but the host BGRA8 product boundary still misses both budgets and
the pinned ncnn runtime has no proven Windows decoder-surface import contract.
Any later runtime or explicit interop prototype must preserve source-frame
fallback, include color conversion and transfer costs in the product gate, and
close model-conversion provenance before release work.
