<p align="center">
  <img src="Resources/AppIcon.svg" width="128" alt="">
</p>

<h1 align="center">Copyisto Trimmer</h1>

<p align="center">
  Cut the music out of scanned notebooks, one box at a time.<br>
  <a href="https://github.com/copyisto/copyisto-trimmer/releases/latest/download/Copyisto-Trimmer.zip"><b>Download for macOS</b></a>
</p>

Open a folder of scans, draw boxes around the staves you want, and export every box as its own image.
It is built for the [Copyisto](https://copyisto.com) dataset of handwritten harmony exercises, but works on any folder of PNG or JPG pages.

## Download

1. Download [Copyisto-Trimmer.zip](https://github.com/copyisto/copyisto-trimmer/releases/latest/download/Copyisto-Trimmer.zip) from the latest release.
2. Unzip it and drag **Copyisto Trimmer** into Applications.

Requires macOS 26, on Apple silicon or Intel.

## Use

1. Open a folder of scans (⌘O) or drop it onto the window.
2. If a page is tilted, press **Wyprostuj automatycznie** (⌘L), or turn it by 0.1° with `[` and `]`.
3. Drag on a page to draw a box; drag a box to move it, or its handles to resize it.
4. Describe crops in the panel on the right (⌥⌘I): tags and a note for the selected box (⌘T, ⌘U), its page (⇧⌘T, ⇧⌘U) and the whole folder (⌃⌘T).
5. Press **Eksportuj** (⌘E).

Crops land in `copyisto-trims/` next to the scans, named `<page>_001.png`, `<page>_002.png`, …, at the scan's full resolution.
Crops of a turned page are cut from the turned page, so the staff lines in them come out level.
Boxes are saved as you go in `copyisto-trims.json`, so you can close the app and carry on later.
Every action is a toolbar button, with its shortcut in the tooltip.

Export PNG: the dataset wants lossless crops, and the app warns while JPG is selected.

## Tags and notes

In a tag field, Return or a comma adds a tag and Backspace in the empty field removes the last one.
Tags are lowercase with single spaces, 1 to 50 characters, exactly as the server stores them, and the field shows them that way as you type.
Suggestions come from the tags already used in the folder and from `.copyisto-tags.json`, which `copyisto raw pull` writes; the app only reads it.
A box shows the tags it inherits from its page and the folder, greyed out.
Its number on the page gets an icon when the box has its own tags or note, and turns into a warning when its crop would have more than 20 tags, which the CLI refuses.
A box note and its page note share a limit of 2000 characters, counted under each note.

The usual round trip with the [Copyisto CLI](https://github.com/copyisto/copyisto-ingestor):

```sh
copyisto raw pull M4K-V-01 ~/Trimmer/M4K-V-01
# Copyisto Trimmer: boxes, tags, notes, export (⌘E)
copyisto trims push ~/Trimmer/M4K-V-01
```

`copyisto-trims.json` is the only source of the crops' tags and notes; the website only shows them.

## Build

You need Xcode 26.

```sh
git clone git@github.com:copyisto/copyisto-trimmer.git
cd copyisto-trimmer
scripts/bundle.sh
open "build/Copyisto Trimmer.app"
```

`swift test` runs the tests, and `swift run` starts the app without bundling it (no icon, system fonts).

## Release

Push a tag and GitHub Actions builds, signs, notarises and publishes the app:

```sh
git tag v0.2.0
git push origin v0.2.0
```

Signing needs these repository secrets; without them the build is ad hoc signed and macOS will ask before opening it.

| Secret | What it is |
|---|---|
| `MACOS_CERTIFICATE` | The Developer ID Application certificate as a base64 `.p12` |
| `MACOS_CERTIFICATE_PASSWORD` | The `.p12` password |
| `NOTARY_KEY` | An App Store Connect API key as a base64 `.p8` |
| `NOTARY_KEY_ID` | That key's ID |
| `NOTARY_ISSUER_ID` | The App Store Connect issuer ID |

## How it works

`copyisto-trims.json` stores boxes in pixels of the original scan, like labelme:

```json
{
  "version": 3,
  "tags": ["zeszyt a5"],
  "images": {
    "4H8-E_001.png": {
      "width": 4960, "height": 7016,
      "rotation": -0.46,
      "tags": ["polifonia"],
      "note": "strona przekreślona",
      "boxes": [
        { "id": 1, "x": 120, "y": 840, "width": 4700, "height": 1300, "tags": ["monodia"], "note": "takt 3 nieczytelny" },
        { "id": 2, "x": 120, "y": 2300, "width": 4700, "height": 1300 }
      ]
    }
  }
}
```

`rotation` is in degrees clockwise about the page centre, and the boxes are in pixels of the turned page, which keeps the original size and has white in the uncovered corners.
Straightening finds the angle by projection profile, the deskew method of Leptonica and Tesseract: turned level, the staff lines fall into the fewest rows.
`tags` on the file apply to every crop, on an image to each crop from it, on a box to its crop only; `note` works the same on images and boxes.
Empty tags and notes are left out, as `rotation` is on a level page.
Every new field bumps `version`, because a build that does not know a field would drop it on save; older builds refuse newer files instead.
Boxes are numbered in the order they were drawn, and deleting one renumbers the rest, so label crops only once a page's boxes are final.
Each export rewrites the crops and removes its own crops whose box is gone; other files in `copyisto-trims/` are left alone.
The app has no dependencies beyond the macOS SDK and makes no network requests.

## Licence

[MIT](LICENSE).
The bundled fonts, [Young Serif](https://github.com/noirblancrouge/YoungSerif) and [Archivo](https://github.com/Omnibus-Type/Archivo), are under the SIL Open Font License (`Resources/Fonts/*-OFL.txt`).
