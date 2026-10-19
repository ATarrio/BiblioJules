# Logo / app icon

`logo.svg` is the master artwork: a pink rounded tile holding a white book with
a pink spine and a bookmark ribbon. It is plain SVG — named Inkscape layers
(`Background`, `Book`), rects and paths, gradients, no fonts, no raster images,
no clipping masks — so it opens and edits normally in Inkscape 1.x.

Every icon in the three clients is generated from this one file:

| Client      | Generated files                                                                                                                                                  | Used for                                                                                    |
| ----------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------- |
| **Web**     | `app/static/img/logo.svg`, `favicon.ico`, `apple-touch-icon.png`                                                                                                  | sidebar + mobile top bar + sign-in `<img>`, `<link rel="icon">`, `/favicon.ico` route         |
| **Desktop** | `app/desktop/assets/logo.svg`, `logo.png`                                                                                                                         | sidebar brand (`main_window.py`), window/taskbar icon (`app.py`)                              |
| **Android** | `mobile/android/app/src/main/res/mipmap-*/ic_launcher.png`, `mipmap-*/ic_launcher_foreground.png`, `mobile/android/app/src/main/res/drawable/ic_launcher_background.xml`, `mipmap-anydpi-v26/ic_launcher.xml`, `mobile/assets/images/logo.png` | launcher icon (legacy + adaptive) and the sign-in mark |

## Palette

| Element         | Colour                          |
| --------------- | ------------------------------- |
| Tile gradient   | `#FFB0D0` → `#FA6BA8` → `#EA3D84` |
| Book cover      | `#FFFFFF` → `#FFEFF7`           |
| Spine           | `#DC3D80`                       |
| Bookmark ribbon | `#B81C5C`                       |
| Drop shadow     | `#7A0B41` at 30%                |

## Regenerating

Needs Inkscape 1.x and ImageMagick 7 (`magick`). Run from the repository root.

```bash
# --- Web -------------------------------------------------------------------
cp images/logo.svg app/static/img/logo.svg
inkscape --export-type=png --export-filename=app/static/img/apple-touch-icon.png \
    --export-width=180 images/logo.svg
for w in 16 32 48; do
    inkscape --export-type=png --export-filename=/tmp/favicon-$w.png \
        --export-width=$w images/logo.svg
done
magick /tmp/favicon-16.png /tmp/favicon-32.png /tmp/favicon-48.png \
    app/static/img/favicon.ico

# --- Desktop ---------------------------------------------------------------
cp images/logo.svg app/desktop/assets/logo.svg
inkscape --export-type=png --export-filename=app/desktop/assets/logo.png \
    --export-width=256 images/logo.svg

# --- Android launcher icon (Android 7 and older, and every density) --------
for spec in mdpi:48 hdpi:72 xhdpi:96 xxhdpi:144 xxxhdpi:192; do
    d=${spec%%:*}; w=${spec##*:}
    inkscape --export-type=png \
        --export-filename=mobile/android/app/src/main/res/mipmap-$d/ic_launcher.png \
        --export-width=$w images/logo.svg
done

# --- Android adaptive icon foreground (Android 8+) -------------------------
# 108dp canvas with the book kept inside the 66dp safe circle, so no launcher
# mask can clip it. The book layer only, exported on a wider canvas.
for spec in mdpi:108 hdpi:162 xhdpi:216 xxhdpi:324 xxxhdpi:432; do
    d=${spec%%:*}; w=${spec##*:}
    inkscape --export-type=png --export-id=layer-book --export-id-only \
        --export-area=-144:-144:656:656 \
        --export-filename=mobile/android/app/src/main/res/mipmap-$d/ic_launcher_foreground.png \
        --export-width=$w images/logo.svg
done

# --- Android in-app mark (sign-in screen) ----------------------------------
inkscape --export-type=png --export-filename=mobile/assets/images/logo.png \
    --export-width=384 images/logo.svg
```

`mipmap-anydpi-v26/ic_launcher.xml` and `drawable/ic_launcher_background.xml`
are hand-written and only need touching if the *structure* of the icon changes,
not when the artwork is recoloured.

## Notes

- **Adaptive background.** Android shape drawables cannot express the tile's
  radial sheen, so `ic_launcher_background.xml` is a plain two-stop version of
  the tile gradient. The legacy `ic_launcher.png` files and the web/desktop
  copies use the full artwork, sheen included.
- **Safe circle.** Doing the adaptive foreground export without
  `--export-area` (i.e. cropping to the book layer) would scale the book to the
  whole 108dp canvas and a circular launcher mask would clip its corners.
- **Transparent variant.** Hide the `Background` layer in Inkscape (or export
  with `--export-id=layer-book --export-id-only`) to get the mark alone.
