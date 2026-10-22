#!/bin/sh
# Crosshair X (Linux) launcher: re-patches the Steam copy of Crosshair X when
# it has changed (Steam update or new patch version), then starts it.
#   crosshairx-linux.sh [--game <Crosshair X install dir>] [app args / crosshair-x:// URL]
TOOL=$(dirname "$(readlink -f "$0")")
ELECTRON="$TOOL/electron/crosshairx"

GAME_DIR=""
if [ "$1" = "--game" ]; then GAME_DIR="$2"; shift 2; fi
[ -z "$GAME_DIR" ] && [ -n "$STEAM_COMPAT_INSTALL_PATH" ] && GAME_DIR="$STEAM_COMPAT_INSTALL_PATH"
[ -z "$GAME_DIR" ] && [ -f "$TOOL/game-dir" ] && GAME_DIR=$(cat "$TOOL/game-dir")
if [ -z "$GAME_DIR" ] || [ ! -f "$GAME_DIR/resources/app.asar" ]; then
  FOUND=$(ELECTRON_RUN_AS_NODE=1 "$ELECTRON" "$TOOL/patcher/steamcfg.js" find-game "$TOOL/../.." 1366800 2>/dev/null) && GAME_DIR="$FOUND"
fi

notify() {
  command -v notify-send >/dev/null 2>&1 && notify-send -a "Crosshair X" -i "$TOOL/icon.png" "Crosshair X" "$1" 2>/dev/null
}
fail() {
  if command -v kdialog >/dev/null 2>&1; then kdialog --title "Crosshair X (Linux)" --error "$1" 2>/dev/null
  elif command -v zenity >/dev/null 2>&1; then zenity --error --title "Crosshair X (Linux)" --text "$1" 2>/dev/null
  else notify "$1"; fi
  echo "error: $1" >&2
}

if [ -n "$GAME_DIR" ] && [ -f "$GAME_DIR/resources/app.asar" ]; then
  printf '%s\n' "$GAME_DIR" > "$TOOL/game-dir"
  if ! ELECTRON_RUN_AS_NODE=1 "$ELECTRON" "$TOOL/patcher/patch.js" --game "$GAME_DIR" --runtime "$TOOL/electron" \
        --layer "$TOOL/layer" --steamworks "$TOOL/steamworks" --port-version "$(cat "$TOOL/VERSION")" --if-needed \
        > "$TOOL/patch.log" 2>&1; then
    if [ -f "$TOOL/electron/resources/app/package.json" ]; then
      notify "Couldn't update the Linux patch for the new Crosshair X version; starting the previous version. Details: $TOOL/patch.log"
    else
      fail "$(printf "Couldn't patch Crosshair X for Linux.\n\n%s\n\nLog: %s" "$(tail -n 3 "$TOOL/patch.log")" "$TOOL/patch.log")"
      exit 1
    fi
  elif grep -q '^patched' "$TOOL/patch.log"; then
    cp -f "$TOOL/electron/resources/resources/logo.png" "$TOOL/icon.png" 2>/dev/null
  fi
elif [ ! -f "$TOOL/electron/resources/app/package.json" ]; then
  fail "Crosshair X isn't installed. Install it from your Steam library first."
  exit 1
fi

# Steam's environment is meant for games: drop its overlay injection and
# runtime library paths, which don't belong in an Electron app.
unset LD_PRELOAD
case "$LD_LIBRARY_PATH" in *steam*|*Steam*) unset LD_LIBRARY_PATH ;; esac

# The overlay must be an X11 (XWayland) window: Wayland clients cannot keep
# themselves on top, position themselves, or ignore pointer input.
unset ELECTRON_OZONE_PLATFORM_HINT ELECTRON_RUN_AS_NODE
export GDK_BACKEND=x11
export CROSSHAIRX_LAUNCHER="$TOOL/crosshairx-linux.sh"

# Chromium's sandbox needs unprivileged user namespaces (or a setuid helper).
SANDBOX_FLAG=""
if [ "$(cat /proc/sys/kernel/unprivileged_userns_clone 2>/dev/null || echo 1)" = "0" ] \
   || [ "$(cat /proc/sys/kernel/apparmor_restrict_unprivileged_userns 2>/dev/null || echo 0)" = "1" ]; then
  [ -u "$TOOL/electron/chrome-sandbox" ] || SANDBOX_FLAG="--no-sandbox"
fi

# PipeWire/portal screen capture is disabled: it pops up the desktop's
# screen-share dialog (the app only wants display thumbnails).
exec "$ELECTRON" --ozone-platform=x11 --enable-transparent-visuals \
  --disable-features=WebRTCPipeWireCapturer $SANDBOX_FLAG "$@"
