# PlainVideo smooth-playback component notice

PlainVideo's optional 24-to-48 and experimental 30-to-60 smooth-playback paths
use motion-estimated RIFE frame interpolation. They are distinct from mpv
display resampling. Both modes are disabled by default. The original
source-frame path remains available and is selected automatically when the
media, GPU, timing, scene boundary, seek state, or runtime does not satisfy the
interpolation contract.

The release runtime accepts Windows x64 and Vulkan. Its native interpolation
boundary is 1920x1080 BGRA8 SDR; higher-resolution input uses the explicitly
tested compatibility bridge before returning to the original output path. The
24-to-48 mode accepts 23.0-to-25.5 fps source video. The 30-to-60 mode accepts
29.0-to-31.0 fps source video and remains visibly labelled experimental because
its conservative native 27 ms timing margin was not met on the qualification
machine. It generates one midpoint frame between each supported pair, falling
back to source frames under overload.

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
