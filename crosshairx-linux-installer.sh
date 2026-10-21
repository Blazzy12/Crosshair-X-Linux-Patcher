#!/usr/bin/env bash
# Crosshair X for Linux: one-click installer / Steam patcher.
#
# Installs a Steam compatibility tool, "Crosshair X Linux (native)", that runs
# your Steam copy of Crosshair X natively on Linux instead of under Proton.
# Nothing from Crosshair X is included here: your own installed copy is
# patched locally, and re-patched automatically after Crosshair X updates.
#
#   bash crosshairx-linux-installer.sh               install / update
#   bash crosshairx-linux-installer.sh --uninstall   remove
#
# Unofficial; not affiliated with CenterPoint Gaming.

set -euo pipefail

PORT_VERSION="1.0.0"
APPID=1366800
TOOL_NAME="crosshairx_linux"
TOOL_DIRNAME="crosshairx-linux"
ELECTRON_VERSION="31.7.7"
ELECTRON_URL="https://github.com/electron/electron/releases/download/v${ELECTRON_VERSION}/electron-v${ELECTRON_VERSION}-linux-x64.zip"
ELECTRON_SHA256="00a2e8e5f52fe39c37cfc9d7bd7629e560017d28ee94c51495bf7e39c84b2d47"
STEAMWORKS_URL="https://registry.npmjs.org/steamworks.js/-/steamworks.js-0.4.0.tgz"
STEAMWORKS_SHA256="877815e99217ff4ffa560476bc1bd27fc5f7bfebd6319e7d21f3cd601b131943"

SELF=$(readlink -f "$0")
MODE=install
ASSUME_YES=0
for arg in "$@"; do
  case "$arg" in
    --uninstall) MODE=uninstall ;;
    -y|--yes) ASSUME_YES=1 ;;
    --in-terminal) ;;
    -h|--help) sed -n '2,13p' "$SELF" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

# ---- run in a terminal when double-clicked from a file manager -------------
if [ ! -t 0 ] && [ ! -t 1 ] && [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] && [[ " $* " != *" --in-terminal "* ]]; then
  inner="bash $(printf '%q' "$SELF") $(printf '%q ' "$@") --in-terminal; echo; read -rp 'Press Enter to closeâ€¦' _"
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
    apply_compat unset || warn "In Steam, open Crosshair X â†’ Properties â†’ Compatibility and pick another tool (or none)."
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
mkdir -p "$TOOL"
payload_line=$(awk '/^__PAYLOAD_BELOW__$/ { print NR + 1; exit }' "$SELF")
tail -n +"$payload_line" "$SELF" | tar xzf - -C "$TMP"
rm -rf "$TOOL/layer" "$TOOL/patcher"
cp -a "$TMP/payload/." "$TOOL/"
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
  echo "  Crosshair X â†’ Properties â†’ Compatibility â†’ tick \"Force the use of a specific"
  echo "  Steam Play compatibility tool\" â†’ choose ${bold}Crosshair X Linux (native)${off}."
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

__PAYLOAD_BELOW__
‹      ì[{WÛÆ¶ïßş5MäÄ’@Ò…Kz†U, 79—pYÛ*²¤£‘±İ„óÙïoÏCIÛ›æ¬³N´ [3{öìÙï=3¤Ş2J¼ ıÍ_øtğ<İØŸxV?å÷îFïÉ“^ïi‡àºİ^÷é7lã¯$Ê<3‘{cßdI’îSıÿ¡Oªåÿ?{'§ûG‡É$à'ëë‘ÿ“ù÷zOÖ¾a¿„š•ç¿\ş]·ãvÿn*¾>ÿ®ÇØ¿Ÿ%BL¼0[8QÏ®˜|¶9>áÿŸ¬?}ºbÿİî“¯öÿ%oïµ‡aÜ“Æ·lÇè {ÃìÒ‚&‹¼YìOx¶É2î¤^ï‚åÎNsîM™Ÿ¤K–ŒjCç[˜³‰'˜?ñâ1˜­ÌÒÀË9K2ó9“ÙÏD˜ÄÍ!	$ïc·h&;wœ±7åì‡ê¼aŒ‘QÄ‚0{vÁÎ½4e^6¬]¢p›í6ûåäà¢qvtt°ußpL˜¬ûvÆ½ 3\2g„×Õ´š½ƒ½³“£Ã-ë>hóˆûy–Ä{±Ÿ¶_ív÷O¶,«Ø9†w-¶Å,E¦Å.úji%àıÕgbrÖë³QØ8gÎog 0†=x TNŒÖÓ³½íWƒ£WÇÛgƒıÃÓ³íƒƒ¾¿Ô`¼wƒŞ=­W.¨uÀ’U´÷mßËo 5Õbo ığ­÷ZÓŞÎ¸Hf™ÏE‚q=áe[Œ½8úåpÓ~N~9lŸv÷¶ºÀc:,C…ÒÅ¬-H­üÑØıUXàc(ÍĞP®‹‹u×<ù¾Óa½gí€_µãY5Wø&)°D#Nòp´´›ì=(ó“éÔ‹æ\1Õî×>è²j·ã1«¢›sBCRè'±›ÆckBêL…ÀÆucä…‘&œ®Pr„^”ŒW©ĞZfz'óˆ×æ1†Še°Ãó2Æ£út¿ñ8Ì—wÌ¦;ºOMšóE~ûœ‚kÊnihö'	³$êMF£=è3Zóâ;Õùwê]š…q>b¿oã‡5dÏn¨»’Â=öÇuT~JuŒv–9N6‹ó°ÔYãc,öSªÇq"oÉ3"_h¨Ôşy’]
ÓU¶Pšd¹£ı+ù¸ŠëŒß’R	GNÌy ?]Îù¬¶eUä.Á”F«”×™ñş¥7æ` -ê¢2ßIfQ?ÌM€ #•FÇˆT‹Ú(jT5K¯­¯¢F%Tšñ«0™	Óí²]Ã˜theI’R>MÙqJkFI˜¢£:7Ñ$itßÆocR¡·ñA2Şdß	R›f$]»ÉÈ¦u[›&/;»òEÙ ™ã8ã)sşÉşCiUğğ&†
gıôãr)¿a`¢ıÑªƒª[(h‘”¾ıÏÈ\±·¶qWo¸l_Çq0a”%S¶ZnDá0ó²%HÉDî¿4¯Èm«€
Æã«$MyÄ‚M¹‡/$-2>è@%)Ğ–@?`K˜ıW¬‚lˆŒEšùÀâ‰h!³	¡ABy”@ÛBÂö4ù˜Æ,<g»ƒã“½ƒ£íİ†ï	²n´ì??Ù>ù»İüHÚë£$íš¬\eı>ãÂói‘gĞoC÷Ù+(!Şt»Ì~óé<–ĞdsDÂd¾Étó£Ü@:æÅ09vÉy
\ÊTğè
9ˆÏ“´ÅÒD„’e_‹Òµp',+YÀ…q:ËÍRxô¿G‡{ƒãƒí³G'¯/÷Ïnu—¾ ÏÄ~Úıyğ|{çç=ÿE·kšwNNO_nïŸ¼lÿr¸órïÄ$`·dƒqegU	g$}õ“#‡&ÀOXòUqJBg¤S¾' ŸX´…yK˜…›ğ(åYÓmœnî>?z3xq°ıS%¥“Î³f‰ßKÑ¾äYÌ£vÿ€ğÇbàC5xÕz(%’‘¬Û”ya‡‚•ô´2Wº7´ÉË¦I6€måYèçƒ[f»uš§[5=xêÙ«õ‰oÜÑ<ÓÙ['€¶´ã0å¯ÃŒ·I^^Ä„Ÿqä¾—æ3h	Œ.…7„=o’§I
I¤Ò7\\BÓ
 QÃƒtÖb%ïI-ÙÜ#­²”ô=ŸÌ¦Ã˜9ÄÄÜ¯E]ÇI~ã€æ°ö)©å%1âä™CìÌÀ¹
ÅÌ‹„ãhR÷ˆz±õšOÎvÌwÔ¢2v¿ÊÌü7ë?ãä–ú‰üİgÜ øDıß}²¶ºÿ·Ñ[ë}­ÿ¿ÄS­ÿMIOâ‡a„´ŞÉ“$B<Í)’ëgv-x«Í1àŠ£`v4¡ˆ´ì6½b? |Ÿ±TB¼^ğg(ØQ¬»®{” §…Z^ç=€1gI(5ç
B%‡’MÔpFû;ë|"h‹ÊÉ÷¿eÎ8gUOÈ½aB8ÁQÜ†ßó\­ˆ’ƒxS³Ó[S¦`ß²ÃDfLº8%
«*Í–NY9Ê8a¯ÃXæ¬£páÊ¡«e	•C2Óé  ˜ûaî…äå¨¾-MÕ‡¢5IÃùRµ—#¡Z–#Ì\-7¸Å„eÉ,GxTÔ$ãÌ›’Ã¶¹;vAµŸ…iÎ¯¼hæåI&ÅBh3_ŠH5œåäQMV'šX.p'RL¤S}™}$`*¹ş×Jéò)]¡EqªÅˆ.ó1óµ…„—¡Œ'SWm¿ì½Ù£X=’=Œ¥{î#W£^ÉÎÓ‚‹ÎwüÃó7‹ZÀ‡›­ÀÙd%vÂ Y,¹Š47ª5(`tüTüo˜ugâR–ƒı,p5¿Dx1şŸd‚r?!Óp¯‚ÑçœãSç?´Ù[÷ÿëë½¯şÿ‹<–ºÕ m&KÌ({T^Yz*ËÑvkšÀ¾#¯øÕ¸şÏO‡şë"ÿ«F}rŸÑ	|Êş×ÖVÏÿ7Ö¿ÿ~™Çº!x¡=êè&&w¡©¹ğ ÇÔ¦Õ{½ueéˆ? ¼Ã5{Z–.á±<ùXiFĞæÏ 2
Ğ¹bÑ›'e_…ëı~õD¿÷1ö/w”ÿ¢[@üşOommíëıŸ/ñÔå?Ä"‘¿{©û«ø|s|Üÿ÷Ö6nÈıiçëùÿy¬™ 
š6­~£İÖÎ¸Zñ¯Ô‹. PoÓ="œ¦§wYæŠâÀ¦VÚé}š³Hß#ğÒ”°eüŸ³0£½f1§'jo¥ÜˆÏ	ÇZyBÌ¦©Ä®o
L™
æ' 6‰PVR+!K²pÆ^Ôb³s…£lê¡*ÎËrõ<°äì•$„m™émK‘f5ûBÖï•~×ŠŞ‘¨öDÙ“Ôz’J?	£`@[½TÊV€j%¼Ùª­‚G„€Ò`§/÷_†t…àìÁ@•-f‰I8­àÜ>>œİ	ïº5xéü¹GË˜É‰%=5JùÈó¥¦Ğê)q@hçWxÿUlVÈ‘jÉÀ¯{éµÙRäùÃto1`ñğÅ*p 6n‡”˜Ÿ1S–ßiúJœ¡ğ“,¸¯é¬.0ãã;‡ĞŠ“€;“0°n6üºP2¸}@™€; (ĞoTßĞ9šÅêXÌ&ÕC•Øbj½ÅBñ
U\N°†t„æ¦´-—/SîN<q4³$åY¾t}ø
»*üÓ8›M>f<ŸeqAœ’OB	Z<×ã.nÓo¨èÑ@lkk‹Y—ÉhZM3ƒ>Aı™ZíÛ§»}µr†Øÿ&¤»,UÈÕÜ˜íT}é|NGpÒ9ÓşQ+§şRÖfjãiÑeÛM¶õìş~„‚Êåöq}©lp’óz‹‘©‹
P'2ZğÆ¹‰Œ{c!DCòéê l­×¦3.|*/¸òÒA.Æä­í#‚'S&–àÁ”ù³L$™¤lL[‘K6ÏÂœ‹¦Ë^Ò¶¡Şs$|æpw.›ŒªFgÏò˜Z$£<ZÊML½ígZ<¦5ÈmçYê6"«e+AÃnè,®ß(¬§¦o´´›êÈBnÕÆ¾¼„$£wÉÂ!ğÛä¦¥0•å˜~NÙÑéWzîG´Ïj:	²_µ¹÷rı›Q8HÌ•Ÿ¾UŞGÈW@H'VšÄr:LĞ æ%¾PP&ñÑÅ¦ëhY»4Hn€^K#¦?«<E" o²X*–µôÒÇ<·!	|´h£:mµ(q—Z”ÕĞ”VÙY¬Ü†´˜ëºtÆ*‰´Ûoİ Šî·CŠ“Û§Èâ1ÁÁSıh¤ ßÙ&Ss»rE5TÍ¾êºQ›ğ„ÈO¸7Wğ×äÖ¯«vWW†kiV;¤ˆz[\¨kÄ|°–€ıĞ‹˜Ü1ŸÓíu’:¤ëU¡à&3#4"kDZÈmvuƒKa%-B #yQªÂiÔd×§ª{CËµŸS>±Ôs×¸<¾r+çû{‡ÛÏö§{‡g'W’ê–şK!©ğ¢TÕõGµ ©A^¢·“T%!×RğZ”c¿'9Rw‹é•nBò‘€J"Ş”‡P#d&–ÕŸ°’¤:u¡KãLÁå‰Êı'8Dyå…d<KáÒ¾æïå‘9áBš@€ğ%É®šzÃÿıb#’Âçó„ù27.x
Í²H“h9
áé€…4C¹Mù„º£|(öù6]s’tÔƒ4e\Q•8D¯æv%¹'¹óÔ’ÒUSR“§ê\f «uk¤æz TÉUNŸr'ëu¤\²İA3g.Íba÷Şúº qºŒ}»Jf‘´ÈÕJ½Ü#ë±ëÔeH§Z)œ(ïkÁ›;Å}	«ÈboÄQşÒ%æî`à/Vƒ†˜—¡‚tã Iß¨]¥ Í¦³ÖñÑİRıHß\ó³Ñéz(Qà1ä½ªØ½•6WŞ¬i²[›‹Øs~QG*Y5Œ¦ÁPå|a½4ç; €İ‘ãıM±ì,éW1Ò”&ò–Sòz°ç0®"÷™šˆn²¨‹QZxs>ÀBµ’
YÆÙk‰€Ø"šÕ…zólÆ+¤wıÿ¨¸VêJYqÙ»Ü—´MúV
×PLtˆCÌ%&ŠÅe<u<‰Œ'n¥tØ[pÿE(çÚ¬tŒ*;PgŞÚ^+)à`àMIÍZ,1u=y¤!üS8¨˜€WÉáäÃ…ŒÇéKûfyö[š¤ùcµ	¾0R]ySêt~Ç„.]·mO…5©§f44[ÍjRE‹«o ¸msõ¨­:e2^ã‹+rpª‘áX1è€VĞt§^jÛ©$àuÿ}*-çÚjÉïiĞ×àI"o]üvØÏÖ»¦r–ÖÛìmA"qÎG‚b$óE~ú—ºğ‡¶ÊÅˆ ÇL…k´LÚRä…I¬µKÄı¤l²NÕê‚Q%Zê*,ŸÉÒ­¬şä¶‚RõbK¤²¯ğBX‹=‡Ù£dP¡¯¥7œö§(.Ø58oF*"”Ó©Ä	Ûß92^€|@edŸìFšıñáOHƒr„=ò¨C¤…H%Ú…~r–#eLohqÊîUUøÃvÙ&z›6ËÂ±ôç©
Œ®®ƒíbíÕĞ]İjÂXZè¥´•0lÊëUEeğ%©í /Èù¤Çj¿«²z×¯uºT Ù•~9óİğä÷Ó¢î¬OdW8Eªc¤;Ö6/“¨º;÷2h÷¹¿h¥”V†R	}÷Ô›ĞhîÂ©	E¦r¯tÖÜ'La´Ë(é{‰Åm?r„úZcyíĞeG±¹SKÈò	”`œÈ„­¼à²ÆFçè’¶Ç,’Èâ³@›0yóÑ’©¸ºıH³"nBBä˜š-¦ŠVÎºŞªnY£?“)…YÌ ”weU*¡£³i]ñ_[S‰.ÿ
Z4%il;s^,Uôª¦0¸»dØĞ™^‹ÍCH×CM7òŒâ
yhO¥“Ç*f¡±œÌ†ñEË4îğ7^Í=‘ÂP¡;Â% w˜²]oœğp<‘)â”-•°-Fú÷ŠÔÒŞÎ1Zá.²©	{Æ*ˆ@…TÅ-±V°LØ£K%UÎF€{>xæBz‰ù1‚^oVlyA6ÕcİçY‹[lxQIÆˆ¨ûîai¾,Ø³-Ğ!›ğmb¼D5º$„x‰éæğé‹&Í«ºAÙyrŞa_}G—ŞÇå{Ş³ò}Ş{E£™dtıNócê-ì^k•ÃßwT!e¶I*KÀwúr1|<~Ü,ûªV<ÇõUƒ6Æ”6P·Zs¥|Ó¬qj Ä£¢Iq!]h®Kœ?²s¬®Åº½N‹õ:ğçkß·ı®÷.Š46°¶Ø@
Ÿ#<CõÆ!…´Ï¡r©­w¾SeW& ”Æ-8öâè6ÚÏ­.ùév)Şvä[Gşè¦®lèšZS§X`Qƒ­–:/€*åèn_ñS@uW¡ºÕY/J%ˆ¼!§­&½5"­™Tª¢åâ6E	rqi?w½	UÙhVÆä	\Ükªw¿ñxœKëÁ/RZ&Œ•'ƒ]c$é«Ñ„´WÁ™,W@I+6a	)uÑœÎ,åüu=GË”üIóü±?ÑUL¡Æc­ãcÒÍú¬iùX«ù˜y>KEW&/'8“ù®—c„º{f;„¸ı¸Ùi(ĞzÖ€fôY›5Ğ³İ-g…$9…äëc4·ˆO™œ]¶oê­Á<ÌŸ³}!ÿÒø-%—•$ğöp¬œ¢ßÒ‚•¾y“!?S¶²	SU;"õÔäıjPn™0UÏåª©ÌO<?Õrku8eÜºS¥1+ır‰w)‹Ìú¾QUM(Ï£.‚pÕı‹ÇEÍMÏ(²Uë`	ˆúÜf˜Ş¶Ô*­f©!Ú¨”
ä&ÄR#&)øÚİè”œÅ‹©M‹İ`>‰L5­q;Švu;*…È2ñ‰¬5"”\©çÉÉwA®µ|ÁìE×²Úµ,6ÇÌ¤.”sÏó'¶"T‰á,wÓ™˜Øåæ,ïq›÷ß.jŸÍÎ»VÑO… N•6Ü’÷¹® ”IÑ¦ñR„¥YBüÛ¬g&ÈJt>RÂ"™Úï6Õ¶Ù×mÖLÂoÒ1RT”Q­·Õ¾r®s-ÛRú4F;»fÉ×um.y¯¨uukRN³©&9õÚ˜tìşs‰õŠ!Ü’MÓ»¡>´†ªèrÔ-G™} x{À)OŒ31ö]ìSáCW	å®Ÿ©Y‹ÿ($¤â]îç™[¬0²^øÜMùßp®à9É°l–ÌÑœyo	òÿÚûö®6lßûw>E»WÖD²…„x:`œ‹ÛLlà N<ŒÜH-è ©uÔ!|÷»{×³»vâñ™9­ÄtWWízíªÚµŸ´aÃŒ«2f¬Õ2ëÖî/[ûïÖÿú‡Cz1…pİl2 Şê®Xí¡‡)€‰ Î8ó`t-´™ŸŒk’W¨ªŸ0˜úÈíİƒM1$&ìÅ]ĞÏAÔ»¢å6“fhu½¿ûîNI÷µá"İ+¨É`L±`}oÜ"¢íÓ™thv+VÉ¬0¡ÿÁÇÍ7,›ŒS1Åå‘,Âwbq`¥e¡°ß43iıÃáîÁáúşaëõö»­R$€¼€jhmìî¼Ş~Óz»û~ÛÍ˜fõó´w’Q¥ŠÛ0Aî&„ôlš„±Š‹u…Ù@ 0aÆ;tŒÄƒx.!³+3ûììô…™«òĞ‚Œë'¿k³ÀZ0E¢-¹W¿8jÎû¬Ş¿ Ê…]Wª«8]G1„ t¯0ÑP–†‚AÃ üÒtä›/<Ú”A
¶0›'ÁCB¹µõ!¤@,©@Ú5bÍõc`7ÍOà­…ßß¢7wá'Ê¸æ¸Î ¤3ovhNgÖõ\iÉÒÏ<)òDó¹†Mu'~Š‹?7.vJ(Ûd óŸ²lv?Ïo™Ó6M‹õÊp‚‘¸“ß,yÍ	¶MÁ6‘=Ş"­÷vª&y³·I§Œ|ê*Êv)=îX(øÀx`·ì¶C3´caqT|ì.İÊÄâ—7³Œğ¢‚«¯İ=õ†ògøzÂÜ;K-[OïŸôpÕ†ÊbP1VØßßê…¤ÌhÕ·»}Mq¶ôâ(£-ş®ú‰š®;\*z¢ƒxÈZ5Èé¶ÃAÿ§õ÷şìÏ×ÿdm­¯®üåú¿ó‹Kú¿ßâW6ÿFÇì+Õq¿şo“ş_ÌÛÌÏ>Ú|“ßı_Gß¹	Ÿ'>Õƒõ€N,h€DÑéµ¦U(ÜğˆùÉ™V1nwÒWå"¾±ÊQ{<‰z¬KÒKÄÿ«8(ıcÚ/£è	*^»Övaöø˜Õ°øğ'Z·ŸdŞï Ô
cıUWÚïtµİûÕ}Ë”z-òC–ïªT\n6èS\ÛJÕ2-ÚÔÔ¤€fO!äQËJFw!TWÓb¾^Úzœôppø==Ûe4B&Z&¥Ó>¥À5HÚ=×4˜/nA6ˆ†¶c¼/´åı°Nòœ;VĞ3ƒiô3¹n¯èx—]QbâªmÈä"5i["ºµ4 Œ¼ß4Yê\+]æëŞ9HÓ‡¢Ä ~3I:
eœ.uÑ¥£°Û•q&Á½:lĞ„4zÉi£s:ÉÜo'ÓûtL¯;æĞ%`“q÷9Qu´	ô+Ş 4şq4;óc4Ó=¹Ÿ»3"Ê¤S-Q¤;J:Šm4[qjŞŸƒÉî&4ç(eÉKYŞM¡7MïÏ„¦UwŸ7¼Òá‘­ ¬Ïé.TÃ $6^é&÷ú8}—ÒnµÁ¤ #]=~ö}ƒÅáBÕ†o·Ù:>¦"aPé¡ÄŒÊ«ÁÌK£qcøx‡ùRüH“fü²½øaıRv?B«*áÛŸ7>`"Ô:>şKŠÇOV²ÜÈ0…ş>ãñ|†ÁOÔşÊPJ¸Vh ø
Rsë÷>_ÿûW3z=>ŞİÇ°úßLi
Òöz9ã†¼·ßW(éÁ¦ì¾>üu}ËkŠÒbv©Y“ÔŒQFÊ¶aŠu¸7J;“öXf!”£\—à—}Hñ:¤•’ª®Wğï°Œs{D{O)Ó÷¢,öµ¦±ÙğGÔ†tär‰µ®XBG ĞOñpù™îıDc±jóÂé¬x¤œaè|>O™Ùè¥E£ö¹.ƒgç“:Ül+™Z4¿Å¨›U|öVÆ'
eÒŒšQ=ñ€ÊüDÿT #+ëRÕ SEÌL¸²œöÿm€^­àÚœÃÖEÕ¬˜
k@'lÅáşÖ›ÖÁßpÃü•ª ŠÒ>_qFÊè°@[SàAmÆíı%<©a3ã£$ŠåÚ5®Xç	‡¢ƒ‡j	Rh…ÕOƒZ‚Òa§|0a&ä‹XîL5Aà,¦LF·HAÇ7ªZ•c¦‹Œ´Ü÷ì'†â¯^”Ğ£zü/•o8Ê:œI"6+\»¨[]Ğxˆøİ'$V?cp@W:Có¶ÕÑIõ^X[Lr|…±65>‘‘~`zU½_ÿsµ³sT÷§¶&£UØ’f´°®kjGr[5µRÔ£ª¾§ŠQÜO/c]ËW+B™ºÏ…åÁa(8zKoş,˜6d£?„¨(µhèŒKÎ½ÁŠÊ=*Ú¤ÕÙj†ß˜¨¡?ûò¶ÏoòI}Ù/|‚¬:X!WÓ š,ReU1)p‚²»y xxÿáİá¶M×¯êëÖÇ½õMûÙ¼‡âæ¯»û›ê+?«’ÿå¤ÿ—“şj{g}ÿoêƒ¼¨/;»;[*¦†Ã¿íIOM»ó-Í7Ío×¿Z[ĞæÖëu‚Úúeıİ‡->G…9+ºóuq±ˆ­'ô?Ÿ‰ùøûÃ¿)ü?kqûêxÀÿË|s±™ãÿ-Í5gùßâ÷ü?…ŸŒ-ëƒ6”o\ˆ“ÎXPÉš™ù—¦DIÁ;¤î0Â|m³Id ØïiÀ¼¿ÖÎÖak}ãN…Ö¯Û;›»¿øµeóOãÛv5ˆ´
îŒr( ¥Ùşp|C­hOØ¦C˜…"!wÜÙyÜë\%„=[
jÄÅâİ×ğ'{à“Ü0™C[&Høb¤Ÿ†È’1O TlfxŒE»i†ªÄæÖÁÏ‡»{â
˜î{+æZ||ìuÃåGB]¢w¿ÆTx`¬:ú(\Kø	ê²ÎÛ0±fE·Ì³[ñá› 0¿L—c•	Ms”ÁÉË¸,ÀQ6íXc	¢ŒÚ£ä4¶5¹*ïf7H¾èÁ‚ùğ@_îJÉ[¹:–šé0ÅŒ£æ6L…G¢¬ëÁ•fR’©Ô}±ÍYq,}UÉ|ÉPVx«_BgÅıB<ÌÁ éı’d	]³
™¨…Šr@ 	Ÿ¶ &¾ÓÚç±‡H'G«.¾BLöp|ØDºÀÄW¹ˆ bÚnxG@~ĞŸu©ê´Al]ÇÁ0}L|1´Û‡sI‚¦c/bVˆæ4ÎE"VÏ
ı[¨Ö04¸Â:…%kÆ×sRáï`.QY—iÊ9ÖÖ¸E¾’v [©.Ì˜qØ´ÈñĞn¤aÍ¶Îr@Š	ºq–Çr“>²Ûõ‰»3kc'WK!Ï[UêT¼m±fC¥Ê<T Cêè\IF5¾øæ¥(^ßİ#ùoú+£ÿ\$_£ıÿ5óñŸ–fg›ôß·øè?0á6‚ƒ”=	lşÌn9”K ×¬¼ÎùËè%À’]Fœu€€Òp‹FÏõï
»}¯QÚ`7º$àÌ Ôê‰áÿuœoş+[ÿ÷¢¯RÇë¿9Wğÿ»¸´ø¸ş¿Éïsï'èöGëÿp%øˆoÀÖ}EH÷"àö€úÑ€Œ?ìo+äğÀû†ñn è¥l®V·raS´Y™÷³Rz]5ã=7a´¢õu‰Øæômmß^ z…r×¹ºéŠçV@S£,½´‘ñÊïF	Œ’‚È£ñóñx˜ı´¢ÅèÈd7 ›¬D¼u=Gƒ¨Çßëğs§8¶Ğ‡­¹Î;ÙC”,®+"¶âfº3íVšØ‡Qv¡››JãIæ÷<4;µŒ’èèBgWT¼ıÜÎpªræ|$ÿg~eû¿ã6î«Ôñı·°<—ßÿı~›ßçîÿ'>åùd¬È.‹osõÎSºa.(?B=62ß<X M¹“q´QÎë§7%¾ìÄ—š‹r0£ •™y]kY¼İŞ,(XLõÁ£[[$‹Ş]´ÃRŞª­ÁMVÒ†¡•ö`ü¯Ù«JïÊÏå×ªã¡õ¿8;Ÿ_ÿ³ñ¾Éïs×?ãÄ§º,ğxÅv9ë›–û²0 PóûÊ—y%‹cã•½ÅVkâpÌ0ñy	³ºï˜½[D—)­ìN:AÌ®s	Nq¦œfœNÆˆ
'[Y}
q˜dé`·ËX£B	üÇñèFÊùOßÊÖ¿ã÷«ÔñĞú_Z,Üÿ–g—×ÿ·ø}îú×8ñ‰è÷ÁMn1Wp¬ÙÃ¿@f§¨)oi—É*ÿ¼qÔëõª•Ñ±%)åÛ,JË°éBucè/–²=¸êİà1¹=Íù2„³[]Ê¨­ê=âÖM–BvE#’O¾sU'ÿE[ÍùÿWİXÿ PÿÏ=Òÿßä÷ò½ÀUIzJy]A”ušF£N£ŸşÕ:[–÷`·R†Nz5ÇÓ¦·(´#Úwi®1!®¦—ñ¨÷3Ôzûñ8ÂÀpø=Nzò7ÉÌî½¸õwwµá•¶—\Ä°_m_¾ƒ@¢¨ee1Êğqo\øÛf+GVê7 µ¡Š9%{ä³0«Å[Ëúx-q+„¬E`UêÓŒ ;mÇÁÌŒJø¯×‹Ï¢^].4~óµ³É¢XS`Ü/hø'ì>ÆélM_w»•~]M¡#ì³»åo]M:ov€B‰3Íª‹\| 8P`”€É†l.’À‡MSAñl_NÀš#.U•®¦~k¶î _	h[vNœl‚­ ¡×|SŒo—õ7ĞøhÛ|$Ç7…îæ‹öĞ$<@ièÿmPıø»ŞãWÂşğÄ:“±Cl—øVJ®(9'Hş°óv}góİÖf°õqckïp{w'ØŞ9ØŞÜ
6Öß½CìæñKc’¬É»kJoŒİŒ« ¥¬FlÆ'(£î4ŒüZM/‰ÀjòÜAÿÿ|"ı_øóÏ³~Õ:pÈ™ı÷İ í¿¿ÅoÊü‹ßš¯TÇôßÒl‘ÿÛœ´ÿş&¿ıwĞáñqã•ŠşK4Üe*j;V>°9 1Ì¥•˜P?ÓÙƒÛüË…ò”è2Hîá"^Ü^=Õ¾Œ¢Óô2VL›I%%Tßµ'Ó( ”$˜¾3#ãèCƒi8Œ#jìi|c![#_R3&I5Yh\'8^{8­ü¼¹¿€ƒtLç¬(z]yÉŒãóäì<qè¬‰™pâŒ‰Ç¤è»I­À_‘hİdDt‡ã!K%DŠC–ªh5Šıè¹®XZò#“C&‘$~ÄiûÑÑ…c}O×ùĞæöÁŞ»õ¿ù%ò¹®Ù[67E‚[„½ä”ëYZojƒ\Š7rÈÚ)H,O]Qö6î8—bo¨-?>ûgà
*Ñ>S­;S5m¿f¶Pqµú6ˆhHb“Iä•°}İ¢¶Úüµ5æ«F¶D(•2Iãù9J7¶²^sÉaò¡§öJÈÜÆ§˜?O‘´o<UuœGpiX¥ue-¦¤\€ˆ©æ€£ym™|Ôv` 4ÄhĞ¢Áë»PreˆNV¨ ÛÏ[cÔ´’nKÌÚ%½¹Dz1._¹>•7 …{áMùè²Ù&äÛÚ¾ĞCæÖ#úàğÏ£êl.{±ÃDEÆò†YÇ^á¼¡˜ó*]G`4v>;C$Õ@áÕiz·G—™²9æ%“Š5²Â¨î#RUf‹EJ!““ñ]äázªLÊğÎY2¼ü9Ûï¿S>‹jH«ú›€q¿L“(¦ËùÔ’àC*”Š(£RÿÀ¦ùZ´#nrcĞ¤šÿE¥ÍŠµ¯r“(/U¯Ÿª§#Sû¬_gdö‹NŒ@&•Q-x^s¶ë&­Î1ÊëW¸}„/P}Ç‘?Y^Øe<¡ó`‰uñg¹›!’ë„ÏİÉÀˆ+YA×¿XY3F=m®;‰ë¤C×ó+íƒN¹¡–)¿†;¬J'á[ÃV\5úsís÷åZğ<ø)»÷Ê9ûŒx•œ}ØŒ—ŞmUf«°ë–t$ÎÏq¢ßº±­Ó(°Vü5¼“Ë¢SQBlû°İ_».QJiÃÕ,Ô2‘[ŒCÑv(JåÅÑiZ»Î¸4€‡	vÇ-µÕiİä¶‘v]!\Ğxì,xÚ¨Ü‡ÃùÔ‚äY?Ü}Ïæçj^ß¬kÜÎ¿.bf£}e¤©ö˜“S&‘C·¨€Ç¬<%Ü³s¼O8^¦’c#üÅi4‚¢øå ó5êgÆÑiİu1â»,yÙ&ÌâQü®º€İˆX<ä/LuÈ¶<¿¾Wv<lÿZƒa‹­’,­İÖÁÆşÖÖNKQ)Æû_ÄÖÎîáöëíu0&îÏùápûİö¡wò`»×¹Å~JkıÕî/HÏ%ü¼½×:\?øùÕúş”¯{ëo¶öC]3pONÁ¸œe±â×}ÉŞaı·*‚Ôw:e/	
3>MÂÁ£ÿ=úÿ¿ÿ¦Üÿ57ü«ÔñÀı~yy¡ ÿ»ô(ÿı&¿Âıá;gäVOS'Ö¡#b6¨.nÁ»èŸIïF4JcñĞ!7\Ì)ùMŸ¯¸“ÑxUéˆdêVÏ&Jx™ˆ‘f»ÆF¬×`tæYğıŞÙnƒ_¹]¾²°´µ%=ÊÜÜ[¨bªq¾Œ´Ë1À<Ÿà2Ì¢§NúÿÁï£kœ!PuÉ*‹³êÃƒèŞê[¥C0%¯ØK‘Y†V_Û.+â2–·ÿ¬dmï!j3^]›@úiÊ#F¤õ1¼¹õêÃ›ÖöÎŞ‡Ãµ&<=+/z„4”ÎèiƒDuc|Je§»/v@ëğ®8L¯<Wœö‡,à`{ 5—j£,Õ'¨qC= ±¾å¹, ÄĞØ-ŒòÏÒƒÀ”ƒzb‡&º‚7«zzµz´ñxšÏë–öÜ+çÊ(ŞLCé—Ó™Š/b:1ÕŒÆn3%i3L™%CeQœ¸vîìœ_—sn\îãfËBHÒ&]KaåjF}Å› '¶¨1ŒânÅMLPÑy©`v•0-Ò¯QDH¨¤ˆ+VZE}eÌ¨z‚åÇw†³ŸßßŠhîŸ”˜êÏJ¤WçÁ3¼°kó¿i©™|ä7ç«ÈÍä=«/ŸÌ].À ×cZÁVöÙw¾Ò>q±êu–q¸LYĞ}«Úa–u_+p¬:•JMC©®–U$&–_:ŠjOf"omöƒp•têãT¹¾j.Uï`Bº†/ˆ"—½óôËÆH›}>0F²W©a2Wß •…A• ®Qy·£ız?;ó3ßå1øÊü`«°%òÆ°Şh©µ&\9¶-@»ŸØ`ädâÂ;”Jju&”küG\n‡ÎEùå­ ›¹`:ô·8Ü.ì"ªÑt¤ßË’­nö	+C”Fç]™F×†ó
ıg¼|ãúoyn©àÿc¶ùHÿ}“_şS>‚x0éÇ*"14€TÈöì<‚ğ¤ jã9¡ÓrÒgZ*ô†‹BR1Bş¸Au€â ?#˜!‰AéÊÒBuf8Š”SÑTR´G£³Ë£Ùf~ø>=˜,Td*ÜJX¹sdÒÅ	YEìÀÆFKŸÀÕ=Å^” ı‹ºªo2§e/j¨•]Êr„Òt Áü²‹z Ì6§#¦Aq2
x5^Ğ†ü²Æ©èÓÿÅòé×í­Ö»İõÍ­}ÊÓøø7ñïøgiÿØÑW©6¡ú}C\¡ªN9.R¶šméaÑdÆ‰ÈÉc¤ûb@yêÁfÜKNq1])" B‰¨˜ãìjf%8íEƒ"vCæÃá		{IÄ^Û07é c°«( 3:êgõàçÍ-"<?uÒŞğ<|ªjwg}Î¬¿Û^?Ø:Pò v6G)ıËtê¤ãiü×¤÷æZ=‰Ò³Iw[*è4} Ò¥óµ¥Îw¼ªow¾—¨³Ñ‡Š{,>Dn=œøéyõı$Èõı-ûF[Ê# ¡p2h"„+ÉÇ³ô¬Â½Jéx‹~\·‰XuçñxQíÖõg´Í„ÜğÛF]şä8Ş+k¹s\5x§4ÇzÍ7h#í÷ÿøhQáOe^‘¿ X={DY'P–+iˆŠ3¸,ñÈœŸÁe2JÓæÎÏ\ ngÈXh—Xî$Ù¯´"*!v€½ı­×Û×Œ«LöYri®$—Ê³—Ùåº{Ş—İKSi8Eh¸àáßWñù˜ş;Ók^”Ã’ôŸI^eGG×Ç76Ó‹!êËFgD›P«İ¸nÈWoè±ç¦É5ß{(Åør™ß}ÙÖgşÍüó¤ºrt|Ü8©ÔŸæ±w"]ÒòÇûÕü¼{Q¿úGs'®éÆ\u‡dƒÛÍ9›'¾ói]‡Ê›ô?CSA	q5–Œ…Èv|l³y.“ˆvê‹\d%d­aË”eªRï³ \‘öV÷œ®*¡éF§¯•²&ğ<¢oüäBP£İ*o¿â]¦JÀ 
QÂƒ¸§R² \Fƒ$C¬us »Áhµ;©Rà¨Zóv5;˜ @ÔGwK6Ø²ùgÓr4Ìãì¤¡ì¯pş­q¥?ÉğàDdÎ¢™óİÕ¯‚G¡„´;hó½—¦™>s	·9$ºñÚÎ¥«h üº+¤œox9ÌON<Âãcµ] Ÿ^5”¹âĞHõŒ++mE.0;ÓkªVÙİÒ°*]n†o››4ÒçÖ9w%ÇcsV¤¸î¢ ’“¥E«z2§ÌÛ©™4>‚åŸ9” nŞ9'e·*l¡OmO&t3™Œ•Æ>Ÿ{Â€ÚK:ÚS78€Ê¹±¿xU¢=gt±™{W}Ú›ÊD5”¦ñãÎ³ïÑeš½*‹Ü8'ÎûIsc;1øğÊ…h¬¦¯>Út$Â§]Çö@ë8o§¦Æ¾Sgd»ËËÑ9Xbyk‡6§Á^ÕJJ,yŸtâ‹ÎØñ¸”;rsê¸Š…Küµxd|ÑÂB•‘ñkàıí0KÁ&¿ËË…†ºÆZnúk¹®Æ£V\âbÇ¯ş»OşgùÌ®ûù?óË‹ËyûÏå¹ÙÅGşÏ·øø?J†¦$€Ì;Q­ÏtEWÂıX±–åblÍaØ>ÁÓ@K¬ˆ¾ë‹ĞJäŠãQ„èÄâõUlI+úWğ®ÁŒ¤§Uü° Šáyk3 ±xÔaïJiİ˜OìS ß‡Ãj=Ø¥ÄÑU’Åì’RAÔ\±<c›6%–TjÎL½ÑKî‘vFKûäV£L£¯ÔEm6µvr%©Çu¶š¾W<0fƒT¡ ª\”ª{#²ÏlE‡eíp,—u6ŠĞ8{Å49Üã¨Í<;êÇoéM6NÚYUC|wÌ»Ræg·h•½íM\ Š¦grËFÜ¢ÑfJ} ïQ ¶u~>è´ ÊpÈZ'<Œ]¢Âê8óä¬ÓİKN'—
Á†ijIv8&ƒ¸9í¥íTÉPÃ^I÷èˆ©9b¯Ï“úNçªåµ°-äº¡9ÂãŸ·şÖÚY¿uP>¶^}8<ÜİÑïïw7·_ooí·v_×‚½õMõù@^D!ˆŠø-®7¹‰vò=ÿÒìCã²^¯GâÖô=ÇõGÄPjA?;[	":) +ä×
Í)šÙ›“ïe"EåÄì¦šö2YÏÌäs´Â	°òÄh‘U^³´¾¤$³½›7±İkú¬÷×€&fPÙ‹FãTÓ:«Úu]Ø'"Hsİ>eßc¨¤fu?Å>ö”õkY‚ÌÎkŒJzì)B6–xª
ºÒškÁOepôw¡ğ‹TO9\îªøÔíEgY5t@´{)_#r08¹ÂE:^~Ş8½ì½T-•]ëTÓ¸Ôèšƒ ì|‘£¢á\pX±ÅÚyZ½y(NC>èwÅìALRšÍ"HN6-ôò×`øîÁá_»W7z<ª:kd·µ¿¹»óîoTˆ.t»…ğêİîÆÏxOˆÂ@âÆ»İ­[œ6'„‡®ro÷İ»íúÒÔ)[¿`"¥†çı-ïšãçõW`Ïëœô©õö×·[œc©Æïúõ¹ÎDeZxÜÇó¢<¿]?œ…â0âŸéw®xÙ¶ekç°u°ıw„Ç[X…Îƒ<ˆJN‹O+VK3§ÉXÂzÿ²½»ñ† V¢S¸=ZÛ»û•¶~¨³×³tSzÍ‡C)É ›Í-ĞB¢ÛÜIÕ´@ÃN$ğ^•9:Zèÿ§ÁülöŸTìÅDuÃU²ˆ×çúMUù§w"ö¿,Âu$x,î^âR xqpbp³Q{…±à¢(®8f¬²¦}Õé]H»"æ×6¾ZkÇØîªm®«^İ¯¹²{4¾yÒM5·®céTùæZ¾{TH<qŒ¹õıw/Ó'ÈÚ©}å­°Ä¶²cû&ïº1D‰H`?å±šñì
›ä¹¡™è.§Ë Z®G18ì’…şdx°ü+êNŠ«å½çœVÛÀ_èÔ=ŒÍùJ`\;o	ÚjòSÎrô	òwqàC®èê—5Ó´¯¬U]ÅøBxSúØU½úó‡¾"By©™1¢Ffñ«dFí F¯K8J¤2^3—iĞ¬²AfÃ9ÒGğ:œlh7‹ê`İ²?†ªPBÍ<Î5 3İ{v	s°	Äc£ÖÔql®´€à(øfàé¾JÎ¶ãJ8{^ô•âğÚEhÿÍ®—«Áé³gtÎ/_Ò=…{ü…ŸQ{=êĞqL[ãÒÁ9­Ô<)g%Aß”‘r˜yãøzl8yüV"*š:âF|åÄhwøz#ê>Îß,S§šÍ¸³§ÇƒF±_² åíJ %£l­şôø´ÂÓqçYõø´Ñ
ƒuí’âKVm'ƒ‰gÖ¤8Â•Æ?vV ÷ZÁLèÓôè¤zÔdöi|I@,¾y%á¢,Á|µú}MD=Eˆ5Äyd°ãy÷¦‚£sÿKÁ«Á’nº£w ã‚SÛÄ@ëx£½nÎ#?Ÿz*ã«ÃÖÁî‡Ã·z>\ß?ô€²ilS$j($•@è»­×‡„ø ƒ>zğ'`-x"MfÙÀéÅi‡ĞC¸ÇzD¸
·âùÙBÒâ²ô÷°õÿ9Ø[ßØ²¨ejy¢{#Ïº%yÄsøÅà+Ğëp$°+0~éC•¡×ô@ÕÜNå-+>¬¬Ñ±ÂÌŒD’¡R²€ÎO	Õ²ÅJÀ§}ëÆî"¸{È.RAQïìÂ Ë…¿±ŞmÍ’Í¿»4óï–V6ğbª«ÃËßm4İ?V|ã-‡†ÅÎXµac¸=<–zO!xFÍR4“3­|Äƒ6·s6«è:a”#&´5‘}âè¨J¶$oT6·àÙª;L]q(h‚I¶Ü=hk’ª–ëé
ŒH9Áµ0Jx›Ö¶gUèÅ\?<wT*	vÙ“ê ¡K]£ëX8"töÑªXÚÀ™û÷]!Øób0b6s|ê;Ñ¡–Ğ5¤Gå/Ñ¶ªİ:æ:v"–=0E®;İ ÄÇc*ì]|YUX7`mÉÛ^(d¯stU­
ÉË³_ºÄ ºWĞÀ®Ğº¬¢MqgæEâ'=š”ä€œÕ9™“«ıÀLÜULÖeÏ˜œ¥Ù²³™b–1«ÃÉi/ÉÎ	Y+B_éÀ3t„$àÔ@ë¨¢Ğ¥5;×‡;µ»í•Ì”[ó) »²2†È™$T©Dêğú­*O-´CÊ`Â¹¤
A£ÚæµßdÊÌ2dl¦>{Ì;! ÙÉ/Õq#Âº0qŸÒzªÔîúµ 5ÜÕ«X ]±=ZFÄÊ Ş¹úIÆZuÚÿBª”õóVæÛ€²ÓqÿµÌQ† Ò©;û-sxç˜Ï‰'µ¥¸
ª’µ@Á¸U¤ÑTÂ=eŠª£6GJå‚àµÖéöõ³ ·¯"Y%;rpç†¯¢ìB÷‚şÃZY’HaÆvE·ÌL£bßÎ–Ûm‹?Aî8à2êNußÂ¨`—Ù“HÅÚ7ô¯%…îVGJÏy’‰«Uà„è\¸ÃW/ÕE®½U²È~×ºMñ ›Œbù®ô°¬ÆD“æŞ’¿[6°ª‚;lĞ„˜HJ’í/ºüşÃ[ŠÚôvåí@O¤…L²„â¦™ßÓèHLîŠ{Swa™sœ©<]µÿ¥œ²–}9O.8²`ìËú\Ó€ù¢oIäÑ'ûóÒ“°ˆ8™ÿz°»4ÍI÷Fë}{úÉ*Êî«*6ŞÑ<e¶‡”{,	)İc¹Tf{Å½ºšÓ?¡QB|a´ªcˆ{Zg~ªzĞzpÎ€‚- ÒÔ:gr<R%Mo6=ËÖú›õíM§8¨
í\®ùÊîìnnı•–aoB4BGqY,wşE–š#WY<<s™‹Ô‰J^sÒóD”¸æ3Ã¡íÿ›KDÏÌæ’™9í¢¢óP‘ç¹"ÌË•ÑT“™›-Ç™{Bx¤×”s6c£Ä×E™[%EhGøŒ"Óí¡Ò†ıf\
¹TÊÈ– âÄ¹.sZğj|ÌœÏQÓd‡=BôĞ¿Ò"^hº¬»|Áû&<–ÜO\ª—)fZJ5|ïªa¡Iœw´¶=ãŞ‡!¯l~Ş+LoñºbÜÛáíƒøµ ßÅİ±ãÌÿÏ1¿´j–c~}~9DŞP¡1ÁZ-ÇŒ¯#&”I7QÉëêtTÈÚİ™—{&‘®1¥³f$'\×TïP[1˜şìşw{“á%2ÜM™L#×(Öòax_À‘{«ò=Æ/ØÑ^jÀ±±9õÚ·#ëµôï@¯õşPî]ëtKbã«–›ˆñWX9#·«İ»¨BõF-®Ï-ª}Cm—j!aêå‚Rşš±£YïráæwÑ-b¦©Kh1ÃI.z4²ˆU´Ó‡"aF /»®Jî£‹“@¡“Ÿ/ehˆ¿»‰Êuê/\äK+ÂDŸRE^•M»)Ös³¥2ºÉùù¹ÔEÜt]ÆòJûÙ_—AI‹5§cÊ^Í-‘¯lAİÛÀo2‹9zˆ-ÕÆ 9ÔÅMÍ{şâfÑ¹ïà¯! İ~‰x#dtÆ†Ñ*3’ñGÇBñ^sšô‡\ÎIÖ)àşˆû·v·³=æ/‚o<­dÓ¤t¤àvØĞÚò„FqŸ%4c¦};ñµzûÏr5w[DêO†å2ŸKŠBG*s‹•7†A´¸€ù¤ ò§‡}ßıÇ8¾û¯wÔ2—w…>º‹ìÄ½/÷uÇ¯„ñ¾§»)»oŠù¾h”®h<p¨ÌçŸè±qş„Î:Ü¼ñ(‚~”]øüäTtAÅè†d2öı}O;ryıê?·rîÜÒ¬_4¾_î°S–³#×–(uÇ¥›tˆZt¨‹bJy—ü< ×ÁöŸöpx«˜â%+€¥€ã4¬e‡ÕªwZ)ÊS1¡šs&HwTlhô×î’R}gE‰ŸA%”˜æSQUü;;Je­¢£Ähµ8×L:Ñä×¬DY‘­[ïvd¼àhowØf	ÜLoïÓ8ÏÑ`¯ëE-Ö5ÏJXTpÕ–RJÍÕË.igÛ=µ¡mğ¦óv­Ì 6æç1d5§£»Îs2×£-m5Y^ô´@†ôœŸÂ&´¦ææ´şAİİ+î qÆf‰6kmüÚÍûõƒŸÙ!€0ÊÑ\ÁÍÜµ\Eò>æœåÂÎ¹rSXZÑ¨“ ¢)ïÉì;Ñ¹±Ÿ™|Qûèğì÷KüŞ‰h°ßTÂo³ˆ
á êkiœ¾–à~SáşsúJI”U@™—
+E!Ë2¤
¢ğçç0’€!<8“tàĞTšê®8Õ‡KïºøÚs#eEuçqû‚¿¹TúGO',uöïèÎÚÇº ÜÇâ‚sú7är(ıSnÎ;º¨¬0Û­¤¡Êi.A2²|T÷!n|ş6¤{Kï¹
É•M{²á¡¹w95_ÔàŒÎ•œ0æcİnLn£Šî2K¯43×*KZÏYqÿ7å:™NéBWó:QTT Ê	~ô[:rß“A*j³n]#·2—¤-«å(·–,î}^—2O¡	î%é¸C9Ì ğ²\Í%[‹5¾e…ªz9q¥w˜<'éÍEZ›‚&[úSX-’$TÎçÎZmÕxPØi(·=gŸÛc˜&bi‰‹%Ô&êÖ¨jsäP®,¥Mg¡¡|ÒÈIX£â¿/ÕmVsÅ€n—4åÒªvÆy[˜·Ö˜-Á®J:k·×{=:n‰²QRñÓï-Ú-×š4•ÏøÕiU?ºjyBß¯,n ­êJ%ÉsÅ| Ë‰Üœ¯¿êyÁy^t—àXtyö£«[DïyÅŒ®»Û=hÔö	¿£,–ñ$dWƒ§÷×¦u²Urb»£'S¤¨"zÍT	ßÎ·ô¤×…?ÇıtQ òQ	Ú8ÙKÅo,‘ìÖs—§ïFUĞqæ‰£üeqÉÇ¾]Á_‚Ùëå®…exãsÏA@iBoAnˆzò…yà>1Ì€ÊÎFïÌõØÀ^æÑ†7%UÌè6¬ìĞ©×#DTµfo€ŞƒsFåùáñå´¡Ò½Á¦êöJX<&T(+UBçèñÒUA´4/Š™6a¡¨4Uz©Zg‚ç†Y¯Äª|IÒ2®ğzå‚=Gpv-×òj7írŞÍ°˜oŞÒÔæùV^ª¹ö=Qjã˜ĞÉ ~:"-MéÉkÚ¢zúr-X`ly}±,J¡µU_?}5Ò™ÓûGfÑÌwö_}p\FVÿ{èFm˜‹”š,‡økˆâ˜Í¦…†=q³jâw?†.•ˆ$<‚xOÌ(Ù!Ë]]ŠúëÍÕÛı¸bawzU§^­î‹ôV1ÀW¿Ë)}¡}0nò¶»yBqÏ%5U?WÕ¤T§ÄU°B¸˜& ²T¹X·ec-Ñx†x3?Ñ­s%˜u‰~Ö-õŞ÷ğbÒ®á¿Yr30£…ß1Zø !G®>q;¬x‘HIï3ŸÕb­¥2P»pâŞ™«H2ó ?2H·? ÏeÕÕXÅ#vãH"†t•!à£Ã³³¸ŞTàS>iÓå>JÆè&qKÖG£è†_Î	;ü.ƒWY¨VÍ}•€ÔÔ0£O#\Í=e}®Ÿ¨èRœàÎé[òvkäå­Ç*jvÅF£WáëÔèCÍìBŞuvc‚‚ŸG—±²Ô$ºEYVã*g‡Ñ É?X•°ºÊiá¸º¡­•z¸	™=ZïIHŸq·‚—¬ıxÇr÷Ê·ZĞÏ­O³ïYXvy‰Ù1àÜ­…!zËœ!jaî°0«ïœ²ìÿœYLñÿ`l‘¿Føÿ\\^œ/úÿ|ôÿğM~%şß‡™òî(z‹pP™vî¨Í)30Û:“¶`;." Í‹Ì±>+obĞ(°é9¤ê¯¬|8Pá¾Å<Ìl@<Á—À«8e]RŸm,¬D¬Rp9Xíã€fŸÔ”Û*jJ7ê'½„fz`ÂÁÁE“NA^ú+ïÏ‚çÆå€¡L•ô¶¹„[Y›İ8Âd“¨‡yú;GáËqş.Òßú»Déï2ı]¢¿Ïéï2ıı‘ş>±ÙÓÃx ÔY†ÙĞ¤ê öÂê£6ˆ•&àF§’•üRQË¯x@5ˆRÒD=H2‡zñ€zş†Ôò¨e¨e€¾'ıì#¤ö	6äx|‰?K™çQÉ:F•à•lâ•¼Æ*yƒTò¨â¯x@?ãU¼¨`Ø?à°?á°uÜÀ?>æ2¨âïHDñ€*6ğ€*~Áªx…T°ƒCïÀ"ª¨!UÔñ ğ<,8•.şÎ¤Ï* ‹¨CBğ.¢–5U‹¨iƒVÕ»´}!àQåk`Íê|¼YB•¯9K¨ó5ã°‡]„¾ş,¡Ê×À %Ô÷8´„ê^‰–3dA£¥Uë¤â`•´Gt^™¦,7U@\S/ º<¯^ wyA½ÌH)İo´ryI½0š/«´uù¹zy&¥t{Ğóç³ê®[ş?×­˜Å‹nÅf,(ö|IÍsğœ{İd`Òí9Îñ£nÆÑ—?ê&a.Dƒö`›*: ¼gõ,baÍ¢-oÓ>/¹Y´åÃ1{toP¯V?ÄêÕD±Ìë¥ÃßPı¦X7gT@tïÛƒ,1 Ş6ÙøE ñvğ~2æÖğ–ğKÚ›ĞíÔ X´ih’Z O9xe#@4—œg4r}g»ìòYÊòè¿nÎóÂ(Ø\àgFÂæ"?36—øY¦d™ŸeN+H‚ò¼Ñı(H?ËÏŒösM~fÄŸ›ãg®ykş‘k[`H8¡ØŠ@éQ›%ª	Ø  ×‘ÖÔóà&¢÷I‡ÈJ•ª ğĞ0vY•wA§½NGWÑ¨c2/>pò’ƒùªs¦ Ã”Åµºé0ö“´²0³Ì'ĞôXƒ°¦e¡qOìóœSÈír¡g|&¹€­qÅêâÊ!eµqå°²ª´rh9š¶¼şrãôcqŒîŒgÇ{Kyß¤Ú•Çº¤åihíÑ»8V WÂOzUÂ@©ò’ääµ"3”Ş®ÆzøÍY5vl Kp»´EÕq.3ÈÇÒ¶ˆ¸WIó*i'™l*í×8k¤àSìtÒÆ#5zH\6‰v‘atôUn¦«‚h²C×ÖìS“èÃ÷ÿ4ãNŞX§¹Yç˜(=\Î7ÇÄV½UIs*É@›c‚Á({3óp´Æß¼avÇ×Dı,Œ`nèrc–*Œü¡É‰wÜî{ı>ñ"İQ«ÂFÜZùlNŸİ¶jî 
§¹Nü
.¦Œwˆ©õıoÁ İ ÿwŒ/ÿ>·´°øÿı[üòóŸã¨ßî}½èïİÿ›Íåüıqvvîñşÿ-~Åøï@ vû1óËæk¾«¼¦%0Šíõâ‘ñò8(ÀõüÇÒ‚üaŸÆíeğ""ĞE`~tb+¯0
"üÁáÅã™vÚ'ìülxc¸¨ >´ìh/P@+2
ìFî4öz§Z88 ïƒ8 `Ò¸²K‘31ØJ:HG‚>FJTiÄ÷Õ0îõÀáÈRíœlJ$:„»ÉYı²Ó“m¥ŒÆ3ç7PY§“öùŸˆ3‚ŠvOƒöäÀğN"ğ²Å5SÙAŒDÂÀÅò!c×í(]Ï9ªŒYmç'$8‰¶/±r	vI#ÌyÇxå"-QÅá†çdÍÚ9g%	^v?’)Ï# y”œÀ×³g.w\}!P#D)I‚Õ¢I?8\—„mVx<´5É5²»|p+× g”ëR¾I?„?8²jÛtŒ\¦,†Êûî6ÏƒRÒoºn£÷åİÌn$agdV,JÛjÂ¼ê˜½t©¤±$±!_Û-— ÜœMQ2\'U={f*º+‚"¿2;¶ÅÉË“ÆÑqv{£¬Z·gŞÒÓß0ocè9záÃ|wK%
,®xâ™Âá–3HÇ«\§¦W˜R‚MDBŠ’H<`C,ÚÅCGT\˜İ»Ğƒ^ñ4êEğwïàZWÁclv›¢+pÕúƒmwüÎ!@e:è°WOx
t»É5‡¼ˆƒ£ïİŞ™Ÿ;ác„Ä§/|÷Ò„ÑÂë'êÓúuôğ²<Ñ«’ÿQí›>R·2RÈkœÉnG3®ÄG' F×\NíÊ¬w=F	Œ» 8ÃÒªˆ×Eå>«¢Œ#FƒM‘ú¥ıPu´@­Ù™6äò?ëªíŒ£S^"´$ëâô¯ÂùDk$–%äH¨ x”³¾`dYĞYO2€^VÙ9?ÖÓ§ïoQÛ]øı-õ³rQ½£½A¥İâÉ6øR·–¶—êÊsw<ø$C©ÇzÔ1õF^/¹’OZfYê£éŒe¬—ÏãDSÇã7^‡-)é¢Äc>e÷S«&nÒëX¸µ MÀ8vâ8ˆş-9líFw™5}LÎ,˜utr²*dtÓ’L¼Åüyˆá‘Œö^üu"ØH:QïÂ¶ óš·ÚD´g zŠ^'MÉU¥%ÃèQ0¯Ğ	ôÕ×Ëe½ˆÔ+XşµÀÒ
eû.KıYÖÛ×3”"ø©4ìÏ<ú Ê«Ï#·b¿J5lãtÄAj+†Äsk§Ï®ÛÁ#ä¢#ÆÚ'yO]&—lT“•ôŒÈeà9Hı7İ´G4aòê¦å…œVÊØI[=åœU‹ayOƒ]ãQ0§!ÖëšÙ-Æ\µ¡ö¦$¾útawÛĞ»F¯›§BŠûÆ­cU¯Ömš4£ğ*O{b²Ó½2Í+¨BQ—Z½ÛS9—®Ë(Ğv¸KÑî¤)U~øğâb9U€8ñ‘
Ûø˜îìñ­¡°À¨°ö(b¡¯Hµ»é‰JäPéıíGƒ¤KÄMëû[®ï®NåtLXq$•ÕÅX’ç¾|ÉÑ‡µŠÊQˆÀX$ª±´á ¬ÚĞõ·eáÑu	Ì‰šiD	Õu‘>ûZ‡O(%ßJcÚ1aû&DØ7È=P±uÕ¨4à¼ñpa±%Zˆ¥Î¨G‡¯«ÆÙ-×¿z/˜ğ0Ê¼y÷ıŞúa‹ş‹ıB!tzƒ×öÁ8aÔÂƒ´;¾Šäù—ˆ6ND§ğ°Á·ÒCº¾Ç4z{ìJØhp)ø§F.aŸYm5öŞ™f´ù8™²»ğ¦nqÃé¾Š$"h¬ 'èÖ¯iºHš_VD)qÆ6¡F$k4Ò3œ?ñ9…Î)‘¤>ùî\§kY_atÕ™WîÖK›ÛÛİÍñÇG‡Ú¾KP­Zr+p8ˆaá\;DÃ­»/ø§q@*òæX½Æ]hÖ‚ªÓ[Û°©wˆ.Ş¶½YwŠ§ƒÖM-dÂe"N(Áäß‡£$%r’§pnq6<99Ñã„F½dRY5ìˆRà‹‚«[•£E·YH0|pÚ…hŸP¥Yv%£ëùšYñ÷ùJQ gä‹CÒ©%KDøÌğÏ!æa}”½ŸÄğ6/Áß]ãUÀî¾â+õ3”È4ü*ÒÏ—LÏ!Cd;q¼
 ‹D®/UÓ6İ¸Z†S¶ÎuM9fúœù4;’¨C—Ë“xØÒ5KQÔ5R³CÍîe5KX+ª£Ì¬÷£DÜ–H¥.ºµûm²ê`–6ºæp‰rt.wxdW	›«ÇƒÅFs¸bˆBÖËÖT•S§¾wJKïëd\¡ñå’:Ü¼5o™\™åBçÔÛCÔ­®<¼}æÉÊ
ªÕVZÚå4‡+Ş¢}B'îFˆÕuÓcÍÙ!$HŸh !|´MÔİwe¦C9`Ê÷;JÎÙç]™ÿÓ¢Çßÿ)Êÿøï×şıŸ‡äs³ssË9ùßÂücü·oó+Èÿ9ÚndÔj74‰|4¢ºd0N)‹h	ÓÆ£b9¥£-|'L€˜dBÑ]¯rË.õ6“Qf4ˆ ÄÏ¬xÎOLI@7ãW\¿ˆáqpÇ²·wÛ+²£i,fDØø‚ğ’^ààE¬âImJ:W"¹T ¶ÂïhfÆ6@² Í˜QĞÁ‹KILº3ƒ8îÄÕß¶K/#M‰k5ß¬/×—él‹ãUÇÉ‚ëğğQœòã˜ğ4®a®—ä­œN’¼ÄRã¸ÏcÏbÂìŠ>@Ig˜ñÚ p\QïˆÌÆ'8Å—I:Éz7Fk ;Õúwßé{®ÓUV›Y±SçX¼?ëkn–Ğ%DË¤³šepİû?.kT|i„+)~¤´ƒÃõ÷{`Kƒû×Ãà×á -tï¼ítxCCZÉFmºçgŠ‰_ÏC&Auzİ:·'4é—*:0¸Ï£V,ìMLüa›êÑe|HsEK£?Ìt,aÅÂïEYìaøùŞ°)y'“[¸ ®ô“rVT HfùÂÙçÜö¶Ñ-C5RóÓCÌì®ÚúÙ™°Qz¦Â} pUAÍ¸şóTNqjo†¶›•O‚q´³…ÄŸÅ×9aí÷·~œkf·Ş­P:*¼;'ş®£%R6bMjsJ•ÊnâqİåbI+_M–ëQß?«­X»ıÓälB+#¨|ËPîˆ<W#öpt0]ñŸr#Ê·&5'0ËŒĞF¦Kä½:ƒSî}ê*`\üA‰`nqix­®¿â˜ëô‡,ØŞØ•]‰€RövŞÙ Ú‘¶½
êI;­:âxÂÕQÔïÎ^Òşv;­P‰Õ;œq<Ä\Dä<vªüÎenÀ> =ÀF®t3Qû‘1N‹E `Ëêræãôy‰OƒÄåúÀF¬s$*w46î§,ùgìµ…q+^­)7É%›s†¹ß_±cbâúù‹³ñÂ2_Ÿp¿¨	W„x®_ÑE^uö6¸ªqc¤R?9ò¯ŠTP³A[T=›œ²&F…ëa×nú	ñˆğˆÊÊïŒ–‡ÅçÍ6´Š9´óØ÷L1¡ v›cš¢S9¤N+nİ
VLu‡€Şd'¾„èÅ¨´z¤C’ôgæ{ÚƒÙµÛKiyS†¾$Wó1Ô“ìÃğ0…á4âÄ§A¸×yÖ&8*¯åŒ; .èÂ˜Ğ>ÃªyQ‹Âe‰şàÔxÌL4®îvBÇóö	I9£U›Ë¤¸YÔ(û¹TâTV©Á^Ÿ[ú5¨ÃšŠ’ê\ÌõdYòaOŒ/@Î)œ8¬:í8q.sòátĞ%ï‚NËYÆp?¹2İ¯­SğÆ)×…‚£_LçTæä_ßÛ»/k:iŸ;NEJé"Ká=ß)¯"êø`k<oP™vS_×{=3¢5´Ê5.¿8ûÜ…Åm#¢±}ÅB÷å–šäMâguE[ğ¡­*Qµ:È¶ëä˜ @|ë£ujõØ„&OüsŠ¨ËÏÀ@ˆ±¦ŠâDAgg¨t:ï³æMêÈSÁ¢D1TÛéT\ò‡F7‘a×–ß;ĞÕr²£†Z¥€ù¾A0ëC8+rfo÷ÓKLŸºÀÎ°"ä)­0:Ó8Š{<Üı°Óëe¯ÓÑ_£ËH<\òšÅ+eÍ„–ğ8³ÆÿÍ˜Îj´{ÉÌU2˜Ÿ›¹^Z(ÍÙI²v:êü–5zÉé9øV^Ÿ˜1°.½ÔÅ†İ	çeÜ ¦¨fœTKQƒ—
õús‘Â+jŠ |{xFõŒÄ"[üg—RØ¼ß¼)ƒ¼];ÏèÕÌyÒ±Ëcj3½2²ÃÖ £Ïm¿ÅSöaó
…ıİµ´ªs‡¦:“2wàF(Ÿw‰®ö/ZB%E˜ µ4¾½¶€NåSè¤ùù¡—ˆbã`‘È%@³Mø´ÕÇ„ìö Î·Rí®h¼w@ƒ`˜&5Ïä¡}ÿ-«3T,¥™³Á„]P° ıÖßr´ÀSY²tB¯Şº`&P¨{†ÑWN³œ˜¶<~WÑNZVèWè’ÍæfU©Òwãˆ( :Ñ¯ºÆ´…fğs¡}rÑÿ8‰DˆBZƒ«oœÂ,í„~UeêÄÙÅ8îˆ4;tÄ‡ÂñPßË5Ÿ:.sé©>ñèçhÎË$›Ú`ççè4Ï&ı¡xÜ!ËÇÈW˜røÚ=Y“£_3§¦ö_-âQ×Y9€»“Lœ°^N0Ğ¬ÂC ¼Åíqf8•ÍÙF³©ÕAq—^	~à3t'«<ÍÙ£¨ş,í‹£“ ³Ÿ“&ŠÎ››ímÎào*zSr ÀêÆı¹œLªF¥ñô¡İÕòƒ±7JYîšÓÍ˜pËè>O{‘Úñ 7ä*¡Äğ8²˜È%8UÏrƒ¡HñÖìõ|wqqa©N|á¨/jxÁ#ºE!Âv‹J)=ìíï¾Ş~·ÕÚÜŞ7Ée=ÿBğØĞ„2€‡½¨d÷V¨¥31%Ÿe±#Æ>£Ô·=Åx]snÔ9¼ÜFíT]uÕZŸtë`æ‰¦#ryÈ­‚ÌÜH;uÜ›Îß«'ƒvoBkÜ×Ø@%©Û¯8Ñ9/¶%Ï_<òğì^eÌVçì»ö&½dÌD<İÖ»VDËyşÆiªQì6‡dÜYa{iİäa:¬°p<Ä,Ç)Ò8B™ÆI#WJ¯nõ‘Ùt÷V¾J®éc_ÍäJN{³ñÛYhä-wvù¦X€¡áĞxºT¶B¤ÁO‚;¯½_\'´*B)yŸªzèdÖç¶töÄÜéó¬@†Q.Ë”+ªY&Áé–TD¾vz6H²¸³*\Õ?È‚å¨xèôÑ¬Ü¡s‹øåò8XÚmXEÎ=®Æ"Œñúx…ûÌ¬j}œnì*†R³áŸj0z»Š†,Ra5š›™ó¡éÉôŸ›,˜ğÉ€\ê1{µ¤ƒÃş®lôJ½ï†ö:ù6%}&-W¤?5@T„fı¡†•è<ól˜Ò´A\BC¥‚Ğ²œ  .ÂÑ[ÒéÚ,Â9ª9l¼š+jù-•ht–İ§‘¢ft8<OıúşF?A¨3A³ÛÕÎU_‰ÃûçÑ†cĞà 1¡+-7×t(Ğbâ¯ ÚJ(rNÁòƒÌg•¤sh²İ|W¤½|õèg“Å¦ê|GVårå¡’Ïs~’ÖU«±_Ó›m§JĞÍš¢C2ÒÈÊŸ‘îşQ1®V-Ñ¹ó˜¾è§šl};pBV	søÊiÕQ\r‡ÂÉ$múÏFÕØ«\Ç7Ì{_v8¦´U¦Ìü\ÑÎ+½*Ö(4}r£éïŸ´ÚçŠ]*Ö—(üT”]ğ zgşduåc	ÚìsµZ6àºAßü—×ÿQ‚õ¯ZÇCşÿf—óşšóóú?ßâWôÿ—’~Ôck;‰ƒöÍ¼‹†ºwà¾z‡™«U£ôÃšßDËNæç‚…şsN¹ˆMÚD&ÿŒO†üL }UØWãğ!Ş!l XCôA¯—^	™É—(ÜhàtU^Ónw<±{rPî	•õ+=’4£Ÿ``ıhtApÃÉ \Ú¸ƒÊ…¾ˆFíszyY×¡î¡Vhù!ƒ.ËVmYğTaØ0ê0Z*j›%dÆs0ı‘*¨ÈI‚[ï¶6÷wwZûvZë-Ä÷­BW4(UÈ¡*GÙøÏXò;¡ê£Î[£J×3 põÕ¤[î`_İV…ÎìÔtföbû¼æy
–	é¢Îç‹×
¹Kêµ`J`ÊqlæšòB,Ğ¢l“ÿ¡¦ø‚([ÌÈÛ©»ğ­«@ãÎ¡.®Êˆº İV"^GAg|rRê,êÆezšõ|ÁºwæGlq=‹C›OfÈÎ2ëßCFÉ™§?SğxXbïñIV?k–À‡îPˆŸ1İÆL~K*Ò!gR›W(a™Ÿ¬±‘ştD!Âë
µs¡ä¾Ø( lIa²#U*)J.¢[]i8*7Sò'†£øÃHÜúš9„&–\’raº`Í‰y¯Í®5¤òÕ‘f«Hñ´Qeãª(dl5DFİŞUó6“üË§±GÈ¥‚£“Å²^s	a	œBóÏb‚ğ4¾¿Å_£÷d;-:{Ğ€Â¿šåÇU¬ğŸ|Afƒğ2´#.{ÄGÕ2¾#
oZÔ}³"?6(ax~5n´ ®­—.Ê¼^(¥±B›R¬5yõĞú`['èå¤û­Ïnú(b¯ÑúL“7êë›Q×èö,UCWi2¾¯ézaÆ
Â”îŒ»Æ0*ù
ÜI°L7æ:´ÏéjmG6]^\,6­8ŠJK`âeµå´xdúĞ?0y;`Æ¬ÙˆvN%,=X“•ı,Ø™ôOiMKBGø¨!~#ŞnaU€?[+œ:§8oğQNÀ`F¿p•ÏøÍ^`ñx1˜[°'[óL‹ˆÇøS"¦=LÖÖ*ÊY>0rëı,Ô`˜ÓÓ»±’WvE¤ºb®_e»{Ou&÷ø{ü=ş¿Çßãïñ÷ø{ü=ş¿ÛßÿİM h 