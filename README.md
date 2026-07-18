# PlainVideo

> A borderless Windows video player that leaves only the video on screen.

PlainVideo extends the product philosophy of PlainView to video: open a file and start watching immediately, keep the interface out of the way, and reveal only the controls needed at that moment.

The project is currently at the **playback-surface proof stage (pre-alpha)**. A local prototype plays through the real mpv engine, but there is no distributable player yet.

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

- A small Rust launcher around a pinned mpv developer runtime
- Real playback in a titleless, borderless window
- Click to play/pause, double-click fullscreen, arrow-key seek and volume, and `Esc` to return
- PlainVideo's own transient play, seek, and volume feedback; no permanent toolbar
- Automatic discovery of a same-name external SRT subtitle
- A single localized drop hint on the empty surface

The evidence currently covers an H.264/AAC MP4 fixture, a Matroska remux of the same streams, and external SRT. `d3d11va-copy` hardware decoding was observed on the development machine. Broader format support is a direction, not yet a product guarantee.

## Run locally

```powershell
.\scripts\bootstrap-mpv.ps1
cargo run --release -- "C:\path\to\video.mkv"
```

With FFmpeg installed, `.\scripts\generate-smoke-media.ps1` recreates the deterministic fixtures. See the [Slice 0 playback proof](docs/SLICE_0_PLAYBACK_PROOF.md) for the exact evidence and limits.

## Technical direction

- Playback candidate: [mpv/libmpv](https://github.com/mpv-player/mpv) with FFmpeg
- Interpolation candidate: [Practical-RIFE](https://github.com/hzwer/Practical-RIFE) models with an ncnn/Vulkan runtime
- UI shell: reuse PlainView's interaction language, but do not lock in Tauri until a native video-surface prototype proves the integration

See [Product definition](docs/PRODUCT.md) and [Architecture notes](docs/ARCHITECTURE.md).

## Name

`PlainVideo` makes both the product family and its purpose explicit: PlainView for images and PlainVideo for video. Trademark and store-name availability must still be checked again before a public binary release.

## License

Original PlainVideo code is released under the [MIT License](LICENSE). Bundled playback engines, codecs, models, and runtimes retain their own licenses; the exact distribution profile and notices will be locked before the first binary release.
