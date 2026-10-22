#!/usr/bin/env bash
# Crosshair X for Linux: installer / Steam patcher.
#
# Installs a Steam compatibility tool, "Crosshair X Linux (native)", that runs
# your Steam copy of Crosshair X natively on Linux instead of under Proton.
# Nothing from Crosshair X is included here: your own installed copy is
# patched locally, and re-patched automatically after Crosshair X updates.
#
# Run it from a checkout of this repository; it installs the readable files
# next to it (src/, patcher/, installer/tool/). The only binaries are the two
# downloads below, verified against the pinned SHA-256 hashes.
#
#   ./install.sh               install / update
#   ./install.sh --uninstall   remove
#
# Unofficial; not affiliated with CenterPoint Gaming.

set -euo pipefail

APPID=1366800
TOOL_NAME="crosshairx_linux"
TOOL_DIRNAME="crosshairx-linux"
ELECTRON_VERSION="31.7.7"
ELECTRON_URL="https://github.com/electron/electron/releases/download/v${ELECTRON_VERSION}/electron-v${ELECTRON_VERSION}-linux-x64.zip"
ELECTRON_SHA256="00a2e8e5f52fe39c37cfc9d7bd7629e560017d28ee94c51495bf7e39c84b2d47"
STEAMWORKS_URL="https://registry.npmjs.org/steamworks.js/-/steamworks.js-0.4.0.tgz"
STEAMWORKS_SHA256="877815e99217ff4ffa560476bc1bd27fc5f7bfebd6319e7d21f3cd601b131943"

SELF=$(readlink -f "$0")
HERE=$(dirname "$SELF")
PORT_VERSION=$(cat "$HERE/VERSION" 2>/dev/null || echo unknown)
MODE=install
ASSUME_YES=0
for arg in "$@"; do
  case "$arg" in
    --uninstall) MODE=uninstall ;;
    -y|--yes) ASSUME_YES=1 ;;
    --in-terminal) ;;
    -h|--help) sed -n '2,17p' "$SELF" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

# ---- run in a terminal when double-clicked from a file manager -------------
if [ ! -t 0 ] && [ ! -t 1 ] && [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] && [[ " $* " != *" --in-terminal "* ]]; then
  inner="bash $(printf '%q' "$SELF") $(printf '%q ' "$@") --in-terminal; echo; read -rp 'Press Enter to close…' _"
  for t in konsole gnome-terminal kgx xfce4-terminal mate-terminal lxterminal tilix alacritty kitty foot wezterm xterm; do
    command -v "$t" >/dev/null 2>&1 || continue
    case "$t" in
      gnome-terminal|kgx|tilix) exec "$t" -- bash -c "$inner" ;;
      wezterm) exec "$t" start -- bash -c "$inner" ;;
      *) exec "$t" -e bash -c "$inner" ;;
    esac
  done
fi

# ---- helpers ----------------------------------------------------------------
bold=$'\e[1m'; dim=$'\e[2m'; red=$'\e[31m'; green=$'\e[32m'; yellow=$'\e[33m'; off=$'\e[0m'
[ -t 1 ] || { bold=; dim=; red=; green=; yellow=; off=; }
step() { echo "${bold}==>${off} $*"; }
info() { echo "    $*"; }
warn() { echo "${yellow}warning:${off} $*"; }
die()  { echo "${red}error:${off} $*" >&2; exit 1; }
ask() {  # ask "question" -> 0 for yes (default yes)
  [ "$ASSUME_YES" = 1 ] && return 0
  if [ -t 0 ]; then
    read -rp "$1 [Y/n] " r || r=n
    [[ -z "$r" || "$r" =~ ^[Yy] ]]
  elif command -v kdialog >/dev/null 2>&1; then kdialog --title "Crosshair X (Linux)" --yesno "$1"
  elif command -v zenity >/dev/null 2>&1; then zenity --question --title "Crosshair X (Linux)" --text "$1"
  else return 1; fi
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

download() {  # download <url> <out> <sha256>
  if command -v curl >/dev/null 2>&1; then curl -fL --retry 3 --progress-bar -o "$2" "$1"
  elif command -v wget >/dev/null 2>&1; then wget -q --show-progress -O "$2" "$1"
  else die "need curl or wget to download files"; fi
  local got; got=$(sha256sum "$2" | cut -d' ' -f1)
  [ "$got" = "$3" ] || die "checksum mismatch for $(basename "$2") (got $got)"
}

unzip_to() {  # unzip_to <zip> <dir>
  mkdir -p "$2"
  if command -v unzip >/dev/null 2>&1; then unzip -q "$1" -d "$2"
  elif command -v bsdtar >/dev/null 2>&1; then bsdtar -xf "$1" -C "$2"
  elif command -v python3 >/dev/null 2>&1; then python3 -I -m zipfile -e "$1" "$2"
  else die "need unzip, bsdtar or python3 to extract Electron"; fi
}

steam_running() { pgrep -x steam >/dev/null 2>&1; }
stop_steam() {
  if [ "$FLATPAK" = 1 ]; then flatpak run com.valvesoftware.Steam -shutdown >/dev/null 2>&1 || true
  else (steam -shutdown >/dev/null 2>&1 &) ; fi
  for _ in $(seq 1 60); do steam_running || return 0; sleep 1; done
  return 1
}
start_steam() {
  if [ "$FLATPAK" = 1 ]; then setsid -f flatpak run com.valvesoftware.Steam >/dev/null 2>&1 || true
  else setsid -f steam >/dev/null 2>&1 || true; fi
}
node_run() { ELECTRON_RUN_AS_NODE=1 "$TOOL/electron/crosshairx" "$@"; }

# ---- locate Steam -------------------------------------------------------------
[ "$(uname -m)" = x86_64 ] || die "only x86_64 is supported"
FLATPAK=0
STEAM_ROOT="${CX_STEAM_ROOT:-}"
if [ -z "$STEAM_ROOT" ]; then
  for c in "$HOME/.local/share/Steam" "$HOME/.steam/steam" "$HOME/.steam/root" \
           "$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam" "$HOME/.var/app/com.valvesoftware.Steam/data/Steam"; do
    if [ -f "$c/config/config.vdf" ]; then STEAM_ROOT=$(readlink -f "$c"); break; fi
  done
fi
[ -n "$STEAM_ROOT" ] || die "couldn't find a Steam installation (set CX_STEAM_ROOT=/path/to/Steam)"
[[ "$STEAM_ROOT" == *"/.var/app/com.valvesoftware.Steam/"* ]] && FLATPAK=1
TOOL="$STEAM_ROOT/compatibilitytools.d/$TOOL_DIRNAME"
DATA="${XDG_DATA_HOME:-$HOME/.local/share}"

echo "${bold}Crosshair X for Linux${off} ${dim}(unofficial patch, v$PORT_VERSION)${off}"
info "Steam: $STEAM_ROOT$([ "$FLATPAK" = 1 ] && echo ' (Flatpak)')"
echo

# Applies or removes the compat-tool selection in Steam's config.vdf, which
# Steam only reads at startup and overwrites on exit, so it must be closed.
apply_compat() {  # apply_compat set|unset
  local was_running=0
  if steam_running; then
    if ask "Steam needs to restart to switch Crosshair X to the Linux version. Restart Steam now?"; then
      step "closing Steam"
      stop_steam || { warn "Steam didn't close in time"; return 1; }
      was_running=1
    else
      return 1
    fi
  fi
  if [ "$1" = set ]; then node_run "$TOOL/patcher/steamcfg.js" set-compat "$STEAM_ROOT" "$APPID" "$TOOL_NAME"
  else node_run "$TOOL/patcher/steamcfg.js" unset-compat "$STEAM_ROOT" "$APPID" "$TOOL_NAME"; fi
  if [ "$was_running" = 1 ]; then step "starting Steam"; start_steam; fi
  return 0
}

# ---- uninstall ----------------------------------------------------------------
if [ "$MODE" = uninstall ]; then
  [ -d "$TOOL" ] || die "not installed ($TOOL not found)"
  if [ "$(node_run "$TOOL/patcher/steamcfg.js" get-compat "$STEAM_ROOT" "$APPID" 2>/dev/null)" = "$TOOL_NAME" ]; then
    apply_compat unset || warn "In Steam, open Crosshair X → Properties → Compatibility and pick another tool (or none)."
  fi
  step "removing $TOOL"
  rm -rf "$TOOL"
  rm -f "$DATA/applications/crosshairx-linux.desktop" "$DATA/icons/hicolor/256x256/apps/crosshairx-linux.png"
  rm -f "${XDG_CONFIG_HOME:-$HOME/.config}/autostart/crosshairx.desktop"
  mimelist="${XDG_CONFIG_HOME:-$HOME/.config}/mimeapps.list"
  [ -f "$mimelist" ] && sed -i '/^x-scheme-handler\/crosshair-x=crosshairx-linux\.desktop$/d' "$mimelist"
  command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$DATA/applications" 2>/dev/null || true
  echo "${green}Uninstalled.${off} Your Crosshair X settings in ~/.config/CrosshairX were kept."
  exit 0
fi

# ---- install ------------------------------------------------------------------
for c in tar sha256sum; do command -v "$c" >/dev/null 2>&1 || die "missing required command: $c"; done

step "installing tool files"
for f in src/bootstrap.js patcher/patch.js patcher/asar.js patcher/steamcfg.js installer/tool/crosshairx-compat.sh VERSION; do
  [ -f "$HERE/$f" ] || die "missing $f next to install.sh (run it from a full copy of the repository)"
done
mkdir -p "$TOOL/patcher"
rm -rf "$TOOL/layer"
cp -a "$HERE/src" "$TOOL/layer"
cp -f "$HERE/patcher/asar.js" "$HERE/patcher/patch.js" "$HERE/patcher/steamcfg.js" "$TOOL/patcher/"
cp -a "$HERE/installer/tool/." "$TOOL/"
cp -f "$HERE/VERSION" "$TOOL/VERSION"
cp -f "$SELF" "$TOOL/install.sh"   # kept so `install.sh --uninstall` works from there too
chmod +x "$TOOL"/*.sh
info "$TOOL"

if [ "$(cat "$TOOL/electron/version" 2>/dev/null)" != "$ELECTRON_VERSION" ] || [ ! -x "$TOOL/electron/crosshairx" ]; then
  step "downloading Electron $ELECTRON_VERSION (Linux runtime, ~100 MB)"
  download "$ELECTRON_URL" "$TMP/electron.zip" "$ELECTRON_SHA256"
  unzip_to "$TMP/electron.zip" "$TMP/electron"
  mv "$TMP/electron/electron" "$TMP/electron/crosshairx"
  chmod +x "$TMP/electron/crosshairx" "$TMP/electron/chrome_crashpad_handler" "$TMP/electron/chrome-sandbox"
  rm -f "$TMP/electron/resources/default_app.asar"
  [ -d "$TOOL/electron/resources/app" ] && mv "$TOOL/electron/resources/app" "$TMP/electron/resources/app"
  rm -rf "$TOOL/electron"
  mv "$TMP/electron" "$TOOL/electron"
else
  info "Electron $ELECTRON_VERSION already present"
fi

if [ ! -f "$TOOL/steamworks/steamworksjs.linux-x64-gnu.node" ]; then
  step "downloading Steam integration (steamworks.js)"
  download "$STEAMWORKS_URL" "$TMP/steamworks.tgz" "$STEAMWORKS_SHA256"
  tar xzf "$TMP/steamworks.tgz" -C "$TMP" package/dist/linux64
  rm -rf "$TOOL/steamworks"
  mv "$TMP/package/dist/linux64" "$TOOL/steamworks"
fi

GAME_DIR=$(node_run "$TOOL/patcher/steamcfg.js" find-game "$STEAM_ROOT" "$APPID" 2>/dev/null || true)
if [ -n "$GAME_DIR" ]; then
  step "patching Crosshair X"
  info "$GAME_DIR"
  printf '%s\n' "$GAME_DIR" > "$TOOL/game-dir"
  if ! node_run "$TOOL/patcher/patch.js" --game "$GAME_DIR" --runtime "$TOOL/electron" --layer "$TOOL/layer" \
       --steamworks "$TOOL/steamworks" --port-version "$PORT_VERSION" 2>&1 | sed 's/^==> /    /'; then
    die "patching failed (this Crosshair X version may not be supported by this patch yet)"
  fi
  cp -f "$TOOL/electron/resources/resources/logo.png" "$TOOL/icon.png" 2>/dev/null || true
else
  warn "Crosshair X isn't installed in Steam yet. It will be patched on first launch."
fi

step "registering crosshair-x:// links"
mkdir -p "$DATA/applications" "$DATA/icons/hicolor/256x256/apps"
[ -f "$TOOL/icon.png" ] && cp -f "$TOOL/icon.png" "$DATA/icons/hicolor/256x256/apps/crosshairx-linux.png"
cat > "$DATA/applications/crosshairx-linux.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=Crosshair X (Linux)
Comment=Opens crosshair-x:// links in Crosshair X
Exec="$TOOL/crosshairx-linux.sh" %u
Icon=crosshairx-linux
Terminal=false
NoDisplay=true
MimeType=x-scheme-handler/crosshair-x;
DESKTOP
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$DATA/applications" 2>/dev/null || true
command -v xdg-mime >/dev/null 2>&1 && xdg-mime default crosshairx-linux.desktop x-scheme-handler/crosshair-x 2>/dev/null || true

step "selecting the Linux version for Crosshair X in Steam"
SELECTED=0
if [ "$(node_run "$TOOL/patcher/steamcfg.js" get-compat "$STEAM_ROOT" "$APPID" 2>/dev/null)" = "$TOOL_NAME" ]; then
  SELECTED=1  # already selected by a previous install
elif apply_compat set; then
  SELECTED=1
fi

echo
echo "${green}${bold}Crosshair X for Linux is installed.${off}"
if [ "$SELECTED" = 1 ]; then
  echo "Press Play on Crosshair X in Steam to start the Linux version."
else
  echo "Last step, in Steam (restart Steam first so it sees the new tool):"
  echo "  Crosshair X → Properties → Compatibility → tick \"Force the use of a specific"
  echo "  Steam Play compatibility tool\" → choose ${bold}Crosshair X Linux (native)${off}."
fi
[ -n "$GAME_DIR" ] || echo "Then install Crosshair X from your Steam library if you haven't yet."
if ! id -nG | tr ' ' '\n' | grep -qx input; then
  echo
  echo "${dim}Tip: hotkeys work while a game (or any X11 window) is focused. For hotkeys that work"
  echo "everywhere, add yourself to the input group and log back in:"
  echo "  sudo usermod -aG input \$USER"
  echo "(this lets programs you run read keyboard input)${off}"
fi
exit 0
