# Third-party notices

## mpv developer runtime

The playback-surface proof downloads a pinned Windows mpv build produced by [shinchiro/mpv-winbuild-cmake](https://github.com/shinchiro/mpv-winbuild-cmake). The archive is not committed to this repository.

- Release: `20260610`
- Asset: `mpv-x86_64-20260610-git-304426c.7z`
- mpv revision in the asset name: `304426c`
- mpv archive SHA-256: `facac536baa73c7b925771af5e39a3c9cb16b8d75b59a6e9800de89799dffca7`
- extracted `mpv.exe` SHA-256: `b0bb2dc1928e6d86cc26d950815c80c977440081e814c6a46e93f6e9e99c276d`
- Slice 0B development asset: `mpv-dev-x86_64-20260610-git-304426c.7z`
- libmpv archive SHA-256: `8cbb25ea784f01afbb3f904217cab1317430a8bcfd5680fd827a866367f71cc9`
- Embedded development library: `libmpv-2.dll`
- extracted `libmpv-2.dll` SHA-256: `5c876d79e070529128331591b48f87846fb30557f19c11280df9c6ee9b6dbafa`
- Manifest: [`third_party/mpv-runtime.json`](third_party/mpv-runtime.json)

mpv is GPL-2.0-or-later by default and can be built under LGPL-2.1-or-later only when its GPL features are disabled. The pinned third-party binary is conservatively treated as GPL-2.0-or-later. It also contains or links open-source multimedia components including FFmpeg, libplacebo, and libass under their respective terms.

This runtime is a **developer dependency only**. It must not be copied into a PlainVideo release until the exact build configuration, complete component inventory, corresponding source offer, and redistribution notices have been reviewed and checked in.

## PlainVideo 0.1.0 shared libmpv release candidate

[`third_party/lgpl-libmpv-profile.json`](third_party/lgpl-libmpv-profile.json)
pins a separate Windows x64 source-build candidate for mpv, FFmpeg,
libplacebo, and libass. It asks FFmpeg to disable GPL, nonfree, and version-3
options and builds shared DLLs, while mpv uses `gpl=false` and exposes only
`libmpv`. The candidate build, package lock, runtime hashes, copied license
texts, and dependency closure evidence are generated under the ignored
`.runtime/lgpl-libmpv` directory.

The 24-DLL closure has been bound to the exact direct sources or MSYS2 binary
packages. The 0.1.0 corresponding-source bundle additionally retains every
official MSYS2 source-only package, exact recipe commit and patch, all direct
source/submodule archives, build arguments, and a SHA-256 inventory. LuaJIT's
upstream MIT `COPYRIGHT` is included separately because its binary MSYS2
package omitted a `share/licenses` payload. See `SOURCE_OFFER.md` for the
publication location and three-year fallback offer.

The staged runtime components and selected terms are:

- mpv — LGPL-2.1-or-later candidate with `gpl=false`;
- FFmpeg — LGPL-2.1-or-later candidate built without GPL, nonfree, or
  version-3 options;
- libplacebo — LGPL-2.1-or-later;
- libass — ISC;
- Brotli and LuaJIT — MIT;
- bzip2, libpng, PCRE2, and zlib — their permissive project licenses;
- FreeType — FreeType License (FTL) option;
- FriBidi, GLib, Graphite2, and the distributed libiconv/libintl runtime
  portions — LGPL-2.1-or-later;
- HarfBuzz — MIT;
- libc++ — Apache-2.0 with LLVM exception.

Every copied license text remains authoritative over this summary. The
engineering source and notice set is complete. The publisher accepted the
remaining multimedia-patent and worldwide distribution risk on 2026-07-21;
that decision is not a legal opinion that no patents apply. See
`docs/RUNTIME_DISTRIBUTION_REVIEW.md`.

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
