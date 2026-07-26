# PlainVideo 0.2.2 release notes

Status: GitHub prerelease published and Partner Center Submission 3 submitted;
currently in pre-processing, not yet certified or published in Microsoft Store

## User-visible changes

- Made volume and mute read as distinct states. Muting now shows an explicit
  localized muted state instead of leaving a faded percentage as the primary
  feedback, while unmuted volume retains its exact percentage and slider.
- Added audio timing correction in 0.1-second steps alongside the existing
  subtitle timing controls.
- Added `Alt+[` / `Alt+]` / `Alt+\` shortcuts to move audio earlier, move it
  later, or restore default timing.
- Added the same audio timing actions to the progressively disclosed Audio
  context submenu and reset audio timing when a different media file loads.
- Extended the real Windows interaction verifier to require exact
  `audio-delay` transitions from `-0.1` to `+0.1` and back to `0`.

## Release boundary

PlainVideo 0.2.2 keeps the borderless playback surface and does not add a
permanent toolbar or settings panel. Experimental RIFE/FRUC runtimes and models
remain outside normal portable and Store artifacts. GitHub prerelease,
Partner Center submission, certification, and Store availability remain
separate release states.

Partner Center accepted `PlainVideo_0.2.2.0_x64-store.msix` and Submission 3
(`1152921505701493629`) entered `Update in certification`, step 2 of 4
(`Pre-processing`) on 2026-07-27. Publication remains on manual hold: even after
certification, 0.2.2 will not start publishing until `Publish now` is selected.
The Microsoft Store version independently verified as available remains 0.2.0.0.

## Current local evidence

The 2026-07-26 clean-commit Quick integration passed all 14 steps on
`36ce3e8469829f5724eddbd4fff78aba5db4e93c`:
49 Rust tests passed with one explicit local-runtime test ignored, Clippy and
format checks passed, all 10 format rows were verified, and all 8 playback-soak
sessions completed without a selected failure. Real Windows input evidence
recorded subtitle and audio timing at `-0.1`, `+0.1`, and reset `0.0`.

The updated window verifier also captured the actual normal and muted renderer
states. The exact `0.2.2.0` Store MSIX contains 66 staged payload files and zero
RIFE/FRUC runtime or model assets. Microsoft Defender found no threats in the
Store MSIX, signed developer MSIX, or portable ZIP, and WACK reported overall
`PASS`.

- Store MSIX SHA-256: `2c7ee97b715684c16ac7496fb530dd9d5bcc7e404f9664eab77d6dafd7a6f96d`
- Portable ZIP SHA-256: `dbedaf556eb5f1e00ddc92b43377df76aa6b9b21bc2ea35c2a3223edfaef4c49`
- GitHub prerelease: <https://github.com/teemoZipsa/PlainVideo/releases/tag/v0.2.2>
