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
