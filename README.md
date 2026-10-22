# Crosshair X Linux Patcher
 a patcher to make crosshair x work on linux natively, (No Wine/Proton)!
 unofficial and not affiliated with CenterPoint Gaming.

## Instructions

```
git clone https://github.com/Blazzy12/Crosshair-X-Linux-Patcher
cd Crosshair-X-Linux-Patcher/
```

Install
```
./install.sh # after restart steam
```
Uninstall
```
./install.sh --uninstall # after restart steam
```

### What the installer does, exactly

Everything in this repository is readable source: no minified code, no embedded archives, no prebuilt binaries. `install.sh`:

1. Copies `src/` (the Linux runtime layer), `patcher/` and `installer/tool/` into `<Steam>/compatibilitytools.d/crosshairx-linux/`. That folder is a Steam compatibility tool, the same mechanism Proton-GE uses.
2. Downloads two upstream binaries, each checked against a pinned SHA-256 in `install.sh`. A mismatch aborts the install.

   | What | From | SHA-256 |
   |---|---|---|
   | Electron 31.7.7, the runtime Crosshair X itself is built on | `github.com/electron/electron` releases | `00a2e8e5…c84b2d47` |
   | steamworks.js 0.4.0 Linux binding, with Valve's `libsteam_api.so` | `registry.npmjs.org` | `877815e9…1b131943` |

3. Patches your own `steamapps/common/CrosshairX` locally: it unpacks `app.asar` and makes the three text edits listed under [How it works](#how-it-works).
4. Selects the tool for Crosshair X in Steam's `config/config.vdf`. Only that one entry is touched, and a backup is saved as `config.vdf.crosshairx-backup`.
5. Registers the `crosshair-x://` link handler (`~/.local/share/applications/crosshairx-linux.desktop`).

It never asks for root, and nothing runs in the background except Crosshair X itself. It also turns off the app's error reporting, so crash reports from this unofficial build don't go to the developers.

A note on performance: this is the official Crosshair X app (an Electron app) running natively, not a new app. Like any overlay, including on Windows, this project is for people who want Crosshair X's own features.

## How it works

The app's original code runs on Linux Electron. `src/bootstrap.js` swaps its Windows-only modules for Linux versions:
- global hotkeys via evdev / XInput2
- game detection via `/proc`
- controllers via evdev
- the overlay as an always-on-top X11 window

Only three text edits are made to the app itself (see `patcher/patch.js`):

- skip the "Windows 10/11 only" check
- fix a profiles folder path written with `\` separators
- let the UI show Linux process paths


Build and Run
```
npm install
node build.js /path/to/CrosshairX ./dist/CrosshairX   # the folder containing CrosshairX.exe
./dist/CrosshairX/crosshairx.sh

```

If issues with keybinds
```
sudo usermod -aG input $USER     # then log out and back in
```
