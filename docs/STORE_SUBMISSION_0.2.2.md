# Microsoft Store Submission 3 — PlainVideo 0.2.2

## Package

- Product ID: `9PDKQ88FKG1L`
- Identity: `SeonkyuIM.PlainVideo`
- Version: `0.2.2.0`
- Architecture: `x64`
- Device family: `Windows.Desktop`
- Minimum version: `10.0.17763.0`
- Distribution: free, no ads, no account, no telemetry

## Local release evidence

- Clean source commit: `36ce3e8469829f5724eddbd4fff78aba5db4e93c`
- Integrated validation: 14/14 steps passed; format matrix 10/10; quick playback soak 8/8
- Store MSIX: `.runtime/msix/PlainVideo_0.2.2.0_x64-store.msix`
- Store MSIX SHA-256: `2c7ee97b715684c16ac7496fb530dd9d5bcc7e404f9664eab77d6dafd7a6f96d`
- Store MSIX size: `18,435,833` bytes; staged payload: 66 files
- Developer MSIX SHA-256: `eb630ec4688530d13eaab1105a155e32dbd24823b9362e7143550a268df919d7`
- Developer MSIX signature: valid
- Microsoft Defender: no threats in Store MSIX, developer MSIX, or portable ZIP
- WACK: overall `PASS`; report SHA-256 `9719ec28b6268555f1c52ed31f79e12a3426c5ef34c2c5379abec3adc7c668c0`
- WACK optional blocked-executable reference check: retained for review
- Experimental RIFE/FRUC runtime/model assets in Store MSIX: `0`
- Portable ZIP SHA-256: `dbedaf556eb5f1e00ddc92b43377df76aa6b9b21bc2ea35c2a3223edfaef4c49`
- GitHub prerelease: `https://github.com/teemoZipsa/PlainVideo/releases/tag/v0.2.2`

## Partner Center result

- Submission: `3`
- Submission ID: `1152921505701493629`
- Package validation: `PlainVideo_0.2.2.0_x64-store.msix` — `Validated`
- Submitted: 2026-07-27
- Current state: `Update in certification`
- Certification pipeline: step 2 of 4, `Pre-processing`
- Publication: manual hold retained; Partner Center states that publishing starts
  only after `Publish now` is selected
- Store-live boundary: Submission 2 / `0.2.0.0` remains the independently
  verified Microsoft Store version

## Listing fields

The existing `en-US` and `ko-KR` listings and rights-cleared media were
retained. Only the localized 0.2.2 release notes from
`STORE_LISTING_DRAFT.md` were replaced and saved before submission.

## Properties

- Primary category: `Photo + video`
- Privacy policy URL: `https://github.com/teemoZipsa/PlainVideo/blob/v0.2.2/PRIVACY.md`
- Website: `https://github.com/teemoZipsa/PlainVideo`
- Support URL: `https://github.com/teemoZipsa/PlainVideo/blob/v0.2.2/SUPPORT.md`
- Purchases outside Store: no
- Accessibility declaration: leave unchecked until runtime assistive-technology testing exists
- Generative AI declaration: no; experimental frame-interpolation runtimes and models are not shipped
- Mixed Reality declarations: none
- Optional phone/address and Xbox-only voice-title fields: leave blank
- Hardware requirements: leave unspecified; automatic hardware decode retains a verified software fallback

## Certification notes

PlainVideo 0.2.2 is a local Windows video player. No account, credentials,
network service, advertising, or telemetry is required. Open a local MP4 or MKV
file with `Ctrl+O` or drag it onto the window. To test this update, press `M`
and confirm muted state is explicit. Use `Alt+[` and `Alt+]` to move audio
timing earlier and later in 0.1-second steps, then use `Alt+\` to restore the
default timing. The same commands are available in the Audio context submenu.
Experimental RIFE/FRUC interpolation is not included or enabled.

## Submission options

- Retain manual publication after certification.
- Do not describe the package as Store-live until certification, publication,
  and independent Store propagation are each verified.
