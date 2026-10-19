# Retrolux

Retrolux is a fan project: a non-destructive photo manager and editor for macOS 14+ (Apple Silicon), inspired by the photo software of the Snow Leopard era. Its look and workflow are modelled on classic pro photo tools; all code, icons and presets are original work. English and German.

> Not affiliated with, endorsed by, or connected to Apple Inc. or any other company. All trademarks belong to their owners.

## Features
- **Library**: projects, folders, albums, smart albums, stacks, keywords, ratings, labels, flags; originals are never modified (checksummed on import), managed or referenced in place; vaults (incremental backup) and a library first-aid check.
- **Import**: files and folders, memory cards and cameras (ImageCaptureCore), Photos library, legacy libraries (`.aplibrary`, read-only); rename, metadata and adjustment presets, RAW+JPEG pairs, automatic project splitting, duplicate detection, post-import script.
- **Browser and viewer**: grid, list, filmstrip, split view, full screen with pointer-revealed toolbar and filmstrip, loupe, compare and multi-up layouts, hot/cold area overlay, soft proofing.
- **Adjustments**: RAW fine tuning, white balance, exposure, enhance, shadows & highlights, levels, curves, colour, vignette, sharpen, noise reduction, quick brushes, retouch, crop and straighten; Core Image based, with 16-bit float processing.
- **Export**: presets (editable), subfolder and file-name formats, colour profiles, watermark, print-lab sizes, web galleries and journals.
- **Documents**: books, light tables, slideshows (also to movie), web pages, print layouts.
- **Places and Faces**: map view with pins, GPS tracks, "My Places", face detection and naming (Apple's Vision framework, on device only).
- **Automation**: AppleScript dictionary, plug-in adapter (scripts), external editor round trip.

## Build and run
Requires Xcode 16+ / Swift 6 toolchain. Releases are built for Apple Silicon (arm64) only; an Intel (x86_64) build is currently not supported.

```bash
swift test                      # unit tests
./scripts/make_app.sh           # builds dist/Retrolux.app (release, ad-hoc signed, Sparkle embedded)
open dist/Retrolux.app
```

The library lives in `~/Pictures/Retrolux Library.retrolux` by default; use `--library <path>` for another one. Headless checks: `Retrolux --library /tmp/x.retrolux --selftest`.

## Install
Download the latest disk image (`.dmg`) from the [releases page](https://github.com/konzertblock/retrolux/releases). The app is **not signed with a Developer ID**, so macOS will warn on first launch: right-click the app, choose *Open*, and confirm (or run `xattr -dr com.apple.quarantine /Applications/Retrolux.app`). Updates are delivered with [Sparkle](https://sparkle-project.org) and verified with an EdDSA signature.

## Releasing (maintainers)
`./scripts/release.sh` builds the app, zips it and updates `docs/appcast.xml` (served through GitHub Pages). The EdDSA private key stays in the maintainer's keychain (account `retrolux`, created with Sparkle's `generate_keys --account retrolux`); the public key is set in `scripts/make_app.sh`.

## Image processing
Operations are Core Image approximations of classic photo-editing controls; ranges marked `approx` in the catalogue are estimates. Results are close to, but not identical with, other editors.

## Layout
- `Sources/RetroluxCore`: models, SQLite library, importer, render engine, exporter, operation catalogue.
- `Sources/Retrolux`: SwiftUI/AppKit interface, menus, self-test.
- `resources/`: app icon, AppleScript dictionary. `scripts/`: build and release scripts.

## Icon themes
Preferences ▸ Appearance ▸ Icon Theme: built-in drawn icons, or your own set (a folder with `theme.json` and PNGs; keys like `inspector`, `browser`, `folder`; missing icons fall back to the built-in set).

## License
GPL-3.0-or-later, see [LICENSE](LICENSE). Retrolux includes the [Sparkle](https://github.com/sparkle-project/Sparkle) update framework (MIT license).
