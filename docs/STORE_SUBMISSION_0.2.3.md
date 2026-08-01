# Microsoft Store Submission 4 — PlainVideo 0.2.3

## Package

- Product ID: `9PDKQ88FKG1L`
- Submission ID: `1152921505701552228`
- Identity: `SeonkyuIM.PlainVideo`
- Version: `0.2.3.0`
- Architecture: `x64`
- Device family: `Windows.Desktop`
- Minimum version: `10.0.17763.0`
- Distribution: free, no ads, no account, no telemetry

## Locked source and artifacts

- Release source commit and `v0.2.3` tag target:
  `4417b459475aeb0d99e32374077731d9ba6b99b1`
- Store MSIX: `.runtime/msix/PlainVideo_0.2.3.0_x64-store.msix`
- Store MSIX SHA-256:
  `d4e431a226aba4b02a272283128f1cbc8ec12f77b54abe9c6669fa02924c2685`
- Store MSIX size: `30,468,974` bytes; staged payload: 75 files
- Developer MSIX SHA-256:
  `0fc935cff980ec3c00d3e3d310de241a22364a5c4e18bbc5fb50a7ddfdad7c60`
- Portable ZIP SHA-256:
  `a1433aecfb8fc2ae77e2d7ded869c9667d46a1580a9eb4fc2befce56358e1adc`
- Corresponding-source SHA-256:
  `67b047b4f947d76d4c6920ae0cf46c3a81248348931fb915224573814fda8aa4`
- GitHub prerelease: `https://github.com/teemoZipsa/PlainVideo/releases/tag/v0.2.3`

The Store MSIX includes the release-approved RIFE runtime, selected model,
feature manifest, third-party notice, and Practical-RIFE/ncnn licenses. Smooth
24→48 playback remains user-enabled and retains source-frame fallback.

## Validation

- Rust: 54 passed, 0 failed, 1 explicit local-media diagnostic ignored
- Clippy: all targets with warnings denied passed
- Release build: passed
- Native RIFE 24→48 persistent Vulkan GPU round-trip p95: `26.725 ms`
  against the fixed `33.0 ms` gate
- Focused playback qualification: normal generation, seek restart, scene-cut
  fallback, and unsupported 30 fps source fallback passed
- Developer MSIX signature: SignTool policy validation passed
- Microsoft Defender: no threats in Store MSIX, developer MSIX, or portable ZIP
- WACK: `OVERALL_RESULT="PASS"`, version `10.0.26100.7705`
- WACK report SHA-256:
  `9cea47fb5cdd96589ac628d40301e59e9d4569fe842935817320342bd064eeca`

## Partner Center result

- Submission: `4`
- Submitted: 2026-08-01
- Package validation: `PlainVideo_0.2.3.0_x64-store.msix` — `Validated`
- Current state: `Update in certification`
- Certification pipeline: step 2 of 4, `Pre-processing`
- Publication: manual hold retained; Partner Center says publishing begins only
  after `Publish now` is selected
- Store-live boundary: Submission 3 / `0.2.2.0` remains the independently
  verified Microsoft Store version

## Listing fields

The existing `en-US` and `ko-KR` listings and rights-cleared media were
retained. Both localized release-note fields were updated with the on-demand
playback panel, seeking/speed/A–B/volume/equalizer controls, keyboard operation,
and optional 24→48 behavior with its default-off and source-fallback limits.

## Remaining boundary

Submission, certification, publication, and Store propagation are separate
states. Do not describe 0.2.3 as certified, published, or Store-live until each
state is directly verified. The selected Windows 10 minimum-image proof remains
open.
