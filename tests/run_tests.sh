#!/usr/bin/env bash
#
# Test suite for sd-geotag. Sources the main script for its helper
# functions and exercises the filesystem-driven logic (card classification,
# RAW collection, GPX selection) against throwaway fixtures.
#
# Run: ./tests/run_tests.sh

set -euo pipefail

cd "$(dirname "$0")/.."

# Sourcing the script must not execute main (guarded by BASH_SOURCE check).
# shellcheck source=../sd-geotag.sh
source ./sd-geotag.sh

PASS=0
FAIL=0

# check <test-name> <expected> <actual>
check() {
  local name="$1"
  local expected="$2"
  local actual="$3"
  if [ "$expected" = "$actual" ]; then
    PASS=$((PASS + 1))
    printf 'ok   %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL %s (expected %q, got %q)\n' "$name" "$expected" "$actual"
  fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- classify_volume ---------------------------------------------------------

mkdir -p "$TMP/fuji/DCIM/101FUJI"
check "classify fuji 101FUJI" "Fujifilm" "$(classify_volume "$TMP/fuji" || true)"

mkdir -p "$TMP/fuji-old/DCIM/100_FUJI"
check "classify old fuji 100_FUJI" "Fujifilm" "$(classify_volume "$TMP/fuji-old" || true)"

mkdir -p "$TMP/sony/DCIM/100MSDCF"
check "classify sony 100MSDCF" "Sony" "$(classify_volume "$TMP/sony" || true)"

mkdir -p "$TMP/sony-video/M4ROOT"
check "classify sony video M4ROOT" "Sony" "$(classify_volume "$TMP/sony-video" || true)"

mkdir -p "$TMP/ricoh/DCIM/100RICOH"
check "classify ricoh 100RICOH" "Ricoh" "$(classify_volume "$TMP/ricoh" || true)"

# A card from an unsupported brand must not be classified.
mkdir -p "$TMP/other/DCIM/100CANON"
check "classify unknown brand (CANON)" "" "$(classify_volume "$TMP/other" || true)"

# A volume without DCIM must not be classified.
mkdir -p "$TMP/nodcim/docs"
check "classify volume without DCIM" "" "$(classify_volume "$TMP/nodcim" || true)"

# --- collect_raw_files ---------------------------------------------------------

mkdir -p "$TMP/rawcard/DCIM/100MSDCF" "$TMP/rawcard/.Trashes/501" "$TMP/rawcard/DCIM/101MSDCF/sub"
: > "$TMP/rawcard/DCIM/100MSDCF/DSC001.ARW"
: > "$TMP/rawcard/DCIM/100MSDCF/DSC002.arw"
: > "$TMP/rawcard/DCIM/101MSDCF/sub/DSC003.RAF"
: > "$TMP/rawcard/DCIM/100MSDCF/DSC004.JPG"
: > "$TMP/rawcard/.Trashes/501/DSC005.ARW"
: > "$TMP/rawcard/DCIM/100MSDCF/GR006.DNG"

# Expect 4 files (two ARW variants, one RAF, one DNG), .JPG and .Trashes excluded.
# find order is unspecified; compare as counts and membership instead.
check "collect raws count" "4" "$(collect_raw_files "$TMP/rawcard" | wc -l | tr -d ' ')"
if collect_raw_files "$TMP/rawcard" | grep -q ".Trashes"; then
  check "collect raws excludes .Trashes" "no-trash" "found-trash"
else
  check "collect raws excludes .Trashes" "no-trash" "no-trash"
fi
if collect_raw_files "$TMP/rawcard" | grep -q "DSC004.JPG"; then
  check "collect raws skips JPG" "no-jpg" "found-jpg"
else
  check "collect raws skips JPG" "no-jpg" "no-jpg"
fi

# Empty card.
mkdir -p "$TMP/emptycard/DCIM/100MSDCF"
check "collect raws on empty card" "" "$(collect_raw_files "$TMP/emptycard" || true)"

# --- newest_gpx_in_downloads ---------------------------------------------------

mkdir -p "$TMP/gpxdir"
: > "$TMP/gpxdir/older.gpx"
: > "$TMP/gpxdir/newer.GPX"
touch -t 202601010000 "$TMP/gpxdir/older.gpx"
touch -t 202609200000 "$TMP/gpxdir/newer.GPX"
check "newest gpx selection" "$TMP/gpxdir/newer.GPX" "$(newest_gpx_in_downloads "$TMP/gpxdir")"

# No gpx files.
mkdir -p "$TMP/nogpx"
check "newest gpx when none" "" "$(newest_gpx_in_downloads "$TMP/nogpx" || true)"

# --- volume_field ---------------------------------------------------------------

check "volume_field Internal of /" "true" "$(volume_field "/" Internal)"
check "volume_field RemovableMedia of /" "false" "$(volume_field "/" RemovableMedia)"

# --- validate_gpx ----------------------------------------------------------------

printf '<?xml version="1.0"?>\n<gpx><trk><trkseg><trkpt lat="1" lon="2"><time>2026-01-01T00:00:00Z</time></trkpt></trkseg></trk></gpx>\n' > "$TMP/ok.gpx"
set +e
(validate_gpx "$TMP/ok.gpx")
check "validate_gpx accepts track" "0" "$?"

: > "$TMP/empty.gpx"
(validate_gpx "$TMP/empty.gpx" 2>/dev/null)
check "validate_gpx rejects empty gpx (exit 2)" "2" "$?"

(validate_gpx "$TMP/missing.gpx" 2>/dev/null)
check "validate_gpx rejects missing file (exit 2)" "2" "$?"
set -e

# --- require_exiftool --------------------------------------------------------------

# Force PATH without exiftool to check the install hint and exit code 1.
if command -v exiftool >/dev/null 2>&1; then
  set +e
  (PATH="/usr/bin:/bin" require_exiftool 2>/dev/null)
  rc="$?"
  set -e
  check "require_exiftool exits 1 without exiftool" "1" "$rc"
fi

printf '\n%s\n' "$([ "$FAIL" -eq 0 ] && echo "PASS: $PASS test(s), 0 failures" || echo "FAIL: $PASS passed, $FAIL failed")"
[ "$FAIL" -eq 0 ]