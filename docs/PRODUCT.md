# Product definition

## Promise

Open a video and watch it. PlainVideo should feel understandable to a first-time computer user while retaining serious playback capability for people who need it.

The product is not “a simple player with few features.” It is a capable player whose complexity stays out of sight until it is useful.

## Default surface

During ordinary playback, the window contains only:

- the video;
- letterbox or pillarbox background when required;
- subtitles when enabled.

Actual input reveals only the feedback needed for that action:

- play or pause briefly shows a centered glyph;
- seeking briefly shows current time, duration, and a thin progress line;
- volume adjustment briefly shows a percentage;
- the empty surface shows one localized drop hint.

Pointer movement reveals one compact, time-limited playback bar and the top-right window controls. Track selection and advanced actions remain in contextual surfaces and all overlays disappear again after inactivity.

Close, always-on-top, and window movement remain discoverable without recreating a conventional title bar. The top-right controls appear on activity, while the full-width top 56 logical pixels form an invisible native move zone with only a move cursor. The right-click menu is reserved for open, subtitle, and close actions.

## Interaction defaults

| Input | Default action |
|---|---|
| Single click on video | Play or pause |
| Double click on video | Enter or leave fullscreen |
| Space | Play or pause |
| Left / Right | Short seek backward / forward |
| Up / Down | Volume |
| Esc | Leave fullscreen; no action when already windowed |
| Drop a media file | Open and play |

These are hypotheses for usability testing, not immutable shortcuts. In particular, window dragging and single-click playback can conflict in a borderless window and need a prototype.

## Progressive disclosure

1. **Always obvious:** play, seek, volume, fullscreen.
2. **Only when relevant:** subtitle and audio-track selectors, chapter markers, playlist navigation.
3. **Overflow or context menu:** speed, aspect ratio, rotation, screenshot, file information, hardware-decoder status.
4. **Advanced settings:** color management, tone mapping, cache, audio delay, subtitle timing, interpolation quality.

## Release slices

### Slice 0 — playback-surface proof

- Open one local MP4 and MKV file.
- Render through the real native playback engine.
- Play, pause, seek, resize, fullscreen, and preserve A/V sync.
- Prove that a borderless overlay can coexist with the video surface.

### Slice 1 — trustworthy everyday player

- Broad local-format matrix generated from the shipped engine.
- Hardware decoding, software fallback, subtitles, audio tracks, drag and drop.
- Folder navigation and portable Windows artifact.
- Crash recovery and deterministic local smoke fixtures.

### Slice 2 — modern video quality

- HDR and tone mapping validation.
- Display-synchronized smooth playback.
- Capability and performance diagnostics phrased in plain language.

### Slice 3 — experimental frame doubler

- 2x only at first: 24→48 and 30→60.
- Vulkan capability check and benchmark before enabling.
- Scene-cut detection, overload fallback, seeking bypass, and A/V-sync soak tests.
- Clear visual distinction between display sync and generated intermediate frames.

## Non-goals

- Streaming-service accounts, DRM circumvention, or embedded ad-supported web portals
- A Plex-style library or media server
- Editing, transcoding, downloading, or media scraping
- Features added only to make the settings page look competitive

## Naming gate

PlainVideo is the selected product and repository name. It keeps the PlainView family relationship while making the video focus explicit. Repeat store, domain, trademark, and search-confusion checks before branding a public binary.
