# The app icon

`Inscribe.icon` is an Icon Composer document: two quotation marks cut into stone,
standing as the uprights of an N, and a carver's chisel lying across them as its
diagonal. The marks and the chisel are glass layers; the tile is a shade of black.
No color: the only color in Inscribe is the ribbon that moves with the voice.

`draw-icon.swift` draws the shapes and writes them as the SVG layers in
`Inscribe.icon/Assets`. Build and run it with

```bash
swiftc -O -o draw-icon draw-icon.swift -framework AppKit -framework CoreImage && ./draw-icon
```

To see the icon as macOS will draw it, without opening Icon Composer:

```bash
"/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool" \
  Inscribe.icon --export-image --output-file icon.png --platform macOS --rendition Default \
  --width 512 --height 512 --scale 2
```
