# Microsoft Store listing artwork

This directory contains the Partner Center artwork used by PlainVideo. It is
intentionally separate from the PNG/ICO files embedded in the app and from
MSIX package resources. The listed destinations were verified against the live
app listing in Partner Center.

## Prepared files

The English and Korean poster/box-art copies are intentionally identical because
the only text is the product name `PlainVideo`.

| Artwork | Prepared file | Current status |
| --- | --- | --- |
| 1:1 App tile icon | `upload/shared/app-tile-300x300.png` | Uploaded for both locales |
| Poster art | `upload/<locale>/poster-1440x2160.png` | Uploaded for both locales |
| 1:1 Box art | `upload/<locale>/box-art-2160x2160.png` | Uploaded for both locales |
| 150 x 150 logo | `upload/shared/store-logo-150x150.png` | Uploaded for both locales |
| 71 x 71 logo | `upload/shared/store-logo-71x71.png` | Uploaded for en-US; add to ko-KR in Submission 2 |

`<locale>` is `en-US` or `ko-KR`. The high-resolution poster and box-art
variants are retained as source-ready assets. Partner Center currently exposes
poster, box-art, app-tile, 150 x 150, and 71 x 71 destinations for both locales.

## Source and regeneration

The generated background plates and composed high-resolution masters live in
`source/shared/`. The exact transparent app artwork remains
`../../packaging/icons/plainvideo-icon-master.png` and is composited without
redrawing it.

Regenerate every upload file from the repository root:

```powershell
python scripts\build-store-listing-assets.py
```

The script uses Pillow and the installed Segoe UI Bold font. It checks every
output's pixel dimensions, RGB mode, and 50 MB Store upload limit.

## Generation provenance

The two background plates were created with the built-in image-generation tool.
The PlainVideo icon was a palette/material reference, while NeatRename's Store
art was a Plain-family tone and spacing reference only.

Portrait prompt summary:

> Minimal 2:3 Microsoft Store poster background plate; deep navy gradient,
> restrained electric-cyan bloom, faint rounded video-frame silhouettes, clean
> title and icon areas, subdued bottom third; no icon, text, play symbol, UI,
> documents, check marks, orange, or watermark.

Square prompt summary:

> Minimal 1:1 Microsoft Store box-art and app-tile background plate; deep navy
> radial gradient, cyan halo, nested glossy video-frame contours, clean title
> and centered-icon areas, subdued bottom third; no icon, text, play symbol,
> UI, documents, arrows, check marks, orange, or watermark.

The build script adds the exact `PlainVideo` name and existing icon after image
generation, preventing text errors or brand-mark drift.

Official specification:

- [Microsoft Store screenshots and images](https://learn.microsoft.com/windows/apps/publish/publish-your-app/msix/screenshots-and-images)
