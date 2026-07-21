# PlainVideo 0.1.0 runtime distribution review

Date: 2026-07-21

Status: engineering and source-compliance material complete; the publisher
accepted the residual multimedia-patent and worldwide territorial distribution
risk on 2026-07-21. This is a publisher decision, not a legal opinion or a
finding that no patents apply.

## Binary and source relationship

The candidate is a Windows x64, side-by-side shared-DLL build. PlainVideo uses
`libmpv-2.dll`; mpv uses separately named FFmpeg and other dependency DLLs.
The application does not rename or statically absorb these libraries. The
runtime closure contains 24 DLLs: 9 built directly from pinned mpv, FFmpeg,
libplacebo, and libass sources, plus 15 DLLs owned by 14 exact MSYS2 binary
packages.

The local corresponding-source bundle contains:

- pinned archives for mpv `v0.41.0`, FFmpeg `n8.1.2`, libplacebo `v7.360.0`,
  libass `0.17.4`, and every initialized libplacebo submodule;
- the official MSYS2 source-only tarball for every one of the 14 transitive
  packages;
- each exact MINGW-packages recipe commit, with the `PKGBUILD` hash matched to
  both the binary package `.BUILDINFO` and source-only tarball;
- all recipe patches, including the historical zlib pull-request patch whose
  current mutable URL no longer has the original bytes;
- the direct build arguments, runtime hashes, package hashes, and inventory.

Local bundle evidence:

- file: `PlainVideo-0.1.0-corresponding-source.tar.zst`
- size: `268325686` bytes
- SHA-256: `3e3089757120c42aa632d1683481df522a9989ab016c242f1509a38d3c8ffad8`
- inventory SHA-256: `025c6c0bc2d831d1543954d1b570380b129fcbc950fb9aaa39545a7f04272805`
- packages: 14 of 14, with zero embedded `PKGBUILD` hash mismatches
- direct source archives: 10

The intended publication location and three-year fallback offer are recorded
in `SOURCE_OFFER.md`. That URL must be live and independently downloadable
before a Store package is uploaded.

## Configuration disposition

- FFmpeg: LGPL-2.1-or-later profile; shared libraries; `--disable-gpl`,
  `--disable-nonfree`, and `--disable-version3`; no external GPL codec library.
- mpv: `gpl=false`, `libmpv=true`, shared library, no CLI player.
- libplacebo: LGPL-2.1-or-later shared library.
- libass: ISC.
- FreeType: the FTL option is selected, rather than GPLv2.
- gettext: only `libintl-8.dll` and its LGPL `intl/COPYING.LIB` terms are
  distributed; GPL command-line programs and documentation are not staged.
- libiconv: the LGPL runtime DLL is staged; GPL documentation is not staged.
- LuaJIT: MIT; its exact upstream `COPYRIGHT` from commit
  `9d145d2ca3db58493859c495489a0f08f627834f` is included because the MSYS2
  binary package omitted `share/licenses`.
- The remaining staged packages use MIT, BSD-style, Apache-2.0 with LLVM
  exception, libpng, bzip2, PCRE2, or zlib terms as recorded in the package
  metadata and copied license set.

## Publisher decision

This engineering review does not decide multimedia patent licensing or give
legal advice. The exact FFmpeg build includes decoders for standardized media
formats that may be patent-encumbered in some jurisdictions. On 2026-07-21 the
publisher explicitly chose to proceed with free worldwide distribution after
being informed of that residual risk. Microsoft Store certification does not
replace that decision. Runtime and Store upload eligibility still remain
fail-closed until the exact corresponding-source URL is public and the final
candidate gates pass.
