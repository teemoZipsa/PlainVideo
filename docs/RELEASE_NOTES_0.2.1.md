# PlainVideo 0.2.1 release notes

## User-visible changes

- Redesigned the compact volume control so the speaker, slider, percentage,
  and mute state read as one balanced control at normal and narrow widths.
- Made mute feedback explicit without adding a permanently visible label.
- Allowed one subtitle file dropped onto an active video to attach without
  replacing or restarting that video.
- Added subtitle timing controls in 0.1-second steps, plus reset, to the
  context menu and `Ctrl+[` / `Ctrl+]` / `Ctrl+\` shortcuts.
- Reset subtitle timing when a different media file is loaded.
- Expanded automated input coverage with a real cross-process Windows file
  drop and exact subtitle-timing checks.

## Release boundary

PlainVideo 0.2.1 uses the same reviewed source-frame playback runtime as the
published releases. Experimental RIFE/FRUC runtimes and models are not included
or enabled, and normal playback retains its existing fallback path.
