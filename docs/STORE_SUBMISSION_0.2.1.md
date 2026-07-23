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

## Local release evidence

- Clean source commit: `1be0b6de297a41ddf740b8eb87bd2886ca38ad29`
- Integrated validation: 14/14 steps passed; format matrix 10/10; quick playback soak 8/8
- Store MSIX SHA-256: `270f858610a8246a026154bd5053a0b9da0439fa72d6ede56cf6b5d1099172b0`
- Store MSIX size: `18,435,113` bytes; payload: 66 files
- Developer MSIX signature: valid
- Microsoft Defender: no threats in Store MSIX, developer MSIX, or portable ZIP
- WACK: overall `PASS`; optional blocked-executable reference warnings retained for review
- Experimental RIFE/FRUC runtime/model assets in Store MSIX: `0`
- Portable ZIP SHA-256: `fa53e4b5adb1ce52408856ab42cc6903a7ca1899d6fc7d7c64511afa7491031e`
- GitHub prerelease: `https://github.com/teemoZipsa/PlainVideo/releases/tag/v0.2.1`

## Submission options

- Retain manual publication after certification.
- Do not describe the package as Store-live until certification, publication,
  and independent Store propagation are each verified.
