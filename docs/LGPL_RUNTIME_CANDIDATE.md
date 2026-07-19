# Shared libmpv runtime candidate

Status: **candidate-not-release-approved**

This is a build-and-measurement path for a Windows x64 shared `libmpv` runtime.
It does not make the runtime redistributable, Store-ready, or legally approved.
The existing `third_party/mpv-runtime.json` remains a separately verified,
developer-only GPL-conservative runtime.

## What is pinned

[`third_party/lgpl-libmpv-profile.json`](../third_party/lgpl-libmpv-profile.json)
records the source tags and commits for mpv, FFmpeg, libplacebo, and libass;
the no-GPL/no-nonfree FFmpeg configure arguments; the `gpl=false`/shared-libmpv
Meson profile; and the MSYS2 base archive hash. The candidate deliberately uses
dynamic DLL staging so the runtime verifier can prove the actual import closure.

The MSYS2 package repository is rolling. Running
`bootstrap-lgpl-mpv-dependencies.ps1` records an observed package lock under
`.runtime/lgpl-libmpv/toolchain`; it is not created implicitly by every build.
`capture-lgpl-runtime-closure.ps1 -MaterializeEvidence` then binds the staged
DLL bytes to the exact cached package archives/signatures, package license
payloads, direct source checkouts, and initialized direct-source submodules.
Those ignored local artifacts are evidence only, not a corresponding-source
delivery mechanism. A release cannot claim reproducibility until the package
recipes, upstream source, patches, source-delivery method, and license review
are retained and approved. Each candidate build also uses new build-ID-suffixed
prefix and build-tree directories and refuses to reuse either, so stale
locally-built `.pc` files, DLLs, or objects cannot become implicit inputs to the
next candidate.

## Local candidate build

Run these from a trusted checkout on Windows:

```powershell
.\scripts\bootstrap-lgpl-mpv-toolchain.ps1
.\scripts\bootstrap-lgpl-mpv-dependencies.ps1
.\scripts\build-lgpl-libmpv.ps1
.\scripts\verify-mpv-runtime.ps1 `
  -ManifestPath .runtime\lgpl-libmpv\runtime-manifest.json `
  -RuntimeRoot .runtime\lgpl-libmpv\runtime
.\scripts\capture-lgpl-runtime-closure.ps1 -MaterializeEvidence
.\scripts\build-portable.ps1 `
  -RuntimeManifestPath .runtime\lgpl-libmpv\runtime-manifest.json `
  -OutputPath .runtime\portable\PlainVideo-lgpl-candidate
```

The toolchain cache is intentionally outside the repository at
`C:\pv-tools\msys64`, and the short build root defaults to `C:\pv-build`.
Neither becomes part of a PlainVideo artifact. Generated DLLs, source revision
evidence, build configuration, package lock, notices copied from the four
direct sources, and hashes stay under the ignored `.runtime\lgpl-libmpv`
directory until the candidate is qualified.

`verify-mpv-runtime.ps1` checks the declared DLL hashes, PE architecture,
required libmpv exports, and recursive non-system ordinary- and delay-import
closure on the executing host. Dynamic `LoadLibrary` paths and minimum target
Windows compatibility are deliberately outside that structural check. It always
reports `releaseEligible=false`; structural success is not a legal conclusion.

`capture-lgpl-runtime-closure.ps1` exits nonzero for an unowned staged DLL,
runtime/package byte mismatch, dirty or incorrectly pinned direct checkout, or
missing requested materialization. It still preserves `releaseEligible=false`:
the capture does not classify every transitive license or provide a source
offer. Archive the generated closure JSON and its material directory together
with any candidate that is reviewed; both are ignored local outputs by design.

## Local host proof

The current local build path has produced a 24-DLL candidate runtime and a
candidate portable proof under the ignored `.runtime` directory. Its structural
verifier passed with no unresolved non-system imports. On the build host, the
candidate portable also passed the generated 10-row format matrix (including
MP4, MKV, external SRT, hardware-decoded rows, and software-decoded rows),
the invalid-media recovery check, and the Quick hardware/software playback
soak. The profile explicitly enables the Windows WGL context required by the
existing `gpu-api=opengl` render configuration.

The host proof also starts `plainvideo.exe` without `PLAINVIDEO_ROOT` or
`PLAINVIDEO_LIBMPV_PATH`, so the executable must find the staged sidecar
runtime itself. Unattended playback harnesses set
`PLAINVIDEO_DIAGNOSTIC_IGNORE_INPUT=1`; the application honors that switch
only when a diagnostic log is configured, preventing foreground keyboard or
pointer input from changing or closing a timed verification run. It is not a
normal playback setting.

Candidate portable staging writes a portable-specific `runtime-manifest.json`
with `runtimeRoot: "."`, retains the source manifest and pre-stage evidence as
`source-runtime-manifest.json` and `source-runtime-verification.json`, then
verifies the copied portable root itself. Its provenance binds the portable
manifest and verification hashes separately from the source-manifest evidence.
The x64 MSVC target uses `+crt-static` in `.cargo/config.toml`; candidate
staging additionally runs `audit-windows-runtime-compatibility.ps1` and embeds
its `windows-runtime-compatibility.json`. That audit rejects Visual C++ runtime
DLL imports from `plainvideo.exe`, records **Windows 10 version 1703 x64** as a
technical API floor because of `SetProcessDpiAwarenessContext`, and explicitly
marks the D3D11/D3D9/DXVA2/DXGI and GPU-driver paths as runtime dynamic-load
dependencies rather than static closure.

The current local closure capture found 24 staged DLLs: 9 from the four direct
source builds and 15 from MSYS2 packages. All staged bytes matched their source
or cached package owner; the four direct checkouts were pinned and clean, and
their source/submodule archives plus package archives/signatures were
materialized. LuaJIT's cached binary package contains no `share/licenses`
payload, so its source/license inclusion remains an explicit legal gate.

A clean Windows 11 Enterprise 10.0.26100 x64 Sandbox run also passed the
default sidecar-load module snapshot, 24-DLL structural closure, all 10 format
rows, recovery verification, and the Quick hardware/software soak. Its module
snapshot observed the reviewed `d3d11.dll`, `d3d9.dll`, `dxva2.dll`, and
`dxgi.dll` system dependencies. The generated manifests, hashes, and test logs
remain ignored build outputs; the Sandbox result is not a Windows 10 1703
proof, an approved component inventory, or a redistribution authorization.

## Remaining release gates

- Classify and retain corresponding source and license material for every
  transitive DLL, including LuaJIT, the MSYS2-provided
  FreeType/HarfBuzz/FriBidi dependency graph, and libplacebo submodules.
- Decide how exact source archives, package recipes, and patches will be made
  available to recipients; local archive capture alone is not a source offer.
- Review codec patent exposure, LGPL replacement/relinking obligations,
  notices, source delivery, and Store terms.
- Repeat the declared-DLL structural and playback checks against the exact
  candidate manifest on the selected Windows 10 minimum image. The clean
  Windows 11 Sandbox result captures the current hardware and software routes,
  but it does not validate the Windows 10 1703 technical floor or every dynamic
  loader branch.
- Make a separate explicit legal disposition before changing any artifact from
  `candidate-not-release-approved` to a release profile.
