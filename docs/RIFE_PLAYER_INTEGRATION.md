# Experimental RIFE player integration

Date: 2026-07-23

Status: local experimental player integration verified; disabled by default;
not release-approved and not included in the ordinary portable or Store build

## Result

PlainVideo now has an isolated custom-libmpv build that can insert RIFE
4.25-lite midpoint frames before the normal libmpv renderer. This is actual
motion-estimated frame interpolation, not mpv display resampling.

The feature is exposed only when the staged root contains the experimental
RIFE DLL and model. In that build, the right-click menu contains `RIFE frame
interpolation (experimental)`. It remains off on every launch. The ordinary
libmpv runtime and release staging are unchanged.

The currently qualified playback policy is deliberately narrow:

- fixed 1920x1080 BGRA8 SDR filter boundary;
- the normal experimental option permits 24/25 fps source video and keeps
  source rates above 25.5 fps on the source-frame path;
- a separate development-only `max-source-fps=30.5` filter option exists for
  measured 30-to-60 probes; it does not change normal activation;
- unsupported size/format, scene change, discontinuity, queue pressure,
  deadline miss, or processing failure always selects a source-frame fallback;
- seek/reset waits for or discards the active worker result before flushing
  queued mpv frames;
- disabling the filter or closing the app joins the worker, frees the mpv
  refqueue in its required owner callback, destroys RIFE, and unloads the DLL.

## Scheduler and ownership

The custom `plainvideo-rife` mpv filter uses `mp_refqueue` with two future
frames. It presents the current source frame first and runs interpolation on a
dedicated worker. A two-entry task queue prepares the following pair while the
current midpoint is consumed. Results carry their midpoint PTS, so a result is
accepted only for the matching refqueue field.

This one-pair lookahead was required for real playback. A synchronous filter
and a first asynchronous version both made the RIFE call fit the source-frame
interval but started too late for the midpoint deadline, causing mpv A/V
desynchronisation warnings. The queued version gives steady-state work almost
the full source-frame interval and keeps audio pacing intact.

The filter explicitly frees `mp_refqueue` in its destroy callback. The queue
owns an autoconvert child filter; leaving it for generic talloc destruction
caused the child to be destroyed first and made `mpv_render_context_free()`
hang. The final teardown test completes the filter, render context, render
thread, and mpv core in order.

## Native performance evidence

Exact Quick ABCCBA evidence:
`.runtime/rife-spike/evidence/20260722-224602-858/summary.json`.

Machine: Windows 11, Ryzen 7 7800X3D, NVIDIA GeForce RTX 5070, driver 610.52.

| Cadence | Persistent Vulkan attempt p95 | Return p95 | GPU round-trip p95 | Deadline misses | Fixed limit | Result |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| 24 to 48 fps | 27.986 ms | 27.986 ms | 26.077 ms | 0 / 120 | 33 ms | Pass |
| 30 to 60 fps | 27.523 ms | 27.830 ms | 26.102 ms | 74 / 120 | 27 ms | Fail |

Generated-output proof passed with deterministic, changing outputs and
matching A/B/C digests. `activationEligible` remains false because both fixed
cadence gates must pass and Full qualification has not been run.

The fixed 27 ms native limit is a conservative product margin, not the actual
steady-state throughput interval. The queued player needs one generated
midpoint for each 30 fps source pair, so its worker has a 33.33 ms source-frame
interval in steady state. The product playback probe below confirms that this
distinction matters on the tested RTX 5070.

### Targeted 30-to-60 follow-up

A 2026-07-23 console-only follow-up measured only the persistent Vulkan path
for 180 frames after 20 warmups. It did not launch the player or run a long
foreground playback test.

| Runtime / precision | Mean | p95 | p99 | Max | At or below 30 ms | At or below 33.33 ms |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Pinned ncnn `305837f`, baseline | 27.216 ms | 27.685 ms | 28.078 ms | 28.162 ms | 180 / 180 | 180 / 180 |
| Pinned ncnn `305837f`, FP16 arithmetic | 26.896 ms | 27.612 ms | 28.206 ms | 28.623 ms | 180 / 180 | 180 / 180 |
| ncnn `a4d2ea1`, baseline compatibility probe | 27.244 ms | 27.679 ms | 28.535 ms | 28.662 ms | 180 / 180 | 180 / 180 |
| ncnn `a4d2ea1`, FP16 arithmetic compatibility probe | 27.053 ms | 27.427 ms | 27.991 ms | 28.048 ms | 180 / 180 | 180 / 180 |

The pinned results are under
`.runtime/rife-spike/targeted-30to60/`. The latest-ncnn compatibility probe is
under `.runtime/rife-spike/latest-ncnn-probe-20260723/`. The latter required
disabling the reference operator's obsolete Vulkan pack8 branch because
current ncnn removed that option. It is an isolated research build, not a
dependency update candidate.

This comparison rules out a simple ncnn upgrade as the missing optimization:
the latest runtime changed baseline mean by only +0.028 ms and FP16 mean by
+0.157 ms in these runs. The 27 ms activation gate still fails, but every
isolated sample retained at least 4.67 ms of headroom to the 33.33 ms source
interval. The remaining product risk is therefore concurrent playback tail
latency, not isolated average throughput.

The native benchmark now reports an informational `sourceIntervalAssessment`
beside the unchanged fixed activation gate. The player filter also keeps a
bounded 2,048-sample timing window and reports attempt p50/p95/p99, counts over
30 ms and 33.33 ms, plus GPU-round-trip p95/p99 and stage means/maxima. This
instrumentation was incrementally compiled into an isolated libmpv probe; no
new foreground playback evidence is claimed yet.

### Development-only Vulkan stage diagnostics

An optional `PLAINVIDEO_RIFE_GPU_TIMESTAMP_DIAGNOSTICS` build instruments the
persistent Vulkan command with query timestamps. It is off by default, sets
ncnn's benchmark support only in the isolated diagnostic build, and is excluded
from the activation gate. Normal builds expose the additive diagnostic getter
but return `available=false`.

Two 60-frame A/B repeats produced the following means. These were short console
runs and did not launch the player:

| Precision | Upload + preprocess | RIFE model | Postprocess | GPU timestamp span | Host GPU round trip | Full attempt |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Baseline run 1 | 0.504 ms | 24.725 ms | 0.020 ms | 25.249 ms | 27.329 ms | 29.102 ms |
| FP16 arithmetic run 1 | 0.482 ms | 23.365 ms | 0.020 ms | 23.868 ms | 25.923 ms | 27.851 ms |
| Baseline repeat | 0.503 ms | 24.645 ms | 0.020 ms | 25.168 ms | 27.416 ms | 29.402 ms |
| FP16 arithmetic repeat | 0.451 ms | 23.696 ms | 0.020 ms | 24.167 ms | 26.131 ms | 27.867 ms |

Evidence is under `.runtime/rife-spike/gpu-timestamp-evidence/` in the four
`diagnostic-*-60-20260723.json` files. Every run returned 60 consistent query
samples and passed the timing contract.

The model accounts for about 98% of the measured GPU command span. In the
baseline run, the stable largest layer costs were
`Deconvolution:ConvTranspose_487` at 1.44 ms and four seven-input `Concat`
layers at roughly 1.22 to 1.24 ms each. The latter total about 4.9 ms and point
to intermediate-tensor movement as a material optimization target, not merely
host upload or output conversion.

The pinned runtime's shader-pack8 path was also probed and rejected. Its RIFE
custom-shader combination failed SPIR-V compilation with an `sfpvec8`
redefinition and then terminated the probe process. The experimental switch
was removed rather than retained as an unsafe option.

### Byte-exact fused Concat prototype

The four stable hotspots have the same runtime layout at every stage: seven
1920x1152 FP16 tensors with scalar channel counts and packing
`3p1, 3p1, 4p4, 4p4, 1p1, 1p1, 8p4`. The stock ncnn layer records seven
channel-copy dispatches and then converts the 24-channel intermediate to
pack4. A diagnostic-only custom layer writes the final six pack4 planes in one
dispatch.

The prototype is compiled only with
`PLAINVIDEO_RIFE_FUSED_CONCAT_DIAGNOSTICS=ON` and activated only by the
development environment variable `PLAINVIDEO_RIFE_FUSED_CONCAT=1`. It
overwrites ncnn Concat only inside that diagnostic worker. It recognizes the
four exact layer names and runtime layouts; every other Concat or any layout
mismatch delegates to the original ncnn implementation.

Two paired 60-frame A/B repeats after ten warmups produced:

| Case | Attempt mean | Attempt p95 | Attempt max | Model mean | GPU round-trip mean | Deadline misses | Fixed gate |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| Baseline A | 29.168 ms | 30.032 ms | 30.522 ms | 25.340 ms | 27.700 ms | 60 / 60 | Fail |
| Fused A | 24.911 ms | 26.270 ms | 26.681 ms | 21.044 ms | 23.321 ms | 0 / 60 | Pass |
| Baseline B | 28.139 ms | 29.143 ms | 29.697 ms | 24.338 ms | 26.704 ms | 60 / 60 | Fail |
| Fused B | 25.044 ms | 26.463 ms | 26.915 ms | 21.109 ms | 23.465 ms | 0 / 60 | Pass |

All 120 fused measured frames reported exactly four fused calls, 480 total,
with zero target-layout fallbacks. Both fused runs passed the unchanged 27 ms
p95 gate and the timing/fallback contract. A final 60-frame repeat also passed
with 25.802 ms mean, 26.654 ms p95, 27.304 ms maximum, and two safe
deadline fallbacks.

The generated-output proof digests for all four deterministic input pairs are
identical between baseline and fused paths:
`e003cba18b1290fc`, `943d9105b8f45163`, `4a83a94a6312fdfc`, and the repeated
`e003cba18b1290fc`. A separately written 8,294,400-byte BGRA proof frame was
also byte-identical. This optimization changes tensor movement, not model
precision.

Evidence is under `.runtime/rife-spike/gpu-timestamp-evidence/` as
`fused-ab-*-60-20260723.json` and
`fused-concat-final-60-20260723.json`. The ordinary build explicitly keeps
both diagnostic CMake options off, does not compile the custom layer, reports
`fusedConcatBuilt=false`, and produced zero fused calls in its smoke proof.

The resulting optimization order is:

1. qualify FP16 arithmetic against a locked real-video corpus before any
   further performance use; the current synthetic proof has unacceptable
   localized outliers despite its small average error;
2. carry the byte-exact fused-Concat candidate into the experimental player
   worker and verify foreground A/V tail latency, seek/scene fallback, and
   teardown before changing the 30-to-60 policy;
3. pursue a GPU-native player/filter frame contract after the model work; the
   currently unattributed download, fence, command, and CPU portion is only
   about 2 ms and cannot close the fixed gate by itself;
4. evaluate a different compact model only with reproducible conversion,
   redistribution, and locked-corpus quality evidence.

None of these results changes activation. A candidate still needs the fixed
native gate, foreground A/V stability, seek/scene fallback, real-video quality,
and broader GPU evidence before 30-to-60 can move beyond an explicit
development option.

## Product playback evidence

Reproducible verifier:

```powershell
.\scripts\stage-rife-player.ps1
.\scripts\verify-rife-player.ps1 -SkipBuild
.\scripts\verify-rife-player.ps1 -SkipBuild -Probe30To60
.\scripts\verify-rife-player.ps1 -SkipBuild -Probe30To60 -SeekDuringProbe
.\scripts\verify-rife-player.ps1 -SkipBuild -Probe30To60 -SceneCutProbe
```

Default-policy evidence:
`.runtime/rife-player/evidence/20260722-234240-636/summary.json`.

| Case | Generated | Cadence fallback | A/V warnings | Processing errors | Clean exit |
| --- | ---: | ---: | ---: | ---: | --- |
| 1080p 24 to 48 | 118 | 0 | 0 | 0 | Yes |
| 1080p 30 default source fallback | 0 | 150 | 0 | 0 | Yes |

Development-only 30-to-60 evidence on the same RTX 5070:

| Probe | Generated | Safe fallback | Mean attempt | Max attempt | Deadline misses | A/V warnings | Errors |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Baseline, full 8 s | 236 | 4 overload | 29.295 ms | 42.512 ms | 1 / 239 | 0 | 0 |
| FP16 arithmetic, full 8 s | 236 | 4 overload | 28.459 ms | 42.054 ms | 1 / 239 | 0 | 0 |
| Baseline with backward seek | 306 | 4 overload | 29.320 ms | 44.125 ms | 1 / 309 | 0 | 0 |
| Baseline with one hard cut | 235 | 1 scene + 4 overload | 29.817 ms | 45.041 ms | 1 / 238 | 0 | 0 |

Evidence respectively:

- `.runtime/rife-player/evidence/20260722-234132-191/summary.json`;
- `.runtime/rife-player/evidence/20260722-234151-649/summary.json`;
- `.runtime/rife-player/evidence/20260722-234402-522/summary.json`;
- `.runtime/rife-player/evidence/20260722-234706-410/summary.json`.

The seek probe observed the initial start plus a second completed playback
restart and then resumed generation. The hard-cut probe detected exactly one
scene boundary and used a source frame for that pair.

An FP16 arithmetic development override reduced the repeated native benchmark
mean by about 0.81 ms and the full-playback mean by about 0.84 ms. It is not a
default candidate yet: its deterministic synthetic midpoint differs from the
upstream-compatible precision path by RGB MAE 0.526724, PSNR 40.3231 dB, and a
maximum edge-localized absolute difference of 249. Visual/corpus qualification
is required before treating that precision change as acceptable.

## Release blockers

This work is deliberately not a distributable feature yet:

1. the ncnn-converted 4.25-lite model still lacks a reproducible conversion
   record and locked-corpus equivalence proof against the official model;
2. only one GPU and one 1080p SDR format boundary have playback evidence;
3. a Full native run and longer replacement/seek soak are still required;
4. model, ncnn, shader, and runtime redistribution notices are incomplete;
5. the experimental custom libmpv artifact remains
   `candidate-not-release-approved`.

The reliable source-frame path remains the unconditional fallback and the
feature must never become an automatic default.
