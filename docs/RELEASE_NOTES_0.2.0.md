# PlainVideo 0.2.0 release notes

## User-visible changes

- Added seek-bar thumbnail previews without interrupting the current playback position.
- Added automatic resume for partially watched local files and a restart-from-beginning action.
- Added playback screenshots saved to the Windows Pictures library with transient confirmation.
- Expanded the `Tab` media-information overlay while keeping playback uninterrupted.
- Made the CC button a direct subtitle on/off toggle; detailed track selection remains in the context menu.
- Remembered volume and mute state between launches.
- Moved fullscreen beside minimize and close while retaining video double-click fullscreen.
- Unified transient feedback for playback, seeking, volume, speed, subtitles, and window actions.
- Improved single-click play/pause response and prevented window dragging or context-menu use from pausing playback.
- Added directional surface double-click seek and broader input-conflict regression coverage.

## Release boundary

Experimental RIFE/FRUC frame interpolation is not included or enabled in this release. PlainVideo 0.2.0 retains the proven source-frame playback path and its existing playback-runtime profile.
