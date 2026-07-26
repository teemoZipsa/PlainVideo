# Microsoft Store Submission 3 — PlainVideo 0.2.2

## Package

- Product ID: `9PDKQ88FKG1L`
- Identity: `SeonkyuIM.PlainVideo`
- Version: `0.2.2.0`
- Architecture: `x64`
- Device family: `Windows.Desktop`
- Minimum version: `10.0.17763.0`
- Distribution: free, no ads, no account, no telemetry

The exact package hash, size, payload inventory, clean source commit, WACK
report, and Defender result must be recorded here after clean-commit packaging
and before Partner Center upload.

## Listing fields

Retain the existing `en-US` and `ko-KR` listings and rights-cleared media.
Replace only the localized release notes with the 0.2.2 text in
`STORE_LISTING_DRAFT.md`.

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
