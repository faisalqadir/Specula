# Specula

A native macOS DICOM viewer modelled on the feature set of RadiAnt DICOM Viewer 2026.1 (a Windows app
that otherwise needs Wine on a Mac). Specula is an independent project, not affiliated with or endorsed by
Medixant, the maker of RadiAnt. Swift 6, AppKit + SwiftUI, Metal rendering. No Wine and
no third-party runtime libraries: the DICOM parser, codecs and network stack are written from scratch.

How the RadiAnt feature inventory was recovered is in [docs/RE-FINDINGS.md](docs/RE-FINDINGS.md).

## Build and run

```bash
./Tools/build_app.sh release
```

```bash
open build/Specula.app
```

Requires Xcode 16+ (tested with Xcode 26.6, Swift 6.3) on macOS 14 or later. `build_app.sh debug`
builds a debug bundle with the automation hooks used for testing (`Tools/sp`).

## Layout

| Path | Contents |
| --- | --- |
| `Sources/DICOMCore` | Tags, VRs, dictionary (from DCMTK `dicom.dic`), parser/writer, character sets, ZIP (incl. AES), pixel pipeline, codecs (JPEG baseline/extended/lossless, JPEG-LS, JPEG 2000, RLE, deflate), transcoder |
| `Sources/DICOMNet` | DICOM upper layer + DIMSE: C-ECHO, C-FIND, C-MOVE, C-GET, C-STORE (SCU) and a Storage/Verification SCP |
| `Sources/SpeculaApp` | The app: viewer, measurements, MPR / 3D, library, PACS, export, anonymizer, settings |
| `Sources/speculatool` | CLI for tests: codec round-trips, reference comparisons, phantom generation, `net` (SCU/SCP) |
| `TestData` | Not committed. Generate the synthetic phantom studies (CT, MR, PET, US, XA, CR, SR, one CT per transfer syntax) with `swift run speculatool phantom TestData` (the JPEG 2000 variant needs OpenJPEG's `opj_compress`, e.g. `brew install openjpeg`) |

## Verification

* `speculatool roundtrip`: codec and parser self-tests, all passing.
* `speculatool refcheck <pydicom test files>`: 61 compressed/uncompressed reference pairs decode identically; the only failures are the two HTJ2K files.
* PACS: tested on loopback against pynetdicom 3.0.4's Query/Retrieve SCP: C-ECHO, C-STORE (124 files across 6 transfer syntaxes), C-FIND, C-MOVE into Specula's listener (40/40), C-GET (84/84). Every received file decoded pixel-identical to its source. In the app: search → download into a new window, push into the listener → library import, and Send to PACS from the sheet (24/24).

## Download

A prebuilt app is attached to each [GitHub release](../../releases) as a DMG. It is ad-hoc signed, not notarized, so the first time macOS will refuse to open it: right-click Specula.app → Open, or run `xattr -dr com.apple.quarantine /Applications/Specula.app`.

Specula is not a certified medical device and must not be used for diagnosis.

## Known gaps versus RadiAnt

* HTJ2K (transfer syntaxes 1.2.840.10008.1.2.4.201–203) does not decode yet.
* DSA "magic mask" is missing (manual mask selection and pixel shift are there).
* Movie export is MP4 only (no WMV).
* PACS has only been tested against pynetdicom, not a production archive (Orthanc, dcm4chee, vendor PACS).
* Licensing, update checks, crash reporting and Windows-firewall handling are intentionally not reproduced.
