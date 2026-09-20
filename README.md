# sd-geotag

Geotag RAW photos on Fujifilm, Sony, and Ricoh camera SD cards from GPX track logs.

You record a GPX track while shooting (phone or watch GPS logger, camera GPS
app, anything that writes GPX). Later, drop the GPX in `~/Downloads`, plug
the camera SD card into the Mac, and run this script. It finds the camera
card, collects the RAW files on it, and writes GPS latitude, longitude,
altitude, and timestamps into the EXIF metadata of each photo, matched by
photo time against the GPX track.

Supported RAW formats: Sony ARW, Fujifilm RAF, Ricoh DNG.

## Why folder-structure detection

Camera cards cannot be identified by volume name. Sony cards commonly mount
as `Untitled`, Fujifilm cards as whatever the user last named them, and any
of those names collide with ordinary USB flash drives. Instead, this script
recognizes the directory layouts each vendor's cameras create:

| Brand    | Card layout recognized                                                     |
| -------- | -------------------------------------------------------------------------- |
| Fujifilm | `DCIM/1xxFUJI` (also older `DCIM/1xx_FUJI`, e.g. `100FUJI`, `100_FUJI`)     |
| Sony     | `DCIM/1xxMSDCF`, plus `PRIVATE/AVCHD`, `PRIVATE/XAVCS`, or `M4ROOT`         |
| Ricoh    | `DCIM/1xxRICOH` (Theta, GR series)                                         |

Candidate volumes come from `diskutil info -plist`: only mounted volumes
that macOS reports as removable are considered, which excludes the internal
disk and recovery partitions. Unrecognized removable volumes are ignored.

## Prerequisites

- macOS (uses `diskutil`, `plutil`, `stat`, GNU bash 3.2+ as shipped)
- [ExifTool](https://exiftool.org) — the command name is exactly `exiftool`

Install ExifTool with Homebrew:

```console
$ brew install exiftool
```

Verify with `exiftool -ver`.

## Installation

```console
$ git clone <repo-url> && cd sd-geotag
$ chmod +x sd-geotag.sh
$ ./sd-geotag.sh --help
```

## Usage

```console
$ ./sd-geotag.sh [options]
```

| Option            | Effect                                                                                         |
| ----------------- | ---------------------------------------------------------------------------------------------- |
| `--help`          | Show usage and exit                                                                             |
| `--version`       | Print version and exit                                                                          |
| `--dry-run`       | Preview only: no file is modified; output shows which files would be geotagged                  |
| `--gpx FILE`      | Use this GPX file instead of the newest `.gpx` in `~/Downloads`                                 |
| `--geosync VAL`   | Correct camera-vs-GPS clock drift (passed to exiftool `-geosync`), e.g. `+9:00`                 |
| `--drive NAME`    | Skip detection and process this volume directly (name or `/Volumes/...` mount point)            |
| `--verbose`       | More output, including the exact exiftool commands                                              |

The script never copies or moves photos. It edits EXIF metadata in place on
the card. Keep backups, and always try `--dry-run` first.

## Examples

Preview what would happen (nothing is modified):

```console
$ ./sd-geotag.sh --dry-run
GPX track: /Users/you/Downloads/19-Sep-2026-1923.gpx

Card: /Volumes/Untitled (Sony)
(dry run: nothing will be written)
  Dry run (no files will be modified):
    1 image files created
    1 image files created

Dry run complete. 2 file(s) would be geotagged.
Run without --dry-run to write the GPS data.
```

Geotag for real, using the newest GPX in `~/Downloads`:

```console
$ ./sd-geotag.sh
```

Explicit track file and clock offset:

```console
$ ./sd-geotag.sh --gpx ~/Downloads/2026-09-20.gpx --geosync=+9:00
```

Process a specific volume, camera card or not:

```console
$ ./sd-geotag.sh --drive Untitled
```

## Timezones and clock sync

ExifTool reads GPX timestamps as UTC and photo `DateTimeOriginal` as
camera-local time. When the camera clock matches the Mac's time zone, no
offset is needed and plain `./sd-geotag.sh` works.

When the camera clock runs ahead of or behind the GPS device, matching
fails and the photos are reported as untagged. Common causes: the camera
was never set to local time, or you traveled. Fix it by re-running with
`--geosync=±HH:MM`:

```console
$ ./sd-geotag.sh --geosync=+9:00
```

`+9:00` tells exiftool the GPS clock reads 9 hours ahead of the camera
clock. If you are unsure of the offset, take a photo right next to the GPS
device, note the GPS timestamp of that moment in the GPX track, and compute
the difference between the two. The script also prints this hint whenever
a run geotags nothing.

## Exit codes

| Code | Meaning                                              |
| ---- | ---------------------------------------------------- |
| 0    | Success (check output for skipped files)             |
| 1    | exiftool missing or broken                           |
| 2    | No usable GPX file                                   |
| 3    | `--drive` volume not found or not mounted            |
| 4    | No camera card detected                              |
| 5    | exiftool failed on at least one volume               |
| 64   | Bad usage (unknown option or argument)               |

## Development

Run the test suite (works without a card or exiftool installed):

```console
$ ./tests/run_tests.sh
```

Lint with ShellCheck if you have it (`brew install shellcheck`):

```console
$ shellcheck sd-geotag.sh tests/run_tests.sh
```

## Limitations

- Position between GPX points is interpolated by exiftool; a photo taken
  outside the track's time range stays untagged on purpose.
- Video-only cards (Sony `M4ROOT`/`PRIVATE` layouts) are classified as
  Sony but contain no RAW files, so nothing is written.
- macOS only.

## License

MIT. See [LICENSE](LICENSE).