# PlainVideo 0.2.2 candidate release notes

Status: source candidate with developer-portable validation; not yet release
packaged, submitted, certified, or published

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
remain outside normal portable and Store artifacts. This document describes a
source candidate only until exact package, local validation, certification, and
public availability are verified separately.

## Current local evidence

The 2026-07-26 dirty-working-tree Quick integration passed all 14 steps:
49 Rust tests passed with one explicit local-runtime test ignored, Clippy and
format checks passed, all 10 format rows were verified, and all 8 playback-soak
sessions completed without a selected failure. Real Windows input evidence
recorded subtitle and audio timing at `-0.1`, `+0.1`, and reset `0.0`.

The updated window verifier also captured the actual normal and muted renderer
states. This remains developer evidence; a clean commit and exact release
package must repeat the required gates before publication.
