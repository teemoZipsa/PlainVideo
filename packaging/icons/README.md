# PlainVideo icon assets

`plainvideo-icon-source.png` preserves the transparent 1254 x 1254 extraction
with its original generous canvas. It is an archival source, not a file to use
directly in Windows packaging.

`plainvideo-icon-master.png` is the canonical transparent 1024 x 1024 artwork.
It normalizes the visible object to a square canvas with a 7% optical margin and
is byte-identical to `png/plainvideo-1024.png`. All smaller PNG and ICO outputs
derive from this master.

## Generated outputs

- PNG: 16, 20, 24, 30, 32, 40, 44, 48, 64, 71, 89, 96, 107, 128, 142, 150,
  256, 284, 310, 512, and 1024 pixels
- ICO frames: 16, 20, 24, 32, 40, 48, 64, 96, 128, and 256 pixels

Partner Center display artwork is kept separately under
`../../assets/store-listing/`; it is not a package icon set.

`plainvideo.ico` is embedded into `plainvideo.exe` by the repository `build.rs`.
The native window class loads resource 101 for its large and small icons, so the
EXE, taskbar entry, and window share the same artwork.

## Artwork provenance

The approved two-panel PlainVideo concept was refined against the existing
PlainView and PlainZip icons as product-family references. The final source was
produced with the built-in image-generation path, using a flat `#ff00ff`
background and the following background-extraction instruction:

> Preserve the approved two-panel navy PlainVideo icon exactly. Change only the
> surrounding background to a perfectly uniform #ff00ff chroma key, removing
> every cast shadow, floor plane, reflection, gradient, texture, and halo.

The installed image-generation helper removed the key with border sampling, a
soft matte, despill, transparent threshold 12, and opaque threshold 220. Pillow
12.3.0 produced the committed resizes and multi-frame ICO. Neither tool is needed
to build or run PlainVideo because all generated icon assets are committed.
