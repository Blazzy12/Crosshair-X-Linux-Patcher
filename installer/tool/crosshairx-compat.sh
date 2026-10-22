#!/bin/sh
# Steam compatibility-tool entry point ("Crosshair X Linux (native)").
# Steam runs:  crosshairx-compat.sh <verb> <windows exe> [args...]
# Instead of starting the .exe under Proton we start the native Linux build.
TOOL=$(dirname "$(readlink -f "$0")")
verb="$1"
[ $# -gt 0 ] && shift

case "$verb" in
  getcompatpath|getnativepath)
    # No path translation needed; there is no Wine prefix.
    printf '%s\n' "$1"; exit 0 ;;
  run|waitforexitandrun) ;;
  *) exit 0 ;;
esac

# Only launch for Crosshair X itself. Steam also routes helper programs
# (e.g. iscriptevaluator.exe for redistributable installs) through the tool;
# those are Windows-only and not needed, so report success and skip them.
GAME_EXE=""
for a in "$@"; do
  case "$a" in
    *[Cc]rosshair[Xx].exe|*[Cc]rosshair[Xx].EXE) GAME_EXE="$a" ;;
  esac
done
[ -n "$GAME_EXE" ] || exit 0

exec "$TOOL/crosshairx-linux.sh" --game "$(dirname "$GAME_EXE")"
