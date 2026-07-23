# PlainVideo

> A borderless Windows video player that leaves only the video on screen.

PlainVideo extends the product philosophy of PlainView to video: open a file and start watching immediately, keep the interface out of the way, and reveal only the controls needed at that moment.

PlainVideo is available as a free Microsoft Store app and as a matching portable Windows build. The shipped Win32 MSIX and portable package use the same reviewed shared-LGPL playback-runtime profile, with public notices and corresponding source. See the [Microsoft Store release plan](docs/STORE_RELEASE_PLAN.md) for the exact release evidence and remaining platform limits.

[Get PlainVideo from Microsoft Store](https://apps.microsoft.com/detail/9PDKQ88FKG1L)

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
- Click to play/pause, double-click fullscreen, five-second arrow-key seek, 30-second `Shift`+arrow seek, arrow-key or mouse-wheel volume, and `Esc` to return
- Translucent feedback and a compact playback bar that appear only after pointer/input activity; no permanent toolbar
- A pointer that hides after 1.6 seconds during playback and returns on mouse movement
- A full-width invisible 56 px top move zone with a move cursor and no visible handle
- PlainView-style top-right theme, always-on-top, minimize, fullscreen, and close controls, plus transient play, seek, volume-slider/mute, and subtitle controls
- Physical-pixel window placement across monitors, DPI-scaled 280×240 minimum sizing, and DWM border suppression with the native shadow retained
- Automatic discovery of same-name external SRT subtitles, plus contextual subtitle and audio-track selection, subtitle-file drop attachment, external subtitle loading, and 0.1-second timing correction
- A localized empty state with no Korean/English mixing and a `Ctrl+O` open path
- `PageUp`/`PageDown` previous-next navigation, `A` audio-track cycling, `V` subtitle cycling, `M` mute, and `Ctrl+[`/`Ctrl+]`/`Ctrl+\` subtitle timing
- `Tab` toggles an unobscured, left-aligned media-information overlay without interrupting playback
- Automatic resume for partially watched local files, with a transient resume notice and a context-menu restart action
- Hover thumbnail previews on the seek bar, direct CC subtitle toggle, and remembered volume and mute state
- `S` saves a playback screenshot to the Windows Pictures library with transient confirmation
- `F6`/`Shift+F6` keyboard focus for transient controls, with `Enter` or `Space` activation and a visible focus state
- Real file-drop replacement, plus a progressively disclosed right-click menu for open, retry, previous/next, audio, subtitles, and close
- Recoverable per-file playback errors that keep the window open for retry, another file, or drag and drop instead of terminating the app
- A reproducible local developer portable directory with per-file hashes

The 0.2.0 release-candidate validation on 2026-07-23 passed all ten generated container, codec, audio, and subtitle combinations against one staged portable directory using the reviewed release runtime. This remains exact evidence for that release, not a blanket support claim; see the [format compatibility ledger](docs/FORMAT_COMPATIBILITY_LEDGER.md) for the rows and limits. Hardware decoding is selected per machine and a verified software path remains available.

## Run locally

```powershell
.\scripts\bootstrap-mpv.ps1
cargo run --release -- "C:\path\to\video.mkv"
```

With FFmpeg installed, `.\scripts\generate-smoke-media.ps1` recreates the deterministic fixtures. `.\scripts\build-portable.ps1` creates a local developer proof, while `.\scripts\build-release-portable.ps1` is the clean-commit release path using the approved runtime profile. `.\scripts\run-local-validation.ps1` runs the local quality gate as one batch. See [quality pass 1-6](docs/QUALITY_PASS_1_TO_6.md) for this scope and its remaining gates, plus the [accessibility baseline](docs/ACCESSIBILITY_BASELINE.md), [format compatibility ledger](docs/FORMAT_COMPATIBILITY_LEDGER.md), [playback stability plan](docs/PLAYBACK_STABILITY_PLAN.md), [Slice 0B libmpv proof](docs/SLICE_0B_LIBMPV_PROOF.md), and [Windows window-behavior proof](docs/WINDOW_BEHAVIOR_PROOF.md) for the exact evidence and limits.

## Technical direction

- Playback core: [mpv/libmpv](https://github.com/mpv-player/mpv) with FFmpeg
- Interpolation candidate: [Practical-RIFE](https://github.com/hzwer/Practical-RIFE) models with an ncnn/Vulkan runtime
- UI shell: the proven baseline is a thin Rust/Win32 shell; any higher-level overlay toolkit must preserve its native-surface behavior

See [Product definition](docs/PRODUCT.md) and [Architecture notes](docs/ARCHITECTURE.md).

## Name

`PlainVideo` makes both the product family and its purpose explicit: PlainView for images and PlainVideo for video. The name is reserved and the product is published under Store ID `9PDKQ88FKG1L`.

## License

Original PlainVideo code is released under the [MIT License](LICENSE). Bundled playback engines, codecs, and runtimes retain their own licenses; release packages include the locked runtime profile, notices, license material, and corresponding-source offer. Experimental interpolation runtimes and models are not included in the 0.2.1 release.

See the [privacy policy](PRIVACY.md) and [support guide](SUPPORT.md) for the Microsoft Store and portable releases.
