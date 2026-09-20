# sd-geotag design

Date: 2026-09-20
Status: approved (repo name, license, and timezone strategy confirmed by user)

## Purpose

Write GPS EXIF metadata into RAW photos (Sony ARW, Fujifilm RAF, Ricoh DNG)
that live on a camera SD card mounted in macOS, using GPX track logs from
`~/Downloads` and `exiftool -geotag` for timestamp-based matching.

## Decisions

### Card detection: diskutil enumeration + folder-structure classification (hybrid)

Options considered:

1. Volume-name heuristics. Rejected: Sony cards mount as "Untitled" and
   names collide with ordinary flash drives.
2. `diskutil`/`system_profiler` querying. `diskutil info -plist` is good for
   filtering (RemovableMedia=true) but carries no brand information;
   `system_profiler` parsing is slow and brittle. Used only for filtering.
3. Brand folder-structure detection. Stable vendor conventions, trivially
   extensible, works with "Untitled" volume names.

Chosen: enumerate `/Volumes/*`, keep volumes where
`diskutil info -plist` reports `RemovableMedia=true`, then classify by
folder structure: Fujifilm `DCIM/1xxFUJI` (and `1xx_FUJI`), Sony
`DCIM/1xxMSDCF` plus `PRIVATE/AVCHD`/`PRIVATE/XAVCS`/`M4ROOT` markers for
video-only cards, Ricoh `DCIM/1xxRICOH`. Patterns checked both cases.
Multiple matching cards are each processed. `--drive` bypasses detection.

### Timestamp matching: exiftool built-in (no custom matcher)

Options considered:

1. `exiftool -geotag` with `-geosync` offsets. Built-in track interpolation,
   maintained upstream, one flag to correct clock drift.
2. Custom bash matcher (parse GPX, nearest-timestamp, write tags directly).
   Re-implements interpolation, shell XML parsing is fragile.

Chosen: `exiftool -geotag`. The script validates the GPX has track points,
picks the newest GPX in `~/Downloads` by default (`--gpx` to override),
preserves mod times (`-P`), and passes `--geosync` through.

### Timezone strategy: no offset by default, report unmatched

exiftool assumes GPX times are UTC and photo `DateTimeOriginal` is
camera-local. Default run assumes the camera clock matches the Mac time
zone. When nothing is geotagged, the script prints the likely cause and the
exact retry command (`--geosync=+HH:MM`). Alternatives (always require the
offset, interactive prompt) add friction for the common synced-clock case.

### Dry-run strategy

Real run: `exiftool -overwrite_original -P`. Dry run: `-o DEST` keeps the
originals untouched; `-o /dev/null` is probed once and used when the
exiftool build accepts it, otherwise preview output is written to per-file
temp files and deleted. This avoids the backup-file side effect of running
without `-overwrite_original`.

## Layout

- `sd-geotag.sh`: single bash 3.2-compatible script, sourceable for tests
- `tests/run_tests.sh`: fixture-based tests for classification, RAW
  collection, GPX selection, validation, and the exiftool dependency gate
- `README.md`, `LICENSE` (MIT), `.gitignore`

## Error handling

`set -euo pipefail`, exit codes 1 (exiftool missing), 2 (no GPX), 3
(volume not found), 4 (no card detected), 5 (exiftool failure), 64 (bad
usage). Missing exiftool prints `brew install exiftool`. Exiftool output is
shown verbatim so per-file warnings stay visible.

## Explicitly out of scope

- Copying photos off the card
- Video file geotagging
- JPEG sidecars
- Non-macOS platforms