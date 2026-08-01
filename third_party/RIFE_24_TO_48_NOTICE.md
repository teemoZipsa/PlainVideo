# PlainVideo 24-to-48 playback component notice

PlainVideo's optional 24-to-48 smooth-playback path uses motion-estimated RIFE
frame interpolation. It is distinct from mpv display resampling. The original
source-frame path remains available and is selected automatically when the
media, GPU, timing, scene boundary, seek state, or runtime does not satisfy the
interpolation contract.

The next-update candidate is limited to Windows x64, Vulkan, 1920x1080 BGRA8
SDR input, and 23.0-to-25.5 fps source video. It generates one midpoint frame
between each supported pair. It does not enable the separate 30-to-60
development probe.

## Redistributed components

- `plainvideo_rife.dll`: PlainVideo's native wrapper plus code from
  VapourSynth-RIFE-ncnn-Vulkan commit
  `c3ec6aabc07c8fa37a4f58d7fed9e2ad1fc1b13f` (MIT).
- ncnn commit `305837fd4a722ebc47c5d72e72d8ec9ae970e932`, statically linked into the
  wrapper (BSD-3-Clause and the bundled notices in `ncnn-LICENSE.txt`).
- glslang commit `a9ac7d5f307e5db5b8c4fbf904bdba8fca6283bc`, brought in through the pinned
  ncnn source tree (see `glslang-LICENSE.txt`).
- The converted `rife-v4.25-lite_ensembleFalse` ncnn model copied from the
  pinned VapourSynth-RIFE-ncnn-Vulkan commit. Its source artifact and hashes are
  recorded in `third_party/rife-spike.json` and the staged RIFE manifest.
- Practical-RIFE model material is published under the project's MIT license;
  its license is included as `Practical-RIFE-LICENSE.txt`.

PlainVideo does not claim that the pinned converted ncnn artifact is
byte-equivalent to a fresh conversion of the official PyTorch weight. Product
acceptance is based on the exact pinned artifact, hashes, deterministic output
checks, real-playback checks, and source-frame fallback behavior.

Every included license text is authoritative over this summary.
