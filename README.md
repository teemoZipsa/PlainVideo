# PlainVideo

> A borderless Windows video player that leaves only the video on screen.

PlainVideo extends the product philosophy of PlainView to video: open a file and start watching immediately, keep the interface out of the way, and reveal only the controls needed at that moment.

The project is currently at the **embedded playback proof stage (pre-alpha)**. A local prototype renders in-process through libmpv inside a PlainVideo-owned window, but there is no distributable player yet.

PlainVideo is now planned as a free Microsoft Store app delivered as packaged Win32 MSIX, while retaining a matching portable build. The current developer libmpv runtime is not approved for redistribution, so runtime license/build closure is the first Store release gate. See the [Microsoft Store release plan](docs/STORE_RELEASE_PLAN.md).

[한국어 README](README.ko.md)

## Principles

- **Content first** — no title bar, borders, or permanently visible toolbars.
- **Obvious without instructions** — familiar actions such as click to play/pause and double-click for fullscreen.
- **UI only on demand** — brief feedback appears only after play, seek, or volume input and then disappears.
- **Broad capability, thin surface** — subtitles, tracks, media information, and advanced video options use progressive disclosure.
- **No ads, accounts, or tracking** — local playback remains local and distraction-free.
- **Honest fallbacks** — expensive features appear only when the machine can sustain them.

## Direction

- Broad container, codec, audio-track, and subtitle support through an mpv/FFmpeg-class playback core
- Automatic hardware decoding with a reliable software fallback
- Folder navigation, external subtitle discovery, playback speed, screenshots, always-on-top, HDR, and tone mapping
- A portable Windows build as a first-class release artifact
- Lightweight display-synchronized playback plus an optional, clearly labeled RIFE-based real-time frame doubler

Display synchronization and AI frame generation are intentionally treated as different features. The experimental frame doubler will be off by default, capability-gated, and designed to fall back cleanly during seeking, scene changes, or overload.

## Working now

- A Rust-owned native Windows shell around a pinned libmpv developer runtime
- In-process render-API playback in a titleless, borderless window
- Click to play/pause, double-click fullscreen, arrow-key seek and volume, and `Esc` to return
- Translucent feedback and a compact playback bar that appear only after pointer/input activity; no permanent toolbar
- A pointer that hides after 1.6 seconds during playback and returns on mouse movement
- A full-width invisible 56 px top move zone with a move cursor and no visible handle
- PlainView-style top-right theme, always-on-top, minimize, and close controls, plus transient play, seek, mute, subtitle, and fullscreen controls
- Physical-pixel window placement across monitors, DPI-scaled 280×240 minimum sizing, and DWM border suppression with the native shadow retained
- Automatic discovery of same-name external SRT subtitles, plus context-menu off, track selection, and external subtitle loading
- A localized empty state with no Korean/English mixing and a `Ctrl+O` open path
- Real file-drop replacement, plus a progressively disclosed right-click menu for open, subtitles, and close
- A reproducible local developer portable directory with per-file hashes

The evidence currently covers an H.264/AAC MP4 fixture, a Matroska remux of the same streams, and external SRT. The embedded Slice 0B build selected `nvdec` hardware decoding on the development machine; the older child-process Slice 0A build observed `d3d11va-copy`. Neither observation is a broader hardware guarantee.

## Run locally

```powershell
.\scripts\bootstrap-mpv.ps1
cargo run --release -- "C:\path\to\video.mkv"
```

With FFmpeg installed, `.\scripts\generate-smoke-media.ps1` recreates the deterministic fixtures. `.\scripts\build-portable.ps1` creates a local developer portable proof under `.runtime`; it is not approved for redistribution. See the [Slice 0A playback proof](docs/SLICE_0_PLAYBACK_PROOF.md), [Slice 0B libmpv proof](docs/SLICE_0B_LIBMPV_PROOF.md), [UI/UX polish proof](docs/UI_UX_POLISH_PROOF.md), and [Windows window-behavior proof](docs/WINDOW_BEHAVIOR_PROOF.md) for the exact evidence and limits.

## Technical direction

- Playback core: [mpv/libmpv](https://github.com/mpv-player/mpv) with FFmpeg
- Interpolation candidate: [Practical-RIFE](https://github.com/hzwer/Practical-RIFE) models with an ncnn/Vulkan runtime
- UI shell: the proven baseline is a thin Rust/Win32 shell; any higher-level overlay toolkit must preserve its native-surface behavior

See [Product definition](docs/PRODUCT.md) and [Architecture notes](docs/ARCHITECTURE.md).

## Name

`PlainVideo` makes both the product family and its purpose explicit: PlainView for images and PlainVideo for video. Trademark and store-name availability must still be checked again before a public binary release.

## License

Original PlainVideo code is released under the [MIT License](LICENSE). Bundled playback engines, codecs, models, and runtimes retain their own licenses; the exact distribution profile and notices will be locked before the first binary release.
