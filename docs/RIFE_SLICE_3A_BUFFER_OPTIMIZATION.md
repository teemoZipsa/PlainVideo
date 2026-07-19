# RIFE Slice 3A host/Vulkan buffer optimization

Date: 2026-07-19

Status: duplicate host preparation removed; persistent staged Vulkan path
implemented and measured; **activation gate still failed**

Release state: developer-only, not connected to mpv, not included in portable
or Store artifacts

## Outcome

The duplicate host-frame preparation identified by the first Slice 3A run is
now removed. The benchmark DLL retains three same-executable modes so the
change can be measured at the same product-equivalent boundary:

| Mode | Boundary | Buffer behavior |
| --- | --- | --- |
| `legacy-duplicate-host` (A) | host BGRA8 to host BGRA8 | outer 9-plane float workspace plus a second checked-core host `Mat` allocation/copy |
| `persistent-host-direct-bgra` (B) | host BGRA8 to host BGRA8 | BGRA8 is written directly into persistent checked-core host `Mat` objects; output is checked and packed in one pass |
| `persistent-vulkan-staged` (C) | host BGRA8 to host BGRA8 | BGRA8 is written directly into mapped persistent Vulkan staging; allocator, command, upload/download staging, and fixed pre/postprocess device buffers are reused |

Mode B reduces the final exact-build attempt p95 from `122.507` to `58.494 ms`
for 24-to-48 fps and from `118.975` to `55.196 ms` for 30-to-60 fps. This is a
52.3 percent and 53.6 percent reduction respectively. It proves that the two
planar host preparation layers were a real integration cost.

Mode C safely reuses Vulkan-side resources, but it does not make the complete
host BGRA8 boundary real-time. At 24-to-48 fps its host-recorded ncnn round
trip is within the 33 ms sub-budget while the complete attempt is not. At
30-to-60 fps both the round trip and complete attempt exceed the 27 ms budget.
The feature therefore remains ineligible for mpv integration or product UI.

## Persistent staged Vulkan contract

Mode C prepares the following at context load time:

- one retained ncnn blob allocator and staging allocator;
- one retained `VkCompute` command context;
- two mapped fp32 upload staging frames and one mapped fp32 download staging
  frame;
- two fp32 device input frames;
- two padded fp16 input frames and one padded fp16 timestep frame;
- one fp32 postprocessed device output frame;
- one persistent CPU host output `Mat`.

Each call fills the mapped upload staging frames directly from caller BGRA8,
flushes and publishes their host-write state, records upload/preprocess/model/
postprocess/download work, waits for the fence, copies through ncnn's public
host-read barrier, and resets the command context. A new `Extractor` is created
for every frame pair because ncnn extractors cache produced blobs. The model's
graph `out0` cannot be bound to a caller-selected `VkMat` through the pinned
public API, so its backing allocation is pool-reused rather than guaranteed to
be one fixed output object.

Every pre-submit return or C++ exception is covered by a nonthrowing recording
guard that resets the retained command; cleanup-reset failure poisons the
context. Submission or normal reset failure also poisons it and prevents reuse.
Because ncnn reports queue-submit and fence-wait failures through the same
status, a submit failure is followed by a device-idle check. If idle cannot be
proved, the entire checked implementation graph, including network weights and
pre/postprocess pipelines, is quarantined for process lifetime instead of
destroying a possibly in-flight object. This deliberately favors a rare leak
over unsafe GPU teardown.

The wrapper preserves the previous source frame and its C ABI continues to
require the caller to choose the source frame itself after a nonzero process
return. On normal teardown, destruction releases `VkCompute`, then all `VkMat`
objects, then the staging and blob allocator leases before the process-wide
ncnn GPU instance is destroyed.

The fixed 1080p candidate allocation is approximately:

- 71.19 MiB mapped staging;
- 100.72 MiB device buffers;
- 23.73 MiB CPU host output;
- model, graph workspace, allocator block slack, and ordinary process memory
  are additional.

This footprint is acceptable only for the current RTX spike. It is not a
general low-memory-GPU product contract.

## Measurement method

The Quick verifier runs `A-B-C-C-B-A` independently for both cadences. Each
trial has 10 warm-up and 60 measured frame pairs, giving 120 pooled samples per
mode and cadence. The verifier independently recalculates percentiles,
deadline misses, counts, stage nesting, and every fallback/input/memory proof.
It uses the fixed 33 ms and 27 ms product budgets. Only a Full profile with all
Mode C gates passing can set `activationEligible=true`.

The reported GPU value is CPU steady-clock wall time around ncnn command
recording, real host-to-device upload, model execution, synchronized
device-to-host download, host copy, fence wait, and command reset. It is not a
Vulkan timestamp and not kernel-only inference time.

Before an earlier lower-VRAM-residency run, an otherwise valid ABCCBA attempt was measured while
an idle ComfyUI process retained about 6.7 GiB of local RTX memory. Its ncnn
round trips rose to roughly 64 ms. The ComfyUI queue was verified empty, then
only its model/memory cache was released through its `/free` endpoint; files,
history, server process, and completed icon assets were untouched. That earlier
run began with total RTX allocation around 2.8 GiB instead of more than 8 GiB.
This confirms that GPU residency must be recorded by any future qualification
tool and that an unconditional feature default would be unsafe. A later exact-
build run with roughly 6.8 GiB still resident produced 30.792/32.558 ms rather
than 64 ms, so memory usage alone is not a sufficient causal explanation;
concurrent work, residency, clocks, and paging must all be captured. These are
operational diagnostics and are not embedded in the current `summary.json`
schema. That omission must be closed before qualification.

## Final exact-build Quick result

Machine: Windows 11 Pro build 26200, Ryzen 7 7800X3D, NVIDIA GeForce RTX 5070,
driver 610.52.

| Cadence | A attempt p95 | B attempt p95 | C attempt p95 | C return p95 | C ncnn round-trip p95 | Limit | C result |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| 24 to 48 fps | 122.507 ms | 58.494 ms | 50.506 ms | 50.804 ms | 30.792 ms | 33 ms | Fail |
| 30 to 60 fps | 118.975 ms | 55.196 ms | 54.834 ms | 55.236 ms | 32.558 ms | 27 ms | Fail |

The verifier accepted provenance, and all 12 trials passed the timing-contract,
explicit signal fallback,
deadline fallback, invalid-input, unchanged-input, output-guard, and source-
frame byte-match checks. There were no processing-error misses. Every one of
the 720 timed frame pairs exceeded the complete product deadline and therefore
returned the source frame through the overload fallback path.

Generated pixels are verified separately rather than inferred from those
fallback frames. Before each timed handle, a scoped `deadline=0` handle renders
four phase pairs: `0/16`, `16/32`, `32/48`, and `0/16` again. Across all A/B/C
modes, cadences, and trials, all 48 calls reported generated status, changing
inputs produced different outputs, the repeated pair was deterministic, guards
and inputs stayed intact, and all modes produced the identical FNV-1a digest
sequence:

`e003cba18b1290fc`, `943d9105b8f45163`, `4a83a94a6312fdfc`,
`e003cba18b1290fc`.

Quick evidence is complete but `performanceGatePassed=false` and
`activationEligible=false`.

Evidence:

- summary: `.runtime/rife-spike/evidence/20260719-141423-316/summary.json`;
- SHA-256: `27c1519103b6d207d41d762e0d3fc8a715a67e9c94fb6c7a9644ed693c407672`;
- build-provenance SHA-256:
  `9cc1b4cc5eafe47fa55645d47dadc2caf3bd64f66c38716e811dc2c032cc5152`;
- profile: Quick, 12 trials, 720 timed attempts and 48 generated-output proof
  calls.

## GPU-native boundary decision

Mode C is the nearest safe boundary available without changing ncnn, but it is
still staged host input/output. The pinned ncnn runtime can wrap buffers that
already belong to its Vulkan device; it does not provide the Windows external-
memory import and synchronization path required to accept a libmpv/D3D11 frame
as a compatible `VkMat`. A real zero-copy path would additionally have to prove
Vulkan device identity, queue ownership, image/buffer layout, semaphore/fence
handoff, D3D11 sharing, and color-format compatibility.

Consequently:

1. do not call the current path GPU-native or zero-copy;
2. do not connect it to mpv or expose `Frame doubler 2x` in the UI;
3. retain Mode C as a development measurement boundary;
4. if this work resumes, prototype an explicit Windows decoder-surface/Vulkan
   interop layer or evaluate a runtime with a documented Windows GPU tensor
   import contract;
5. require the complete host/product boundary to pass Full, not merely the
   24-fps ncnn round-trip sub-boundary.
