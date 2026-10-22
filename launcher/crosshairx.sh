#!/bin/sh
# Crosshair X (Linux) launcher.
HERE=$(dirname "$(readlink -f "$0")")
export CROSSHAIRX_LAUNCHER="$HERE/crosshairx.sh"

# The overlay must be an X11 (XWayland) window: Wayland clients cannot make
# themselves always-on-top, position themselves, or ignore pointer input.
unset ELECTRON_OZONE_PLATFORM_HINT
export GDK_BACKEND=x11

# Fall back to --no-sandbox where unprivileged user namespaces are disabled
# and chrome-sandbox isn't setuid root.
SANDBOX_FLAG=""
if [ "$(cat /proc/sys/kernel/unprivileged_userns_clone 2>/dev/null || echo 1)" = "0" ] \
   && [ ! -u "$HERE/chrome-sandbox" ]; then
  SANDBOX_FLAG="--no-sandbox"
fi

# No PipeWire/portal screen capture: it pops up KDE's screen-share dialog and
# has crashed the app; screen previews are generated instead (bootstrap.js).
exec "$HERE/crosshairx" --ozone-platform=x11 --enable-transparent-visuals \
  --disable-features=WebRTCPipeWireCapturer $SANDBOX_FLAG "$@"
