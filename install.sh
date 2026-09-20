#!/usr/bin/env bash
#
# install.sh - integrate sd-geotag for local CLI execution
#
# With no arguments, links sd-geotag.sh into the user's bin directory
# (~/.local/bin, the standard user-scope location on macOS and Linux) so
# the command "sd-geotag" works from anywhere. With --uninstall, removes
# the link. Nothing else on the system is touched: no dotfiles are edited,
# no root required.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$REPO_DIR/sd-geotag.sh"
BIN_DIR="${XDG_BIN_HOME:-$HOME/.local/bin}"
DEST="$BIN_DIR/sd-geotag"

info() {
  printf '%s\n' "$*"
}

usage() {
  cat <<'EOF'
install.sh - integrate sd-geotag for local CLI execution

Usage:
  ./install.sh             Link the "sd-geotag" command into ~/.local/bin
  ./install.sh --uninstall Remove the "sd-geotag" command

No-argument use of the installed command runs the full default workflow:
pick the newest .gpx in ~/Downloads, scan mounted removable volumes for
Fujifilm/Sony/Ricoh cards, and geotag their RAW files.
EOF
}

ensure_executable() {
  if [ ! -x "$SRC" ]; then
    chmod +x "$SRC"
  fi
}

path_contains() {
  case ":$PATH:" in
    *":$1:"*) return 0 ;;
    *) return 1 ;;
  esac
}

install_cmd() {
  ensure_executable
  mkdir -p "$BIN_DIR"
  if [ -e "$DEST" ] && [ ! -L "$DEST" ]; then
    info "⚠️  Replacing existing non-link file at $DEST"
  fi
  # -sfn is idempotent: re-running the installer refreshes the link in place.
  ln -sfn "$SRC" "$DEST"
  info "✅ Installed: $DEST -> $SRC"
  if ! path_contains "$BIN_DIR"; then
    info "ℹ️  $BIN_DIR is not on PATH. Add this to your shell profile:"
    info "       export PATH=\"\$HOME/.local/bin:\$PATH\""
  fi
  if ! command -v exiftool >/dev/null 2>&1; then
    info "⚠️  exiftool is not installed yet (geotagging needs it):"
    info "       brew install exiftool"
  fi
  info ""
  info "Try it:"
  info "  sd-geotag --version"
  info "  sd-geotag --dry-run"
  info "  sd-geotag"
}

uninstall_cmd() {
  if [ -L "$DEST" ] || [ -e "$DEST" ]; then
    rm -f "$DEST"
    info "✅ Removed: $DEST"
  else
    info "ℹ️  Nothing to remove at $DEST"
  fi
}

case "${1:-}" in
  "")
    install_cmd
    ;;
  --uninstall)
    uninstall_cmd
    ;;
  -h|--help)
    usage
    ;;
  *)
    info "Unknown argument: $1"
    usage >&2
    exit 64
    ;;
esac