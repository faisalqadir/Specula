# Specula

**A native macOS alternative to RadiAnt DICOM Viewer.**

RadiAnt DICOM Viewer is a popular Windows app for viewing medical images (CT, MR, X-ray, ultrasound,
PET and more). On a Mac it only runs through Wine. Specula aims to give Mac users the same features
in a real Mac app: built in Swift with AppKit, SwiftUI and Metal, with native windows, toolbars,
trackpad gestures, dark mode and Apple silicon performance. No Wine and no emulation.

> [!WARNING]
> **Specula is new and largely untested. Use it at your own risk.**
> It has only been tried on synthetic test images and a local test server, never on real clinical
> data or a production PACS. It is not a certified medical device and must not be used for diagnosis
> or any clinical decision. Expect bugs, and double-check anything important in an established viewer.

Specula is an independent project. It is not affiliated with or endorsed by Medixant, the maker of
RadiAnt.

## Download

Get the DMG from the [latest release](../../releases/latest), open it and drag Specula to
Applications. Requires macOS 14 or later on Apple silicon.

The app is not notarized, so macOS blocks the first launch. Right-click Specula.app and choose
**Open**, or run:

```bash
xattr -dr com.apple.quarantine /Applications/Specula.app
```

## Features

* **Viewer:** open files, folders, ZIP archives (including password-protected) and CD/DVDs (DICOMDIR); series thumbnails; split screen and multiple windows; window/level presets; zoom, pan, rotate and flip; cine playback; series synchronization; cross-reference lines; DICOM tag browser; SR reports, PDFs and video.
* **Measurements:** length, angle, Cobb angle, ellipse, rectangle, polygon, freehand, arrow, text, ratios, volumes, calibration, SUV, time-intensity curves.
* **3D:** MPR (axial, coronal, sagittal, oblique; MIP/MinIP/average slabs), volume rendering with presets, cutting, snapshots, STL export and movies; PET-CT fusion; DSA subtraction.
* **Library:** a local study archive with search and keywords; export to JPEG, PNG, TIFF, BMP, DICOM and MP4; anonymizer with templates.
* **PACS:** search, download (C-MOVE / C-GET), send (C-STORE), and a listener for incoming studies.

## Known gaps versus RadiAnt

* HTJ2K images (transfer syntaxes 1.2.840.10008.1.2.4.201–203) do not decode yet.
* DSA "magic mask" is missing (manual mask selection and pixel shift work).
* Movie export is MP4 only (no WMV).
* PACS support has only been tested against pynetdicom, not a real archive (Orthanc, dcm4chee, vendor PACS).

## Prefer the original RadiAnt?

If you need RadiAnt itself, download it from the official site, [radiantviewer.com](https://www.radiantviewer.com),
and license it from Medixant. It is a Windows program, so on a Mac it runs through Wine, for example via
a Wine wrapper or a tool such as CrossOver or Whisky. This repository does not include or redistribute
RadiAnt.

## Build from source

Requires Xcode 16 or later (tested with Xcode 26.6, Swift 6.3).

```bash
./Tools/build_app.sh release
```

```bash
open build/Specula.app
```

`build_app.sh debug` builds a debug bundle with the automation hooks used for testing (`Tools/sp`).

| Path | Contents |
| --- | --- |
| `Sources/DICOMCore` | Tags, VRs, dictionary (from DCMTK `dicom.dic`), parser/writer, character sets, ZIP (incl. AES), pixel pipeline, codecs (JPEG baseline/extended/lossless, JPEG-LS, JPEG 2000, RLE, deflate), transcoder |
| `Sources/DICOMNet` | DICOM networking: C-ECHO, C-FIND, C-MOVE, C-GET, C-STORE and a storage listener |
| `Sources/SpeculaApp` | The app: viewer, measurements, MPR / 3D, library, PACS, export, anonymizer, settings |
| `Sources/speculatool` | CLI for tests: codec round-trips, reference comparisons, phantom generation, `net` (SCU/SCP) |

Test images are not committed. Generate the synthetic phantom studies with
`swift run speculatool phantom TestData` (the JPEG 2000 variant needs OpenJPEG's `opj_compress`,
e.g. `brew install openjpeg`).

## What has been tested

* Codec and parser self-tests (`speculatool roundtrip`) pass.
* 61 compressed/uncompressed reference image pairs from the pydicom test suite decode identically; only the two HTJ2K files fail.
* PACS on a local machine against pynetdicom 3.0.4: verify, search, retrieve and send all worked, and every transferred image was pixel-identical to its source.

How RadiAnt's feature set was worked out is in [docs/RE-FINDINGS.md](docs/RE-FINDINGS.md).

## License

MIT, see [LICENSE](LICENSE). The generated DICOM dictionary (`Sources/DICOMCore/DictionaryData.swift`)
comes from DCMTK and stays under its BSD-style license; see [docs/THIRD-PARTY.md](docs/THIRD-PARTY.md).
