#!/usr/bin/env bash
#
# sd-geotag - geotag RAW photos on camera SD cards from GPX track logs
#
# Scans ~/Downloads for GPX track files, finds currently mounted removable
# volumes that look like Fujifilm, Sony, or Ricoh camera cards (detected by
# folder structure, not volume name), collects the RAW files (ARW/RAF/DNG)
# on each card, and writes GPS EXIF metadata into the RAWs with
# "exiftool -geotag", matching photos to track points by timestamp.
#
# Requires macOS, bash 3.2+, diskutil/plutil (standard macOS tools), and
# exiftool (note the exact command name: "exiftool", not "xftool").
# Homebrew install: brew install exiftool

set -euo pipefail

readonly PROGNAME="sd-geotag"
readonly VERSION="0.1.0"

# --- Camera brand fingerprints ---------------------------------------------
# Detection is based on vendor directory conventions inside DCIM/, checked
# case-insensitively. Both upper- and lower-case patterns are listed because
# the card filesystem may be case-sensitive (ExFAT is case-preserving and
# cameras write upper-case, but HFS+ cards could hold either).
#
#   Fujifilm: DCIM/100FUJI, DCIM/101FUJI, ...  (older FinePix: 100_FUJI)
#   Sony:     DCIM/100MSDCF, DCIM/101MSDCF, ... plus PRIVATE/ and M4ROOT/
#   Ricoh:    DCIM/100RICOH, ... (Theta, GR series)
readonly FUJI_DCIM_PATTERNS=('1??FUJI' '1??_FUJI' '1??fuji' '1??_fuji')
readonly SONY_DCIM_PATTERNS=('1??MSDCF' '1??msdcf')
readonly SONY_VIDEO_DIRS=('PRIVATE/AVCHD' 'PRIVATE/XAVCS' 'M4ROOT')
readonly RICOH_DCIM_PATTERNS=('1??RICOH' '1??ricoh')

# RAW extensions written by the supported camera brands.
readonly RAW_EXTENSIONS=('arw' 'raf' 'dng')

readonly GPX_DOWNLOADS_DIR="${HOME}/Downloads"

# --- Globals set by option parsing -----------------------------------------
DRY_RUN=false
VERBOSE=false
SHOW_HELP=false
GEOSYNC=""
GPX_FILE=""
FORCED_VOLUME=""

# Counters used for the final summary.
GEOTAGGED_COUNT=0
FAILURE_COUNT=0

log() {
  printf '%s\n' "$*"
}

info() {
  # Verbose-only log line; "|| true" keeps "set -e" happy when VERBOSE is off.
  [ "$VERBOSE" = true ] && printf '[info] %s\n' "$*" || true
}

err() {
  printf '%s: %s\n' "$PROGNAME" "$*" >&2
}

# die <exit-code> <message>
die() {
  local code="$1"
  shift
  err "$*"
  exit "$code"
}

usage() {
  cat <<'EOF'
sd-geotag - geotag RAW photos on camera SD cards from GPX track logs

Scans your Downloads folder for GPX files, finds mounted removable volumes
that look like Fujifilm, Sony, or Ricoh camera cards (detected by folder
structure, not volume name), and geotags the RAW files (ARW/RAF/DNG) on
them using exiftool -geotag.

Usage:
  sd-geotag.sh [options]

Options:
  -h, --help          Show this help and exit.
      --version       Print version and exit.
      --dry-run       Preview only. No file is modified; the output shows
                      which files would be geotagged.
      --gpx FILE      Use this GPX track file instead of the newest
                      .gpx found in ~/Downloads.
      --geosync VAL   Pass a time offset to exiftool (-geosync) to correct
                      clock drift between the camera and the GPS device,
                      e.g. --geosync=+9:00 for a camera running 9 hours
                      behind the GPS clock.
      --drive NAME    Skip card detection and target this volume directly.
                      Accepts a volume name ("Untitled") or a full mount
                      point (/Volumes/Untitled). RAW files are geotagged
                      even if the volume does not look like a camera card.
  -v, --verbose       More output, including the exact exiftool commands.

Exit codes:
  0    Success (even if some files were skipped; check the output)
  1    exiftool is missing or broken
  2    No usable GPX file (none in ~/Downloads, or --gpx file missing/empty)
  3    Volume given with --drive was not found
  4    No camera card detected
  5    exiftool failed on at least one volume
  64   Bad usage (unknown option or argument)

Examples:
  sd-geotag.sh --dry-run
  sd-geotag.sh
  sd-geotag.sh --gpx ~/Downloads/2026-09-20.gpx --geosync=+9:00
  sd-geotag.sh --drive Untitled
EOF
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help)
        SHOW_HELP=true
        return 0
        ;;
      --dry-run)
        DRY_RUN=true
        ;;
      -v|--verbose)
        VERBOSE=true
        ;;
      --version)
        printf '%s %s\n' "$PROGNAME" "$VERSION"
        exit 0
        ;;
      --gpx)
        [ $# -ge 2 ] || die 64 "Option $1 requires a file path argument."
        GPX_FILE="$2"
        shift
        ;;
      --gpx=*)
        GPX_FILE="${1#*=}"
        ;;
      --geosync)
        [ $# -ge 2 ] || die 64 "Option $1 requires a value (e.g. --geosync=+9:00)."
        GEOSYNC="$2"
        shift
        ;;
      --geosync=*)
        GEOSYNC="${1#*=}"
        ;;
      --drive)
        [ $# -ge 2 ] || die 64 "Option $1 requires a volume name or mount point."
        FORCED_VOLUME="$2"
        shift
        ;;
      --drive=*)
        FORCED_VOLUME="${1#*=}"
        ;;
      --)
        shift
        break
        ;;
      -*)
        err "Unknown option: $1"
        err "Run '$PROGNAME --help' for usage."
        exit 64
        ;;
      *)
        err "Unexpected argument: $1"
        err "Run '$PROGNAME --help' for usage."
        exit 64
        ;;
    esac
    shift
  done
}

validate_geosync() {
  # Accept exiftool -geosync formats: a time offset like "+9:00" or "-0:30",
  # or an absolute datetime like "2026:09:20 12:00:00+09:00". Loose check;
  # exiftool gives a precise error for anything else.
  [ -n "$GEOSYNC" ] || return 0
  case "$GEOSYNC" in
    +*|-*|[0-9]*)
      ;;
    *)
      die 64 "Invalid --geosync value: '$GEOSYNC' (examples: +9:00, -0:30, or 2026:09:20 12:00:00+09:00)."
      ;;
  esac
}

# Verify exiftool exists before touching anything. The exact command name is
# "exiftool"; it is occasionally mistyped as "xftool", which is not a tool.
require_exiftool() {
  if ! command -v exiftool >/dev/null 2>&1; then
    err "exiftool is not installed or not in PATH (no command named 'exiftool')."
    err "sd-geotag needs ExifTool to read and write GPS EXIF metadata."
    err "Install it with Homebrew:"
    err "    brew install exiftool"
    err "Other installation options: https://exiftool.org"
    exit 1
  fi
  if ! exiftool -ver >/dev/null 2>&1; then
    die 1 "Found a command named 'exiftool' but it failed to run ('exiftool -ver' exited nonzero)."
  fi
}

# volume_field <mount-point> <plist-key>
# Print a field from "diskutil info -plist" as raw text (true/false/string).
# A temp file is used because "plutil -extract" wants a file argument; this
# avoids depending on newer plutil stdin behaviors across macOS versions.
volume_field() {
  local volume="$1"
  local key="$2"
  local tmp
  local value=""
  tmp="$(mktemp)"
  if diskutil info -plist "$volume" >"$tmp" 2>/dev/null; then
    value="$(plutil -extract "$key" raw -o - "$tmp" 2>/dev/null || true)"
  fi
  rm -f "$tmp"
  printf '%s' "$value"
}

# Print mount points of currently mounted removable volumes. Internal disks
# (Macintosh HD, Recovery) are excluded because diskutil reports
# RemovableMedia=false for them. Brand identification happens later; this
# only narrows the candidate list.
list_removable_volumes() {
  local vol
  local removable
  for vol in /Volumes/*; do
    [ -d "$vol" ] || continue
    removable="$(volume_field "$vol" RemovableMedia)"
    if [ "$removable" = "true" ]; then
      printf '%s\n' "$vol"
    fi
  done
  return 0
}

# classify_volume <mount-point>
# Print the camera brand if the volume matches a known folder layout,
# otherwise return nonzero. Volume names are ignored on purpose: Sony cards
# commonly mount as "Untitled", and generic names collide with flash drives.
classify_volume() {
  local vol="$1"
  local pat
  # DCIM-based patterns first: they are the strongest photo-card signals.
  for pat in "${FUJI_DCIM_PATTERNS[@]}"; do
    if [ -n "$(compgen -G "$vol/DCIM/$pat")" ]; then
      printf 'Fujifilm\n'
      return 0
    fi
  done
  for pat in "${SONY_DCIM_PATTERNS[@]}"; do
    if [ -n "$(compgen -G "$vol/DCIM/$pat")" ]; then
      printf 'Sony\n'
      return 0
    fi
  done
  for pat in "${RICOH_DCIM_PATTERNS[@]}"; do
    if [ -n "$(compgen -G "$vol/DCIM/$pat")" ]; then
      printf 'Ricoh\n'
      return 0
    fi
  done
  # Sony video-only cards (no still-photo MSDCF folder) still carry the
  # brand markers. They rarely contain RAWs, but classifying them gives
  # the user useful feedback instead of an "unknown volume" line.
  for d in "${SONY_VIDEO_DIRS[@]}"; do
    if [ -d "$vol/$d" ]; then
      printf 'Sony\n'
      return 0
    fi
  done
  return 1
}

# newest_gpx_in_downloads <dir>
# Print the newest .gpx file in the directory (by mtime), or nothing.
# Uses find -print0 so filenames with spaces are safe; bash 3.2 has no
# mapfile, so the read loop tracks the newest file manually.
newest_gpx_in_downloads() {
  local dir="$1"
  local best=""
  local best_ts=""
  local f
  local ts
  while IFS= read -r -d '' f; do
    ts="$(stat -f '%m' "$f")"
    if [ -z "$best" ] || [ "$ts" -gt "$best_ts" ]; then
      best="$f"
      best_ts="$ts"
    fi
  done < <(find "$dir" -maxdepth 1 -type f -iname '*.gpx' -print0 2>/dev/null)
  printf '%s' "$best"
}

validate_gpx() {
  local gpx="$1"
  if [ ! -f "$gpx" ]; then
    die 2 "GPX file not found: $gpx"
  fi
  # A GPX with no trkpt/wpt/rtept cannot match anything; exiftool would
  # fail later with a less obvious message.
  if ! grep -q -e '<trkpt' -e '<wpt' -e '<rtept' "$gpx"; then
    die 2 "GPX file contains no track points: $gpx"
  fi
}

# collect_raw_files <mount-point>
# Print newline-separated RAW file paths on the volume. Descends a few
# levels to cover DCIM/<subdir>/<file> and card-specific extra folders.
# Skips macOS .Trashes so deleted photos are not geotagged.
collect_raw_files() {
  local vol="$1"
  local files=()
  local f
  local find_args=()
  local ext
  local first=true
  # Build the find expression from RAW_EXTENSIONS so the supported
  # extensions live in exactly one place: ( -iname '*.arw' -o ... ).
  for ext in "${RAW_EXTENSIONS[@]}"; do
    if [ "$first" = true ]; then
      find_args+=(\( -iname "*.${ext}")
      first=false
    else
      find_args+=(-o -iname "*.${ext}")
    fi
  done
  find_args+=(\))
  while IFS= read -r -d '' f; do
    files+=("$f")
  done < <(
    find "$vol" -maxdepth 4 -type f "${find_args[@]}" \
      -not -path '*/.Trashes/*' -print0 2>/dev/null
  )
  if [ "${#files[@]}" -eq 0 ]; then
    return 1
  fi
  printf '%s\n' "${files[@]}"
}

# base_exiftool_cmd
# Print the shared exiftool arguments (track file, sync offset) so the
# dry-run and real-run paths stay in sync. -P preserves the file mod time.
base_exiftool_cmd() {
  local cmd=(exiftool -geotag "$GPX_FILE" -P)
  if [ -n "$GEOSYNC" ]; then
    cmd+=(-geosync "$GEOSYNC")
  fi
  printf '%s\n' "${cmd[@]}"
}

# dry_run_geotag <raw file>...
# Preview the geotag run without modifying any file. exiftool only writes
# when it is told to, and the natural no-touch trick is "-o DEST": the
# geotagged result goes to DEST instead of the original. "-o /dev/null"
# keeps the preview free of disk I/O, but some exiftool builds reject it
# because the output path exists ("Output file already exists"). Probe it
# once with the first file; if the probe fails, fall back to writing the
# preview output to temporary files, one per input, then delete them.
dry_run_geotag() {
  local base_cmd=()
  local line
  local out
  local rc=0
  while IFS= read -r line; do
    base_cmd+=("$line")
  done < <(base_exiftool_cmd)

  info "  Command: ${base_cmd[*]} -o /dev/null <files>"
  if "${base_cmd[@]}" -o /dev/null "$1" >/dev/null 2>&1; then
    out="$("${base_cmd[@]}" -o /dev/null "$@" 2>&1)" || rc=$?
    printf '%s\n' "$out"
    return "$rc"
  fi

  info "  Command: ${base_cmd[*]} -o <temp-dir>/<file> <file> (per file)"
  info "  exiftool rejected '-o /dev/null' on this build; previewing via temp files."
  local tmpdir
  local dst
  tmpdir="$(mktemp -d)"
  local f
  for f in "$@"; do
    dst="$tmpdir/$(basename "$f").geotag-preview"
    if out="$("${base_cmd[@]}" -o "$dst" "$f" 2>&1)"; then
      printf '%s\n' "$out"
    else
      printf '%s\n' "$out" >&2
      rc=1
    fi
    rm -f "$dst"
  done
  rm -rf "$tmpdir"
  return "$rc"
}

# geotag_volume <mount-point> <brand>
# Run exiftool -geotag against every RAW file on one volume.
# Real run: -overwrite_original writes GPS tags in place (no .original
# backups left behind).
geotag_volume() {
  local vol="$1"
  local brand="$2"
  local raws=()
  local f
  local out
  local rc=0
  local n
  local cmd

  while IFS= read -r f; do
    raws+=("$f")
  done < <(collect_raw_files "$vol" || true)

  if [ "${#raws[@]}" -eq 0 ]; then
    log "  No RAW files (ARW/RAF/DNG) found on this card."
    return 0
  fi

  info "  RAW files: ${#raws[@]}"

  if [ "$DRY_RUN" = true ]; then
    log "  Dry run (no files will be modified):"
    # shellcheck disable=SC2312
    out="$(dry_run_geotag "${raws[@]}" 2>&1)" || rc=$?
    printf '%s\n' "$out"
  else
    cmd=(exiftool -geotag "$GPX_FILE" -P)
    if [ -n "$GEOSYNC" ]; then
      cmd+=(-geosync "$GEOSYNC")
    fi
    cmd+=(-overwrite_original)
    if [ "$VERBOSE" = true ]; then
      cmd+=(-v2)
    fi
    cmd+=("${raws[@]}")
    info "  Command: ${cmd[*]}"
    out="$("${cmd[@]}" 2>&1)" || rc=$?
    printf '%s\n' "$out"
  fi

  if [ "$rc" -ne 0 ]; then
    err "exiftool reported errors for $vol (exit $rc); see output above."
    FAILURE_COUNT=$((FAILURE_COUNT + 1))
    return 0
  fi

  # Sum exiftool's footer lines ("N image files updated", or "... created"
  # in dry-run mode) into a single total for the summary.
  n="$(printf '%s\n' "$out" | awk '/[0-9]+ image files (updated|created)/ { s+=$1 } END { print s + 0 }')"
  GEOTAGGED_COUNT=$((GEOTAGGED_COUNT + n))
  return 0
}

main() {
  parse_args "$@"
  # --help/--version must work even when exiftool is missing.
  if [ "$SHOW_HELP" = true ]; then
    usage
    exit 0
  fi
  validate_geosync
  require_exiftool

  # --- Locate the GPX track log -------------------------------------------
  if [ -z "$GPX_FILE" ]; then
    GPX_FILE="$(newest_gpx_in_downloads "$GPX_DOWNLOADS_DIR")"
    if [ -z "$GPX_FILE" ]; then
      die 2 "No .gpx files found in $GPX_DOWNLOADS_DIR. Use --gpx FILE to point at a track log."
    fi
  fi
  validate_gpx "$GPX_FILE"
  log "GPX track: $GPX_FILE"

  # --- Find candidate volumes ----------------------------------------------
  # With --drive the user takes responsibility for the volume; otherwise
  # only removable volumes are candidates and brand folders must match.
  local vol
  local brand
  local -a card_vols=()
  local -a card_brands=()
  local scanned=""

  if [ -n "$FORCED_VOLUME" ]; then
    # Allow both "Untitled" and "/Volumes/Untitled".
    case "$FORCED_VOLUME" in
      /*) ;;
      *) FORCED_VOLUME="/Volumes/$FORCED_VOLUME" ;;
    esac
    if [ ! -d "$FORCED_VOLUME" ]; then
      die 3 "Volume not found or not mounted: $FORCED_VOLUME"
    fi
    card_vols+=("$FORCED_VOLUME")
    card_brands+=("forced")
  else
    while IFS= read -r vol; do
      scanned="$scanned$(printf '  - %s\n' "$vol")"
      if brand="$(classify_volume "$vol" || true)" && [ -n "$brand" ]; then
        card_vols+=("$vol")
        card_brands+=("$brand")
      else
        info "  Not a recognized camera card: $vol"
      fi
    done < <(list_removable_volumes)
  fi

  if [ "${#card_vols[@]}" -eq 0 ]; then
    err "No camera SD cards detected among mounted removable volumes."
    err "Volumes scanned:"
    err "$scanned"
    err "Detection looks for Fujifilm (DCIM/1xxFUJI), Sony (DCIM/1xxMSDCF,"
    err "PRIVATE/AVCHD, M4ROOT), or Ricoh (DCIM/1xxRICOH) folder layouts."
    err "To process another volume anyway, use: --drive <volume>"
    exit 4
  fi

  # --- Geotag each card ------------------------------------------------------
  local idx
  local total="${#card_vols[@]}"
  for ((idx = 0; idx < total; idx++)); do
    vol="${card_vols[$idx]}"
    brand="${card_brands[$idx]}"
    log ""
    log "Card: $vol ($brand)"
    if [ "$DRY_RUN" = true ]; then
      log "(dry run: nothing will be written)"
    fi
    geotag_volume "$vol" "$brand"
  done

  # --- Summary ---------------------------------------------------------------
  log ""
  if [ "$DRY_RUN" = true ]; then
    if [ "$GEOTAGGED_COUNT" -gt 0 ]; then
      log "Dry run complete. $GEOTAGGED_COUNT file(s) would be geotagged."
      log "Run without --dry-run to write the GPS data."
    else
      log "Dry run complete. No files would be geotagged."
      log "Most common cause: photo timestamps fall outside the GPX track time"
      log "range, usually because the camera clock differs from the GPS clock."
      log "Retry with an offset, e.g.: $PROGNAME --geosync=+9:00"
      log "(see README.md, 'Timezones and clock sync')."
    fi
  elif [ "$GEOTAGGED_COUNT" -eq 0 ] && [ "$FAILURE_COUNT" -eq 0 ]; then
    log "No files were geotagged."
    log "Most common cause: photo timestamps fall outside the GPX track time"
    log "range, usually because the camera clock differs from the GPS clock."
    log "Retry with an offset, e.g.: $PROGNAME --geosync=+9:00"
    log "(see README.md, 'Timezones and clock sync')."
  else
    log "Done. Geotagged $GEOTAGGED_COUNT file(s)."
  fi

  if [ "$FAILURE_COUNT" -gt 0 ]; then
    exit 5
  fi
}

# Allow tests to source this file for the helper functions.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi