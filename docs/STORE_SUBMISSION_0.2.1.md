# Microsoft Store Submission 3 — PlainVideo 0.2.1

## Package

- Product ID: `9PDKQ88FKG1L`
- Identity: `SeonkyuIM.PlainVideo`
- Version: `0.2.1.0`
- Architecture: `x64`
- Device family: `Windows.Desktop`
- Minimum version: `10.0.17763.0`
- Distribution: free, no ads, no account, no telemetry

## Listing fields

Use the existing `en-US` and `ko-KR` listings and retained rights-cleared media.
Update only the localized release notes and any description/feature text needed
to document subtitle-file drop attachment and 0.1-second subtitle timing.

## Properties

- Primary category: `Photo + video`
- Privacy policy URL: `https://github.com/teemoZipsa/PlainVideo/blob/v0.2.1/PRIVACY.md`
- Website: `https://github.com/teemoZipsa/PlainVideo`
- Support URL: `https://github.com/teemoZipsa/PlainVideo/blob/v0.2.1/SUPPORT.md`
- Purchases outside Store: no
- Accessibility declaration: leave unchecked until runtime assistive-technology testing exists
- Generative AI declaration: no; experimental frame-interpolation runtimes and models are not shipped
- Mixed Reality declarations: none
- Optional phone/address and Xbox-only voice-title fields: leave blank
- Hardware requirements: leave unspecified; automatic hardware decode retains a verified software fallback

## Certification notes

PlainVideo 0.2.1 is a local Windows video player. No account, credentials,
network service, advertising, or telemetry is required. Open a local MP4 or MKV
file with `Ctrl+O` or drag it onto the window. To test this update, drop one SRT
file onto an already playing video and confirm playback is not replaced; adjust
subtitle timing with `Ctrl+[` and `Ctrl+]`, then reset it with `Ctrl+\`. The
speaker control and `M` toggle mute. Experimental RIFE/FRUC interpolation is not
included or enabled.

## Submission options

- Retain manual publication after certification.
- Do not describe the package as Store-live until certification, publication,
  and independent Store propagation are each verified.
