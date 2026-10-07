# The app icon

The icon is `Indite/AppIcon.icon`, an Icon Composer document: two quotation
marks standing as the uprights of an N, and a carver's chisel lying across them as
its diagonal. Each mark is one stroke, rounded at the head and narrowing to a
rounded tail, leaning twelve degrees. The chisel is a plain bar whose edge is cut
on a slant, lying at forty-five degrees over the marks as smoked glass, its butt
at the top-left and its edge at the bottom-right. The tile is a shade of black and
the shapes are white at two opacities. No color: the only color in Indite is the
ribbon that moves with the voice.

Xcode builds the icon from the document, because the target's app icon is named
`AppIcon` and the document sits in the app's folder.

## Changing it

The shapes come from `draw-icon.swift`, which writes the document's two SVG
layers. The numbers at its top are the design: the marks' lean, taper, bend,
width, height and spacing; the chisel's angle, length, width, outline and slant.
From the repository's root:

```bash
swift Design/Icon/draw-icon.swift
```

Everything else is the document's: the tile, the glass, the opacities, the
shadows and the order of the layers. Open `Indite/AppIcon.icon` in Icon
Composer to change those; it saves into `icon.json`.

To see the icon as macOS will draw it, without opening Icon Composer:

```bash
"/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool" \
  Indite/AppIcon.icon --export-image --output-file icon.png --platform macOS \
  --rendition Default --width 512 --height 512 --scale 2
```

`--rendition` also takes `Dark`, `ClearLight`, `ClearDark`, `TintedLight` and
`TintedDark`, the appearances a Mac can show.
