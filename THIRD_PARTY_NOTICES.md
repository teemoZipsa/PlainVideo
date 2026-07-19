# Third-party notices

## mpv developer runtime

The playback-surface proof downloads a pinned Windows mpv build produced by [shinchiro/mpv-winbuild-cmake](https://github.com/shinchiro/mpv-winbuild-cmake). The archive is not committed to this repository.

- Release: `20260610`
- Asset: `mpv-x86_64-20260610-git-304426c.7z`
- mpv revision in the asset name: `304426c`
- SHA-256: `facac536baa73c7b925771af5e39a3c9cb16b8d75b59a6e9800de89799dffca7`
- Slice 0B development asset: `mpv-dev-x86_64-20260610-git-304426c.7z`
- Development asset SHA-256: `8cbb25ea784f01afbb3f904217cab1317430a8bcfd5680fd827a866367f71cc9`
- Embedded development library: `libmpv-2.dll`
- Manifest: [`third_party/mpv-runtime.json`](third_party/mpv-runtime.json)

mpv is GPL-2.0-or-later by default and can be built under LGPL-2.1-or-later only when its GPL features are disabled. The pinned third-party binary is conservatively treated as GPL-2.0-or-later. It also contains or links open-source multimedia components including FFmpeg, libplacebo, and libass under their respective terms.

This runtime is a **developer dependency only**. It must not be copied into a PlainVideo release until the exact build configuration, complete component inventory, corresponding source offer, and redistribution notices have been reviewed and checked in.

## RIFE performance-spike dependencies

The isolated Slice 3A benchmark fetches the MIT-licensed
[VapourSynth-RIFE-ncnn-Vulkan](https://github.com/styler00dollar/VapourSynth-RIFE-ncnn-Vulkan)
reference source at commit `c3ec6aabc07c8fa37a4f58d7fed9e2ad1fc1b13f`.
It statically links the reference plugin's pinned
[ncnn](https://github.com/Tencent/ncnn) submodule at commit
`305837fd4a722ebc47c5d72e72d8ec9ae970e932`. ncnn is BSD-3-Clause and its
`LICENSE.txt` also inventories bundled third-party components. The build uses
ncnn's recursively pinned glslang source at commit
`a9ac7d5f307e5db5b8c4fbf904bdba8fca6283bc`.

The reference repository's converted RIFE 4.25-lite `param/bin` model is used
only as a prototype input. Its binary SHA-256 is
`350a15e464bea5ad378e06c0fb43996e90a0d35653d5a6ef6bc980d832538fb7`.
The repository does not provide a reproducible conversion recipe proving that
this ncnn model is equivalent to the official Practical-RIFE PyTorch weight.

These sources, licenses, model files, DLL, CLI, and measurements stay in the
ignored `.runtime/rife-spike` tree. They are **not release dependencies** and
must not be copied into PlainVideo's portable or Store artifacts. Exact pins,
hashes, and the release blocker are recorded in
[`third_party/rife-spike.json`](third_party/rife-spike.json).
