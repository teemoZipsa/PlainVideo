# PlainVideo

> A borderless Windows video player that leaves only the video on screen.

PlainVideo extends the product philosophy of PlainView to video: open a file and start watching immediately, keep the interface out of the way, and reveal only the controls needed at that moment.

The project is currently in the **design and technical validation stage (pre-alpha)**. There is no distributable player yet.

[한국어 README](README.ko.md)

## Principles

- **Content first** — no title bar, borders, or permanently visible toolbars.
- **Obvious without instructions** — familiar actions such as click to play/pause and double-click for fullscreen.
- **UI only on demand** — a minimal overlay appears on pointer movement and disappears after interaction.
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

## Technical direction

- Playback candidate: [mpv/libmpv](https://github.com/mpv-player/mpv) with FFmpeg
- Interpolation candidate: [Practical-RIFE](https://github.com/hzwer/Practical-RIFE) models with an ncnn/Vulkan runtime
- UI shell: reuse PlainView's interaction language, but do not lock in Tauri until a native video-surface prototype proves the integration

See [Product definition](docs/PRODUCT.md) and [Architecture notes](docs/ARCHITECTURE.md).

## Name

`PlainVideo` makes both the product family and its purpose explicit: PlainView for images and PlainVideo for video. Trademark and store-name availability must still be checked again before a public binary release.

## License

Original PlainVideo code is released under the [MIT License](LICENSE). Bundled playback engines, codecs, models, and runtimes retain their own licenses; the exact distribution profile and notices will be locked before the first binary release.
