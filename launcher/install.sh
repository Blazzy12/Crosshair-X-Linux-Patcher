#!/bin/sh
# Adds Crosshair X to the application menu and registers the crosshair-x://
# link handler (used for share links and sign-in callbacks).
set -e
HERE=$(dirname "$(readlink -f "$0")")
DATA="${XDG_DATA_HOME:-$HOME/.local/share}"

mkdir -p "$DATA/applications" "$DATA/icons/hicolor/256x256/apps"
cp "$HERE/resources/resources/logo.png" "$DATA/icons/hicolor/256x256/apps/crosshairx.png"

cat > "$DATA/applications/crosshairx-linux.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=Crosshair X
Comment=Custom crosshair overlay
Exec="$HERE/crosshairx.sh" %U
Icon=crosshairx
Terminal=false
Categories=Game;Utility;
StartupWMClass=CrosshairX
MimeType=x-scheme-handler/crosshair-x;
DESKTOP

update-desktop-database "$DATA/applications" 2>/dev/null || true
xdg-mime default crosshairx-linux.desktop x-scheme-handler/crosshair-x 2>/dev/null || true
echo "Installed $DATA/applications/crosshairx-linux.desktop"
