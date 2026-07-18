# Architecture notes

Status: candidate architecture for the first playback-surface proof. Nothing in this document is a shipped capability yet.

## Constraints

- Windows-first and portable-first.
- Broad local media compatibility cannot depend on the WebView codec set.
- Hardware decoding, subtitles, HDR, tone mapping, and A/V sync belong to a mature playback core.
- The UI must remain borderless and mostly invisible.
- Frame interpolation must never make ordinary playback unreliable.
- Binary provenance and third-party licenses must be reproducible before release.

## Playback core

The first prototype should use **libmpv** rather than building a decoder, demuxer, clock, subtitle renderer, and GPU renderer from scratch.

Why it is the leading candidate:

- mpv exposes a client API and render API intended for embedding;
- it inherits FFmpeg's broad container and codec support;
- it already handles hardware decoding, subtitles, audio/video synchronization, HDR-related rendering, and runtime properties;
- its display-resample interpolation provides a useful lightweight smooth-playback baseline.

The primary player must not be an HTML `<video>` element. WebView media support varies with the installed runtime and does not provide the control or compatibility required by the product goal.

## Window and UI shell

PlainView uses Tauri, React, and a WebView effectively because an image can live in the DOM. A native video renderer changes the constraints.

The shell decision remains open until a spike proves all of the following together:

1. libmpv renders into the intended Windows surface with hardware decoding;
2. a transparent or adjacent overlay receives input without flicker or focus bugs;
3. resize, DPI changes, multiple monitors, fullscreen, and always-on-top work predictably;
4. the packaged portable build starts without machine-specific dependencies;
5. closing and rapid file switching release decoder and GPU resources cleanly.

Candidate shells:

- Tauri/React plus a native child render surface, if the composition prototype is reliable;
- a Rust-native window/render shell with a thin declarative overlay;
- Qt/QML as a fallback if it materially reduces native-surface risk.

Visual similarity to PlainView is a design-token and interaction requirement, not a reason to force the same rendering architecture.

## Smooth motion ladder

### Level 0 — normal playback

Use the source cadence with reliable A/V sync and hardware decoding.

### Level 1 — display synchronization

Use mpv's display-resample and temporal scaling path where supported. This can reduce cadence judder, but it does not estimate motion or create semantically new frames. The UI must not call it “AI frame interpolation.”

### Level 2 — real-time frame doubling

Prototype an optional RIFE pipeline using current Practical-RIFE models and a Vulkan-friendly inference runtime such as ncnn.

Required safety behavior:

- benchmark before the option becomes available;
- 2x only for the first release;
- bypass interpolation during seek, decode discontinuity, and scene changes;
- detect queue growth and fall back before A/V sync drifts;
- keep the decoded source frame available so disabling the feature is immediate;
- record dropped, generated, and bypassed frame counts for diagnostics;
- never write temporary decoded frame sequences to disk during playback.

The older `rife-ncnn-vulkan` command-line pipeline is useful evidence that portable Vulkan inference is possible, but it is not itself a real-time player integration. The spike must evaluate maintained libraries and model compatibility rather than shelling out once per frame.

## Format claims

The repository should eventually generate a support matrix from the exact shipped mpv/FFmpeg build:

- build configuration;
- demuxers and protocols;
- video, audio, and subtitle decoders;
- available hardware-decoder paths;
- test fixtures and expected fallback behavior.

Marketing copy should name common containers and codecs, but exhaustive claims must come from that generated evidence.

## Licensing gate

- mpv is GPL by default and can be built in an LGPL profile with GPL features disabled.
- FFmpeg is LGPL by default, but optional components can make a build GPL.
- RIFE code, model files, ncnn, shader libraries, and binary redistribution each need explicit inventory.
- The app's original MIT license does not override third-party obligations.

Before the first distributable binary, check in:

- exact source revisions and build options;
- corresponding source and license links;
- `THIRD_PARTY_NOTICES` generated from the locked dependency set;
- a documented decision on LGPL-only versus GPL distribution;
- codec and patent review for intended distribution regions.

## Local validation before remote automation

No GitHub Actions workflow is part of the foundation. Tests, format-fixture smoke checks, package inspection, and playback soaks must run locally first. Remote automation requires explicit approval.
