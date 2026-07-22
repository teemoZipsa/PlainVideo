# Microsoft Store Submission 2 — PlainVideo 0.2.0

## Package

- Product ID: `9PDKQ88FKG1L`
- Identity: `SeonkyuIM.PlainVideo`
- Version: `0.2.0.0`
- Architecture: `x64`
- Device family: `Windows.Desktop`
- Minimum version: `10.0.17763.0`
- Distribution: free, no ads, no account, no telemetry

## Listing fields

Use the localized descriptions, features, release notes, keywords, and captions
from `STORE_LISTING_DRAFT.md`. Keep the existing product name and inherited
rights-cleared artwork.

Retain the four rights-cleared screenshots per locale in this order and add the
localized captions from `STORE_LISTING_DRAFT.md`:

1. Drop zone
2. Content-first playback
3. Transient controls and seek preview
4. Subtitle/context menu

## Properties

- Primary category: `Photo + video`
- Privacy policy URL: `https://github.com/teemoZipsa/PlainVideo/blob/v0.2.0/PRIVACY.md`
- Website: `https://github.com/teemoZipsa/PlainVideo`
- Support URL: `https://github.com/teemoZipsa/PlainVideo/blob/v0.2.0/SUPPORT.md`
- Purchases outside Store: no
- Accessibility declaration: leave unchecked until runtime assistive-technology testing exists
- Generative AI declaration: no; experimental frame interpolation is not shipped
- Mixed Reality declarations: none
- Optional phone/address and Xbox-only voice-title fields: leave blank
- Hardware requirements: leave unspecified; the release retains both automatic hardware decode and an explicitly verified software path

## Certification notes

PlainVideo 0.2.0 is a local Windows video player. No account, credentials,
network service, advertising, or telemetry is required. To test, open a local
MP4 or MKV file with Ctrl+O, drag a file onto the window, or use the registered
file association. A matching external SRT file in the same folder is discovered
automatically. The CC button toggles subtitles; detailed subtitle and audio
track selection is available from the right-click menu.

Version 0.2.0 adds seek-bar thumbnail previews, automatic resume, screenshots
saved to the Windows Pictures library, richer Tab media information, remembered
volume/mute state, and input-conflict fixes. Double-click the center of the
video for fullscreen; double-click the left or right region to seek backward or
forward. Experimental RIFE/FRUC interpolation is not included or enabled.

The package uses `runFullTrust` for the packaged Win32/libmpv process and local
file access. Privacy, support, source, third-party notices, and corresponding
source information are public. No special test credentials are needed.

## Submission options

Retain manual publication after certification unless the user changes the
release policy. Submission, certification, publication, and device delivery
must be recorded as separate states.

## Observed submission result

- Submission ID: `1152921505701471034`
- Submitted: `2026-07-23` (Asia/Seoul)
- Partner Center package result: `PlainVideo_0.2.0.0_x64-store.msix` validated
- Current status: Submission complete; pre-processing in progress
- Certification: not started at the observation time
- Publishing: not started; manual `Publish now` hold retained
- Existing Store version: Submission 1 / `0.1.0.0` remains publicly available
