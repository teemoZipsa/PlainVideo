# Microsoft Store listing artwork

This directory contains prepared Partner Center artwork candidates. It is
intentionally separate from the PNG/ICO files embedded in the app and from
future MSIX package resources. Applicable fields must be confirmed against the
actual app listing in Partner Center before submission.

## Prepared files

The English and Korean poster/box-art copies are intentionally identical because
the only text is the product name `PlainVideo`.

| Artwork | Prepared file | Current status |
| --- | --- | --- |
| 1:1 App tile icon | `upload/shared/app-tile-300x300.png` | Documented for apps and recommended by Microsoft |
| 2:3 Poster art | `upload/<locale>/poster-1440x2160.png` | Candidate only; Microsoft's current MSIX guidance says this field applies to games, not apps |
| 1:1 Box art | `upload/<locale>/box-art-2160x2160.png` | Candidate only; Microsoft's current MSIX guidance says this field applies to games, not apps |
| 150 x 150 logo | `upload/shared/store-logo-150x150.png` | Reusable candidate; exact Partner Center or package mapping not yet verified |
| 71 x 71 logo | `upload/shared/store-logo-71x71.png` | Reusable candidate; exact Partner Center or package mapping not yet verified |

`<locale>` is `en-US` or `ko-KR`. The high-resolution poster and box-art
variants are retained as source-ready candidates, but they are not counted as
submission-ready app fields until the real Partner Center listing exposes an
applicable destination.

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
