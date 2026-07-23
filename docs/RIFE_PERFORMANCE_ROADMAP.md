# RIFE performance roadmap

Status: planned work for the local experimental player
Last updated: 2026-07-23

This document defines the next five RIFE performance workstreams. It separates
measured evidence from proposed work and gives each workstream an explicit
fallback, validation plan, and completion gate.

Nothing in this roadmap changes the current product policy:

- RIFE remains optional and experimental;
- the reliable source-frame path remains available at all times;
- the normal portable and Store builds must not acquire the model or custom
  filter by accident;
- 30-to-60 activation remains a development override until real playback,
  quality, hardware, licensing, and distribution gates close;
- a performance target is not a capability claim until it passes on the exact
  artifact intended for distribution.

## Current baseline

The measurements below are evidence from the tested RTX 5070 and the pinned
1920x1080 BGRA8 SDR boundary. They are not projections for other GPUs, formats,
or resolutions.

| Area | Current evidence |
| --- | --- |
| Model and runtime | RIFE 4.25-lite through the pinned ncnn/Vulkan worker |
| Normal activation | 24/25 fps only; 30 fps requires an explicit development override |
| Ordinary worker | Fused Concat and GPU timestamp diagnostics are both compiled out |
| Fused diagnostic worker | Four exact seven-input Concat layers are replaced; every other Concat or layout mismatch delegates to ncnn |
| Fused output proof | Four deterministic digests and one 8,294,400-byte BGRA frame are byte-identical to the baseline path |
| Fused coverage | 480 fused calls over 120 measured frames; zero target-layout fallbacks |
| Final fused timing sample | 25.802 ms mean, 26.654 ms p95, 27.304 ms maximum, and two safe deadline fallbacks over 60 measured frames |
| Largest remaining measured layer | `Deconvolution:ConvTranspose_487`, about 1.44 ms in the instrumented baseline |
| FP16 arithmetic effect | About 0.81 ms faster in the repeated native benchmark and 0.84 ms faster in the eight-second playback probe |
| FP16 quality warning | RGB MAE 0.526724, PSNR 40.3231 dB, and an edge-localized maximum absolute difference of 249 in the deterministic synthetic comparison |
| Current frame boundary | Full 1920x1080 BGRA8 frames cross the player/filter and worker boundary through host-visible memory |

The fused diagnostic result closes the fixed 27 ms native p95 gate on the
tested GPU. It does not by itself close foreground A/V stability, longer soak,
multi-GPU, model provenance, quality, or redistribution gates.

## How to read the five workstreams

The numbers preserve the product discussion order, but they are not a command
to combine every optimization at once. Each optimization must first be
measured alone against the same baseline. Combining changes too early would
make regressions and quality differences difficult to attribute.

Recommended execution:

1. make the byte-exact fused worker reproducible in the experimental player;
2. profile and prototype the remaining Deconvolution hotspot independently;
3. qualify FP16 independently against a locked real-video corpus;
4. run the GPU-resident frame-exchange feasibility branch after the worker
   baseline is stable;
5. design lower-performance hardware modes from the evidence produced by the
   first four workstreams.

Workstreams 2 and 3 may be researched in parallel after workstream 1, but they
must retain separate artifacts and evidence.

## 1. Promote fused Concat into the normal experimental worker

### Goal

Turn the current diagnostic-only fused Concat prototype into a reproducible
experimental-player worker without enabling it in the normal portable or Store
artifact.

This is packaging and hardening of an already measured optimization, not a new
performance experiment. The expected benefit is preservation of the roughly
3-4 ms improvement observed in the paired diagnostic runs, without GPU
timestamp instrumentation or manual DLL replacement.

### Current gap

The custom layer is currently compiled only when
`PLAINVIDEO_RIFE_FUSED_CONCAT_DIAGNOSTICS=ON` and activated by
`PLAINVIDEO_RIFE_FUSED_CONCAT=1`. The ordinary worker explicitly compiles it
out. The currently running local player is assembled by manually replacing its
ordinary worker with that diagnostic DLL.

That arrangement is useful for A/B evidence but is not reproducible enough for
a product candidate.

### Proposed implementation

1. Split the build concepts:
   - keep `PLAINVIDEO_RIFE_GPU_TIMESTAMP_DIAGNOSTICS` development-only;
   - retain the existing diagnostic fused switch for baseline A/B work;
   - add a separately named experimental-player fused option that does not
     imply timestamp or benchmark instrumentation.
2. Make the experimental fused worker automatically use the custom layer only
   when all exact contracts match:
   - one of the four locked layer names;
   - seven inputs;
   - the expected width, height, channel counts, packing, element size, and
     storage type;
   - the pinned model identity.
3. Delegate to the ordinary ncnn Concat implementation on every mismatch.
   Model or graph changes must reduce performance safely rather than corrupt
   output or fail startup.
4. Extend the staging manifest with:
   - worker variant;
   - DLL SHA-256;
   - model parameter and weight hashes;
   - ncnn and Practical-RIFE source revisions;
   - relevant CMake options;
   - explicit `gpuTimestampDiagnostics=false`;
   - explicit `fusedConcat=true`.
5. Teach `stage-rife-player.ps1` to select that worker directly. Manual DLL
   replacement must no longer be necessary.
6. Keep the normal portable candidate test asserting that no RIFE filter,
   worker, model, or experimental manifest is included.

### Validation

- Repeat the deterministic four-pair output proof.
- Require the same four digests and byte-identical BGRA proof frame.
- Repeat paired ordinary-versus-fused timing after fixed warmups.
- Verify four custom calls per generated midpoint on the locked graph.
- Deliberately alter each layout contract in a diagnostic fixture and prove
  delegation to the stock ncnn layer.
- Run real player cases for:
  - normal playback;
  - backward and forward seek;
  - pause and resume;
  - hard scene cut;
  - end-of-file and next-file transition;
  - filter disable and re-enable;
  - clean application shutdown.
- Confirm that missed deadlines still publish a source-frame fallback.

### Completion gate

Workstream 1 is complete only when:

- the experimental player can be staged from a clean checkout with one checked
  script command;
- its manifest completely identifies the fused worker;
- timestamp diagnostics are absent;
- deterministic output remains byte-identical;
- the fixed 27 ms p95 native gate passes on the reference machine in two
  repeated runs;
- foreground playback, seek, scene-cut, and teardown probes report no A/V
  warning or processing error;
- normal portable and Store artifacts remain unchanged.

### Main risks

- The optimization depends on exact graph names and layouts.
- A model upgrade can silently invalidate those assumptions unless the pinned
  model identity is part of the activation contract.
- Removing diagnostic instrumentation may change timing slightly; the product
  artifact still needs its own measurement.

## 2. Keep decoded and generated frames on the GPU

### Goal

Remove avoidable full-frame CPU memory traffic between decode, interpolation,
and presentation. The long-term target is:

```text
hardware decoder surface
  -> GPU color/format preparation
  -> RIFE Vulkan inference
  -> GPU presentation surface
```

The source-frame fallback must remain available without waiting for a GPU
readback.

### Why this is not the first optimization

The measured RIFE model accounts for about 98% of the instrumented GPU command
span. The currently unattributed download, fence, command, and CPU portion is
only about 2 ms in the isolated evidence. A GPU-resident path can reduce CPU
usage, memory bandwidth, power, and tail latency, but it must not be described
as a guaranteed multi-millisecond model speedup before measurement.

Its larger value is architectural:

- avoid repeated 1920x1080 BGRA host copies;
- avoid forcing a copy-oriented decode path solely for the interpolation
  filter;
- reduce contention and long-tail stalls during foreground playback;
- prepare for higher resolutions where host bandwidth becomes more expensive.

### Feasibility branches

#### Branch A: D3D11-to-Vulkan external-memory sharing

This is the preferred first probe on Windows.

1. Decode into a D3D11 texture on the same physical adapter used by Vulkan.
2. create or obtain a shareable D3D11 resource;
3. import its Win32 handle into Vulkan external memory;
4. synchronize ownership with external fences or semaphores;
5. run color conversion and RIFE input packing on the GPU;
6. expose the generated texture to the presentation path without a CPU
   readback.

The feasibility probe must verify the required Vulkan external-memory and
external-semaphore extensions on the exact adapter. It must not assume that
adapter index 0 in one API refers to the same physical device in the other.

#### Branch B: mpv/libplacebo Vulkan-native filter boundary

This could keep frames inside a Vulkan/libplacebo graph, but it may depend on
private mpv filter internals rather than the stable public libmpv client API.
The prototype must document which interfaces are pinned and the maintenance
cost of every mpv update.

#### Branch C: a different inference backend

DirectML or TensorRT could share D3D11 resources more naturally on some
hardware. This is a separate backend decision, not a small transport change:

- TensorRT narrows vendor support and adds engine-build/distribution work;
- DirectML requires a separately validated model conversion and performance
  path;
- neither branch may replace the cross-vendor ncnn/Vulkan fallback without
  broader evidence.

Branch C should not start until A and B have quantified why Vulkan interop is
insufficient.

### Required design details

- Match devices by adapter identity, not enumeration order.
- Define ownership for source, midpoint, and fallback textures.
- Bound the number of in-flight textures.
- Specify fence and timeout behavior.
- Handle resize, seek, decoder reinitialization, device loss, sleep/resume, and
  GPU-driver reset.
- Keep color range, transfer, primaries, and chroma handling explicit.
- Do not silently treat HDR, P010, NV12, or non-1080p input as the current
  verified BGRA8 SDR path.
- Keep a host-copy fallback until the GPU-native path has independent proof.

### Validation

Measure the old and new paths with the same file, playback position, decoder,
display mode, GPU clocks, warmup, and RIFE worker:

- CPU utilization and CPU frame-copy time;
- process working set and committed GPU memory;
- full-attempt p50/p95/p99 and maximum;
- A/V sync warnings and displayed-frame drops;
- memory bandwidth where a reliable vendor or OS counter exists;
- power and thermals during a fixed soak;
- exact or tolerance-bounded frame comparison at the presentation boundary.

### Completion gate

- No full 1080p CPU readback/upload occurs on the qualified path.
- Adapter matching and synchronization are proven across restart and seek.
- A device mismatch or unsupported extension falls back before playback
  begins.
- The source frame remains immediately available on every inference error or
  missed deadline.
- Foreground p95/p99, CPU use, and power results are measurably better than the
  host path; the document must report a neutral result if they are not.
- The host path remains tested and available.

### Main risks

- D3D11/Vulkan synchronization errors can cause corruption or GPU hangs.
- Multi-GPU laptops can decode and present on different adapters.
- Private mpv integration can create substantial maintenance debt.
- Eliminating host copies may improve efficiency more than raw model latency.

## 3. Optimize the remaining Deconvolution hotspot

### Goal

Investigate `Deconvolution:ConvTranspose_487`, measured at about 1.44 ms in the
instrumented baseline, without changing model precision or graph semantics.

A reasonable research target is a repeatable 0.5-1.0 ms reduction, but that is
not a promised result. The workstream should stop if shader changes merely move
time into repacking, synchronization, or another layer.

### Investigation sequence

1. Lock the exact input/output tensor shapes, packing, element type, kernel,
   stride, padding, bias, activation, and consumer layout.
2. Confirm the hotspot remains stable in the fused-Concat worker. Removing one
   bottleneck can change scheduling and the next-largest layer.
3. Separate:
   - convolution arithmetic;
   - input repacking;
   - output repacking;
   - bias/activation;
   - command and barrier overhead.
4. Inspect ncnn pipeline and shader selection for the exact RTX 5070 shape.
5. Prototype in a diagnostic-only custom layer:
   - direct write into the consumer's expected packing;
   - fused bias and activation where graph semantics allow it;
   - removal of redundant intermediate conversions;
   - workgroup and memory-access variants selected by measured evidence.
6. Retain an exact contract and stock-ncnn delegation path, following the
   fused-Concat safety pattern.

### Validation

- First compare the custom layer output to the stock layer in isolation.
- Then repeat the four deterministic end-to-end midpoint digests.
- If arithmetic order changes and byte equality is impossible, define and
  publish numerical tolerances before inspecting performance.
- Repeat per-layer timestamps, full-attempt timing, deadline fallback, and
  foreground playback separately.
- Test at least one non-target layout and prove stock delegation.

### Completion gate

- No model graph or precision change is hidden inside the optimization.
- Output is byte-identical, or a separately approved tolerance and real-video
  quality gate passes.
- The improvement survives two repeated runs and is visible in full-attempt
  p95, not only the isolated layer mean.
- The custom path never activates on an unknown shape or model.
- A regression or shader compilation failure falls back safely instead of
  terminating the player.

### Stop conditions

Stop and keep the stock layer if:

- the full-attempt p95 improvement is below measurement noise;
- a faster shader introduces unstable tails;
- the optimized output requires an unapproved precision change;
- the maintenance contract becomes broader than the four known Concat
  contracts plus this single locked layer.

## 4. Qualify FP16 arithmetic as an optional performance mode

### Goal

Decide whether the measured roughly 0.8 ms improvement is visually acceptable
on real content. FP16 arithmetic must remain separate from the byte-exact fused
Concat optimization.

### Current warning

The average synthetic error is small, but the maximum absolute difference of
249 is localized around an edge. Averages can hide temporal flicker, halos,
double edges, or failures on thin detail. The current evidence is insufficient
for a default or unlabeled mode.

### Locked corpus

Build a redistributable or internally reproducible corpus containing:

- slow camera motion;
- fast pans;
- small fast-moving objects;
- faces, hair, hands, and fine fabric;
- animation and line art;
- subtitles and other high-contrast overlays;
- film grain and compression noise;
- dark gradients;
- hard cuts, flashes, fades, and dissolves;
- repeated textures, fences, and occlusion boundaries.

Each clip needs fixed frame ranges and expected cut locations. Source hashes,
decode settings, color metadata, and baseline midpoint hashes must be stored
with the test description.

### Evaluation

For every midpoint, compare FP16 arithmetic with the compatible baseline:

- RGB MAE and RMSE;
- PSNR and, where available, SSIM;
- maximum absolute difference and its coordinates;
- temporal difference against adjacent source frames;
- worst-percentile crops rather than only whole-frame averages;
- manual side-by-side and blink comparison of the worst cases.

Metrics do not replace visual review. Acceptance thresholds must be chosen from
the locked corpus and documented before the final pass, not adjusted after
viewing a desirable performance result.

### Product behavior if accepted

- FP16 arithmetic remains an advanced performance choice initially.
- The ordinary quality path remains the default.
- The selected precision is fixed for a playback session; it must not switch
  frame by frame.
- The UI must describe a quality/performance tradeoff and must not imply that
  both paths are identical.
- Unsupported hardware silently uses the compatible path and reports that
  effective state only in advanced diagnostics.

### Completion gate

- The corpus, source hashes, decode contract, and comparison tool are
  reproducible.
- Worst-case visual differences have been reviewed, not only mean metrics.
- No unacceptable temporal flicker, edge duplication, or subtitle damage is
  present in the approved corpus.
- The roughly 0.8 ms benefit repeats in the product-like experimental worker.
- Seek, scene-change, deadline, and source-frame fallback behavior remains
  unchanged.
- The mode stays opt-in until broader GPU and user evidence exists.

### Rejection rule

If the worst localized differences remain visible or unstable, keep FP16 as a
diagnostic experiment and do not offset a quality regression with favorable
average metrics.

## 5. Add evidence-based modes for lower-performance GPUs

### Goal

Offer useful frame interpolation below the reference RTX 5070 without allowing
slow inference to damage A/V sync. This is a combination of capability
calibration, quality modes, and deterministic fallback policy.

The application must not infer support from a marketing GPU name alone.

### Candidate modes

#### Mode A: full-resolution quality

- Current 1920x1080 model boundary.
- Highest verified quality.
- Enabled only when fixed warmup and p95 gates pass.

#### Mode B: lower-resolution generated midpoint

- Downscale both source frames.
- Run the complete RIFE model at the lower resolution.
- Upscale only the generated midpoint for presentation.

This is the simplest performance prototype, but alternating sharp source frames
with a softer generated midpoint can create visible pulsation. It requires a
strict temporal quality review.

#### Mode C: lower-resolution flow and mask with full-resolution composition

- Obtain motion, mask, or intermediate features at a lower resolution.
- Upscale the required fields.
- Perform the final warp/fusion against full-resolution source frames.

This may preserve more source detail, but the current worker does not expose
that boundary. It requires model-graph work and must not be treated as a
configuration flag on the existing model.

#### Mode D: source playback with display synchronization

When no interpolation mode passes, use normal source-frame playback and mpv's
display synchronization where appropriate. Display resampling does not create
motion-estimated frames and must not be described as AI frame generation.

### Modes to avoid

- Do not generate an inconsistent subset of midpoints without a cadence design.
  Randomly alternating 30 and 60 fps output can look worse than stable 30 fps.
- Do not change resolution or precision every frame.
- Do not wait for the queue to grow before falling back.
- Do not expose an unsupported mode merely because startup succeeded once.

### Capability calibration

Use a short, bounded calibration for the exact model, resolution, precision,
driver, and adapter:

1. warm the persistent worker;
2. measure enough frames for a stable p95;
3. reject on any processing error or memory failure;
4. require margin below the playback deadline;
5. cache the result with the GPU identity, driver, model, and worker hashes;
6. invalidate the cache whenever one of those identities changes.

Runtime overload still overrides the cached result. Use hysteresis so a single
slow frame causes safe source fallback but does not repeatedly switch the whole
mode.

### Quality and performance validation

For each proposed internal resolution:

- repeat the workstream 4 corpus;
- compare generated-midpoint sharpness and temporal consistency;
- measure full-attempt p50/p95/p99 and maximum;
- run 20-30 minute playback, seek, pause, file-transition, and sleep/resume
  soaks;
- record CPU, GPU memory, thermals, power, displayed-frame drops, and A/V
  warnings;
- test at least one NVIDIA, AMD, and integrated-GPU class before making a broad
  support statement.

### UI policy

- Do not add a permanent control to the playback surface.
- Keep the normal action as a single RIFE on/off choice.
- Put quality/performance selection in the contextual or advanced menu only
  when more than one mode has passed.
- Show unsupported or automatically downgraded states clearly when the user
  opens that advanced choice.

### Completion gate

- Every exposed mode has a locked resolution, precision, model, and deadline.
- Calibration results are reproducible and invalidated correctly.
- Overload immediately falls back to the source frame without A/V drift.
- Mode changes occur only at a safe stream boundary or explicit user action.
- The quality corpus passes for each exposed mode.
- Unsupported devices retain reliable source playback.

## Cross-workstream evidence rules

Every performance artifact must identify:

- application commit;
- worker and libmpv hashes;
- model hashes and provenance;
- ncnn and Practical-RIFE revisions;
- GPU, driver, adapter identity, display refresh, and power mode;
- resolution, pixel format, color metadata, source cadence, and decode path;
- warmup, sample count, deadlines, and fallback policy;
- whether timestamps, custom layers, FP16, and GPU-native transport were built
  and active.

Development evidence belongs under ignored `.runtime` directories. Checked-in
documents should summarize exact evidence names and conclusions without
committing private media or large generated artifacts.

## Release boundary

Completing one or all performance workstreams does not automatically make RIFE
release-ready. Distribution still requires:

- reproducible model conversion or equivalence proof;
- third-party license and source inventory;
- longer foreground playback and teardown evidence;
- broader GPU and driver evidence;
- a support matrix for the exact shipped artifact;
- explicit confirmation that the normal fallback works without the
  experimental runtime.

The default remains source-frame playback until those independent gates close.
