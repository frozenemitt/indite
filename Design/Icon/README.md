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

## The README's wordmark

`draw-wordmark.swift` draws the ribbon in the README's animated wordmark,
`Docs/Images/wordmark-light.svg` and `wordmark-dark.svg`. The ribbon follows the
dictation panel's, and the numbers at the script's top are copied from
`ListeningBar.swift`, so a change to one belongs in both. The motion is
`wordmark-motion.json`: 82 frames of 48 band amplitudes, played over 6.8 seconds.
The script rewrites only the ribbon; the tile, the cursor and the name stay as they
are in the SVGs. From the repository's root:

```bash
swift Design/Icon/draw-wordmark.swift
```

Judge the result in Safari, on the README itself. A snapshot redraws the whole
image every time, so it hides the stale glow that Safari can leave behind.
