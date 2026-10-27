# RadiAnt DICOM Viewer 2026.1 — reverse-engineering ledger

Target: `RadiAntViewer.exe` (PE32+ x86-64, MFC, 5,172,744 bytes,
SHA-256 `fb4ae2f1c72dc5ba393bb7139107d0dc1e741a4ed10224b0d8c56a4cc3d0dbb3`),
installed by the Wine wrapper `/Applications/RadiAnt DICOM Viewer.app` into
`~/Library/Application Support/RadiAnt DICOM Viewer/prefix/drive_c/Program Files/RadiAntViewer64bit`.

Nothing from RadiAnt (code, icons, bitmaps, text) is copied into Specula. The
evidence below was used only to build a feature checklist and to match default
behaviour (presets, mouse bindings, overlay layout) in an independent
implementation.

## How the inventory was obtained

| Question | Method | Evidence |
|---|---|---|
| Wrapper layout | Read `Contents/MacOS/RadiAnt` (bash launcher: Wine prefix in App Support, silent NSIS install, `wine RadiAntViewer.exe`) | observed |
| Resource inventory | `inspect_pe_resources` — 206 resources: 40 dialogs, 70 bitmaps, cursors, icons, version, manifest; no RT_MENU / RT_STRING (menus and strings are built in code) | `ev_f3f46cf4…bd6999f88` |
| Complete English UI text | `languages/language_pl.xml` has `<s i=ID c=HASH>`; `HASH` = CRC32(UTF-8 English). Matched every hash against strings in the EXE: **949/949 recovered**. (The recovered table is RadiAnt's copyrighted text and is not published in this repository.) | observed + derived |
| English string table location | `.data` 0x403xxx holds `{int id; wchar* text}` pairs (e.g. id 1203 → "CT Abdomen") | observed |
| Built-in window presets | Ghidra decompile of `FUN_14019c730` (refs string ids 8003–8008) | `ev_5985453c…b3bfd43` |
| Transfer syntaxes | UIDs in `.rdata` | observed |
| Third-party libs | `license/credits.txt`: OpenJPEG, libjpeg (8/12/16-bit + lossless via jpeg1-4.dll), CharLS, Minizip, CrashRpt, Gladman AES/SHA; `gpuengine.dll` + `cudart64_101.dll` = CUDA volume renderer | observed |
| Settings model | `ProgramData/RadiAntViewer/options.xml`, `overlay.xml`, `AppData/Roaming/RadiantViewer/pacs.xml` (documented in-file) | observed |
| Local archive format | `Documents/RadiAntDB/RadiAnt.rdvdb` = SQLite (tables studies / series / images / keywords / keywordmap / delqueue / info) | observed |

## Built-in window presets (decompiled)

`FUN_14019b450(…, modality, key, shortName, longName, WL, WW, mode, …)`:

| Key | Name | WL | WW |
|---|---|---|---|
| 2 | CT Abdomen | 60 | 400 |
| 3 | CT Angio | 300 | 600 |
| 4 | CT Bone | 300 | 1500 |
| 5 | CT Brain | 40 | 80 |
| 6 | CT Chest | 40 | 400 |
| 7 | CT Lungs | −400 | 1500 |

Key 1 = default window (from file), 0 = full dynamic. Four other modality
groups get an unnamed ladder WL = x, WW = 2x for x ∈ {20, 40, 80, 160, 320,
640, 1280, 2560}; a high-bit-depth group gets x ∈ {30, 125, 500, 1875, 3750,
7500, 15000, 30000}; two functional groups (PET/NM) get min/max mode with
upper bound ∈ {0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0}. User presets
(options.xml `<window><presets>`) are appended.

## Transfer syntaxes supported by RadiAnt

1.2 implicit LE · 1.2.1 explicit LE · 1.2.1.99 deflate · 1.2.2 explicit BE ·
1.2.5 RLE · 4.50 JPEG baseline · 4.51 JPEG extended (12-bit) · 4.57 / 4.70
JPEG lossless · 4.80 / 4.81 JPEG-LS · 4.90 / 4.91 JPEG 2000 · 4.201–4.203
HTJ2K · 4.100–4.108 MPEG-2 / H.264 / HEVC video.

## Default behaviour worth matching (options.xml)

* Mouse: left = browse, middle = window, right = zoom, back = pan, forward = ROI; wheel = browse, horizontal wheel = change series.
* Endless scrolling on; sync slice + zoom/pan on, window sync off.
* Cine auto-runs for XA/US, default 10 fps.
* Measurement precision 2 decimals, automatic units.
* Corner overlay (overlay.xml): TL = image no., series no., lossy flag; TR = patient name, ID, birth/sex, institution, study ID, study desc., series desc., … ; BL = thickness/location, WL/WW, cursor/value, filter; BR = acquisition date/time; modality extensions for MR (TR/TE, field strength), CT (mA/kV), MG, XA.

## Feature checklist (from the recovered UI strings)

Viewer: open file / folder / ZIP (password-protected) / CD-DVD (DICOMDIR) ·
series preview bar · split screen (rows × cols) · multiple windows ·
browse / window / pan / zoom tools · presets 0–9 · negative · custom window
(WL/WW or min/max) · rotate 90/180, flip H/V · fill viewport / 1:1 ·
cine with FPS · sorting (instance, position, acquisition time, file name;
asc/desc) · split series · synchronization (slice, zoom/pan, window) ·
cross-reference lines · 3D cursor · hide patient data · font size ·
image filters (smooth / sharpen) · DICOM tag viewer (search, copy, save raw,
show file) · SR documents (HTML), encapsulated PDF, video.

Measurements: length, angle, Cobb angle, ellipse, rectangle, closed / open
polygon, pencil, arrow, text, deviation, length ratio, ellipsoid / bullet
volume, calibration (mm / inch / French), SUVbw, copy / paste / duplicate /
delete measurements, time-intensity curve.

Advanced: MPR (axial / coronal / sagittal, oblique axes, MIP / MinIP / Avg
thick slab), 3D volume rendering (presets: Angio, Airways, Bones B/W, Skin B/W,
Bones and skin 1–3, MIP B/W, MIP B/W inverse; scalpel cut inside/outside,
shading, 3D snapshots, STL export, quick movie 360°/180°), PET-CT fusion,
DSA subtraction (mask, manual / auto pixel-shift, magic mask).

Data: local archive (import copy / link, keywords, search, recently opened,
export to CSV), anonymizer with templates, export (JPEG / BMP / DICOM /
MP4 / WMV; image / series / study / patient; annotations full / anonymous /
none; size), copy to clipboard, print.

PACS: config (listener AE / port / filter, hosts AE / IP / port, transfer
syntaxes, charset, wildcards, timeout), C-ECHO verify, C-FIND study search with
date presets and saved search presets, C-MOVE / C-GET retrieve, download queue
with status, accept pushed studies (Storage SCP), send to PACS (C-STORE).

Not reproduced: licensing / activation / trial logic, update checker,
crash reporter, Windows firewall integration, add-on signature checks.

## PACS behaviour (strings 20000–23011, pacs.xml)

* pacs.xml: `<listener ae="RADIANT" port="11112" filter="2" llock="0">`, `<timeout>30`, `<hosts>`, `<presets>`,
  `<lastsearch dt mfid>`. `filter` indexes "Accept connections" (0 defined hosts, 1 local network,
  2 all IPs); `llock` is "Pause listener on session lock".
* Search fields: patient name / ID, accession, study description, referring / performing / reading
  physician, institution; 25 date presets (All dates … Custom date range); modality filter; one or all
  PACS locations; saved presets; "Find all studies of this patient"; show/hide series.
* Download targets: Download, Add to active window, Download to new window, Download to separate
  windows; "Import to local archive" toggle decides whether studies persist.
* Downloads list columns: patient (study date), progress, download time, bytes, current / average
  speed, downloaded / expected files, PACS location, error message; statuses Queued … Cancelled and the
  DIMSE failure texts (22022–22032).
* Advanced: maximum active downloads, preferred transfer syntax, accept all presentation contexts,
  retrieve protocol (C-MOVE / C-GET), proposed transfer syntaxes (All / Broadly supported / Implicit
  VR LE only), character set + force, wildcards (None / Leading / Trailing / Both), spaces → carets,
  non-ASCII → `?`, query timeout.

Specula differences: default AE title `SPECULA`; "Accept connections" defaults to local network
rather than all IPs, and adds a "This computer only" choice that binds the listener to loopback.

## Reconstruction status (2026-10-27)

Every item in the feature checklist above has an implementation in Specula except HTJ2K decoding,
the DSA "magic mask", and WMV export (MP4 instead). Codecs and PACS are verified against reference
implementations; the viewer, MPR/3D and measurement tools were checked by scripted UI runs on the
synthetic phantoms, not on clinical data. See the README for details.
