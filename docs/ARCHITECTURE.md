# Architecture notes

Status: Slice 0B libmpv embedding is implemented and locally verified. It is an architecture proof, not a shipped release artifact.

## Slice 0A implementation

The current prototype deliberately uses the smallest real-playback path:

- a dependency-free Rust launcher locates a pinned developer mpv runtime;
- mpv runs in an isolated configuration so user scripts cannot alter the proof;
- mpv owns the native playback window and GPU renderer;
- a PlainVideo Lua overlay supplies the localized idle hint and short-lived play, seek, and volume feedback;
- the stock mpv OSC is disabled, leaving no permanent controls or title bar.

This proves the content-first interaction against a real playback engine. It does **not** yet prove in-process embedding, a native overlay window, portable packaging, or a broad format matrix. Those remain the Slice 0B gate.

## Slice 0B implementation

The current prototype replaces the child-process window with a Rust-owned native shell:

- PlainVideo creates a per-monitor-DPI-aware opaque `WS_POPUP | WS_THICKFRAME` window, extends its client area through the native frame, and owns drag/drop, keyboard, mouse, fullscreen, and contextual menu behavior;
- the pinned `libmpv-2.dll` is loaded dynamically, and the core is configured from PlainVideo's isolated assets;
- libmpv's OpenGL render API runs on a dedicated thread that exclusively owns the WGL context;
- the UI thread issues asynchronous playback commands and drains client events without calling render functions;
- resize and render callbacks are coalesced through a condition-variable handshake;
- shutdown stops playback and the idle VO while rendering is active, flushes the final update, frees the render context on its owner thread, and then destroys the core;
- a local developer portable directory copies the executable, libmpv, assets, notices, provenance, and a SHA-256 file manifest.

This proves in-process embedding, transient Lua OSD reuse, real file-drop replacement, current-monitor fullscreen, and clean local teardown. It does **not** finish cross-DPI physical evidence, long-duration replacement soak, a broad format matrix, or redistribution licensing.

## Constraints

- Windows-first and portable-first.
- Broad local media compatibility cannot depend on the WebView codec set.
- Hardware decoding, subtitles, HDR, tone mapping, and A/V sync belong to a mature playback core.
- The UI must remain borderless and mostly invisible.
- Frame interpolation must never make ordinary playback unreliable.
- Binary provenance and third-party licenses must be reproducible before release.

## Playback core

The embedded player uses **libmpv** rather than building a decoder, demuxer, clock, subtitle renderer, and GPU renderer from scratch. Slice 0A launched the pinned mpv executable; Slice 0B moved the proven interaction onto libmpv's render API.

Why it is the leading candidate:

- mpv exposes a client API and render API intended for embedding;
- it inherits FFmpeg's broad container and codec support;
- it already handles hardware decoding, subtitles, audio/video synchronization, HDR-related rendering, and runtime properties;
- its display-resample interpolation provides a useful lightweight smooth-playback baseline.

The primary player must not be an HTML `<video>` element. WebView media support varies with the installed runtime and does not provide the control or compatibility required by the product goal.

## Window and UI shell

PlainView uses Tauri, React, and a WebView effectively because an image can live in the DOM. A native video renderer changes the constraints.

The Rust-native Win32 shell is the proven Slice 0B baseline. A higher-level overlay toolkit remains optional until it proves all of the following without regressing this baseline:

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

### Slice 0B exit criteria status

1. **Verified:** render through libmpv's render API in a PlainVideo-owned native window.
2. **Verified:** preserve click, seek, fullscreen, subtitle, localized idle, and no-permanent-UI behavior.
3. **Verified:** expose open, subtitle, and close through a right-click menu; use the full-width top 56 logical pixels as the only native window-move zone, without a visible handle or `Alt`+drag override.
4. **Mostly verified:** real rapid file replacement, both connected displays, a synthetic DPI message, and clean GPU teardown pass. Both physical displays are 96 DPI, so a real cross-scale transition and a longer soak remain.
5. **Partial:** a reproducible local developer portable directory exists, but the complete licensed component/source inventory is not yet sufficient for redistribution.

Exact embedding evidence is recorded in [`SLICE_0B_LIBMPV_PROOF.md`](SLICE_0B_LIBMPV_PROOF.md). The later DWM, physical-pixel placement, responsive-control, and window-state evidence is recorded in [`WINDOW_BEHAVIOR_PROOF.md`](WINDOW_BEHAVIOR_PROOF.md).

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
