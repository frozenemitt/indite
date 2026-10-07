# The app icon

The icon is `Indite/AppIcon.icon`, an Icon Composer document: the I-beam text
cursor, the I of Indite, white on a tile that is a shade of black. One stem, and two
arms at each end that curve into it, drawn as one stroke with round ends. No
crossbar and no color: the only color in Indite is the ribbon that moves with the
voice, and the README's animated wordmark shows that ribbon as the cursor's crossbar.

Xcode builds the icon from the document, because the target's app icon is named
`AppIcon` and the document sits in the app's folder.

## Changing it

The shape comes from `draw-icon.swift`, which writes the document's SVG layer
and the two menu bar images. The numbers at its top are the design: where the
arms lie, how far they reach and bend, the stroke, and the cursor's size in the
tile and in the menu bar. From the repository's root:

```bash
swift Design/Icon/draw-icon.swift
```

Everything else is the document's: the tile, the glass, the opacity and the
shadow. Open `Indite/AppIcon.icon` in Icon Composer to change those; it saves
into `icon.json`.

To see the icon as macOS will draw it, without opening Icon Composer:

```bash
"/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool" \
  Indite/AppIcon.icon --export-image --output-file icon.png --platform macOS \
  --rendition Default --width 512 --height 512 --scale 2
```

`--rendition` also takes `Dark`, `ClearLight`, `ClearDark`, `TintedLight` and
`TintedDark`, the appearances a Mac can show.
