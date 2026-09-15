# Official Edgee branding

Source assets retrieved from Edgee's official website on 2026-09-15:

- `EdgeeMark.svg`: https://www.edgee.ai/assets/icons/favicon.svg
- `EdgeeWordmark.svg`: the inline navigation logo in https://www.edgee.ai/ (viewBox `0 0 120 28`).

These are Edgee's original vector paths, not a redraw. The PDFs in `Sources/EdgeeWidget/Resources` are vector conversions for native AppKit rendering. macOS applies a template tint in the panel and menu bar; the app icon uses the original mark color on a white rounded tile.

Regenerate the native assets with librsvg (only needed when updating the source artwork; normal builds have no dependency on librsvg):

```sh
rsvg-convert --format pdf --output Sources/EdgeeWidget/Resources/EdgeeMark.pdf Resources/Branding/EdgeeMark.svg
rsvg-convert --format pdf --output Sources/EdgeeWidget/Resources/EdgeeWordmark.pdf Resources/Branding/EdgeeWordmark.svg
```

The Edgee name and logos belong to their respective owner. This project's software license does not grant rights to Edgee's trademarks.
