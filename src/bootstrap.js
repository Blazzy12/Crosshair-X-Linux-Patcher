"use strict";
// Linux entry point for Crosshair X.
//
// Installs Linux implementations for the Windows-only native modules the app
// requires, smooths over a few Win32 assumptions, then hands control to the
// original, unmodified main bundle.

const Module = require("module");
const path = require("path");
const fs = require("fs");
const os = require("os");
const child_process = require("child_process");
const electron = require("electron");

const SHIMS = path.join(__dirname, "shims");
const APP_ROOT = path.join(__dirname, "..");

// ------------------------------------------------------- module shims ----
const replacements = {
  wineventjs: path.join(SHIMS, "wineventjs.js"),
  wininputjs: path.join(SHIMS, "wininputjs.js"),
  xinputjs: path.join(SHIMS, "xinputjs.js"),
  ds5js: path.join(SHIMS, "ds5js.js"),
  cpgwinrt: path.join(SHIMS, "cpgwinrt.js"),
  discordjs: path.join(SHIMS, "discordjs.js"),
  winreg: path.join(SHIMS, "winreg.js"),
  "node-hid": path.join(SHIMS, "node-hid.js"),
};

const origLoad = Module._load;
Module._load = function (request, parent, isMain) {
  if (Object.prototype.hasOwnProperty.call(replacements, request)) {
    return origLoad.call(this, replacements[request], parent, isMain);
  }
  if (request === "koffi") return patchedKoffi(origLoad.call(this, request, parent, isMain));
  if (request === "@sentry/electron/main") return patchedSentry(origLoad.call(this, request, parent, isMain));
  if (request === "@centerpoint-gaming/steamworks.js") return loadSteamworks(() => origLoad.call(this, request, parent, isMain));
  return origLoad.call(this, request, parent, isMain);
};

// koffi itself works on Linux, but the app eagerly binds kernel32/user32/
// advapi32 at load time (custom system cursors, registry writes). Hand those a
// library whose functions all fail softly instead of crashing on startup.
let koffiPatched = null;
function patchedKoffi(koffi) {
  if (koffiPatched) return koffiPatched;
  const fakeLib = (name) => {
    const fail = () => 0;
    const declare = () => fail;
    return { func: declare, stdcall: declare, cdecl: declare, fastcall: declare, thiscall: declare, symbol: () => null, unload() {}, __fakeDll: name };
  };
  koffiPatched = new Proxy(koffi, {
    get(target, prop) {
      if (prop === "load") {
        return (lib, ...rest) => (/\.dll$/i.test(String(lib)) ? fakeLib(lib) : target.load(lib, ...rest));
      }
      return Reflect.get(target, prop);
    },
  });
  return koffiPatched;
}

// Crash reports from this unofficial port would only be noise for the
// developers, so error reporting is off unless explicitly re-enabled.
function patchedSentry(sentry) {
  if (process.env.CROSSHAIRX_ENABLE_SENTRY === "1") return sentry;
  return new Proxy(sentry, {
    get(target, prop) {
      if (prop === "init") return (opts = {}) => target.init({ ...opts, enabled: false, dsn: undefined });
      return Reflect.get(target, prop);
    },
  });
}

// Steam integration uses the Linux binary from upstream steamworks.js (the
// vendor fork is Windows-only). Upstream lacks two calls the app makes;
// polyfill them so those code paths fail gracefully instead of throwing.
function loadSteamworks(load) {
  const linuxBinding = path.join(APP_ROOT, "node_modules", "@centerpoint-gaming", "steamworks.js", "dist", "linux64", "steamworksjs.linux-x64-gnu.node");
  if (!fs.existsSync(linuxBinding)) {
    throw new Error("steamworks.js Linux binary not present; Steam features disabled");
  }
  const sw = load();
  if (sw.__cxPatched) return sw;
  const init = sw.init;
  sw.init = (...args) => {
    const api = init(...args);
    if (api.achievement && !api.achievement.names) api.achievement.names = () => [];
    if (api.workshop && !api.workshop.deleteItem) {
      api.workshop.deleteItem = async () => { throw new Error("Deleting workshop items is not supported in the Linux build; delete it on the Steam website."); };
    }
    return api;
  };
  sw.__cxPatched = true;
  return sw;
}

// ------------------------------------------------------ child_process ----
// `tasklist` is used to list running process names for installed-game hints.
const origExecFile = child_process.execFile;
child_process.execFile = function (file, args, options, callback) {
  if (typeof file === "string" && /^tasklist(\.exe)?$/i.test(file)) {
    const cb = [args, options, callback].find((a) => typeof a === "function");
    const procfs = require("./platform/procfs.js");
    const csv = procfs.getProcessList().map((p) => `"${p.name}","${p.pid}","Console","1","0 K"`).join("\r\n");
    if (cb) process.nextTick(() => cb(null, csv + "\r\n", ""));
    return { on() {}, kill() {}, pid: 0 };
  }
  return origExecFile.apply(this, arguments);
};

// ------------------------------------------------------------ electron ----
const { app, BrowserWindow, nativeImage } = electron;

// Linux has no ICO support in nativeImage; use the PNG extracted at build time.
function icoToPng(p) {
  if (typeof p !== "string" || !/\.ico$/i.test(p)) return p;
  const png = p.replace(/\.ico$/i, ".png");
  return fs.existsSync(png) ? png : p;
}
try {
  const origCreateFromPath = nativeImage.createFromPath.bind(nativeImage);
  nativeImage.createFromPath = (p) => origCreateFromPath(icoToPng(p));
} catch (e) {
  console.warn("[linux] could not patch nativeImage.createFromPath:", e.message);
}

// The display picker asks desktopCapturer for screen thumbnails. On Wayland
// that goes through the xdg-desktop-portal (a "choose a screen to share"
// dialog for every call), and the portal's sources carry no display_id, so
// the app never matches them and keeps asking. Answer screen requests from
// the display list instead, with a numbered tile as the thumbnail.
function displayTile(index, display, size) {
  const aspect = display.size.width / display.size.height;
  let w = size.width, h = Math.round(w / aspect);
  if (h > size.height) { h = size.height; w = Math.round(h * aspect); }
  const buf = Buffer.alloc(w * h * 4);
  const px = (x, y, [r, g, b]) => {
    if (x < 0 || y < 0 || x >= w || y >= h) return;
    const o = (y * w + x) * 4;
    buf[o] = b; buf[o + 1] = g; buf[o + 2] = r; buf[o + 3] = 255;
  };
  const border = Math.max(2, Math.round(w / 80));
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
    const edge = x < border || y < border || x >= w - border || y >= h - border;
    px(x, y, edge ? [255, 120, 20] : [38, 38, 42]);
  }
  // 3x5 bitmap digits, scaled to ~40% of the tile height.
  const FONT = ["111101101101111", "010110010010111", "111001111100111", "111001111001111", "101101111001001",
    "111100111001111", "111100111101111", "111001001001001", "111101111101111", "111101111001111"];
  const label = String(index + 1);
  const s = Math.max(2, Math.floor((h * 0.4) / 5));
  const totalW = label.length * 4 * s - s;
  let ox = Math.floor((w - totalW) / 2);
  const oy = Math.floor((h - 5 * s) / 2);
  for (const ch of label) {
    const glyph = FONT[+ch];
    for (let gy = 0; gy < 5; gy++) for (let gx = 0; gx < 3; gx++) {
      if (glyph[gy * 3 + gx] !== "1") continue;
      for (let dy = 0; dy < s; dy++) for (let dx = 0; dx < s; dx++) px(ox + gx * s + dx, oy + gy * s + dy, [235, 235, 235]);
    }
    ox += 4 * s;
  }
  return nativeImage.createFromBuffer(buf, { width: w, height: h });
}
try {
  const { desktopCapturer, screen } = electron;
  const origGetSources = desktopCapturer.getSources.bind(desktopCapturer);
  desktopCapturer.getSources = async (opts = {}) => {
    const types = opts.types || [];
    const out = [];
    if (types.includes("screen")) {
      const size = opts.thumbnailSize || { width: 150, height: 150 };
      const displays = screen.getAllDisplays().slice().sort((a, b) => a.bounds.x - b.bounds.x || a.bounds.y - b.bounds.y);
      displays.forEach((d, i) => out.push({
        id: `screen:${d.id}:0`,
        name: `Screen ${i + 1}`,
        display_id: String(d.id),
        thumbnail: displayTile(i, d, size),
        appIcon: null,
      }));
    }
    const rest = types.filter((t) => t !== "screen");
    if (rest.length) out.push(...(await origGetSources({ ...opts, types: rest })));
    return out;
  };
} catch (e) {
  console.warn("[linux] could not patch desktopCapturer:", e.message);
}

app.on("browser-window-created", (_e, win) => {
  try {
    const iconPath = path.join(process.resourcesPath, "resources", "logo.png");
    if (fs.existsSync(iconPath)) win.setIcon(iconPath);
  } catch {}
  if (win.getTitle() === "__CROSSHAIR_OVERLAY") {
    const ok = require("./platform/x11.js").makeOverlay(win);
    console.log("[linux] crosshair overlay window " + (ok ? "retyped as OSD overlay" : "left as always-on-top window"));
  }
});

// Electron's login-item API is a no-op on Linux: implement it with an XDG
// autostart entry so "Launch on startup" works.
const AUTOSTART_FILE = path.join(process.env.XDG_CONFIG_HOME || path.join(os.homedir(), ".config"), "autostart", "crosshairx.desktop");
app.setLoginItemSettings = (settings = {}) => {
  try {
    if (settings.openAtLogin) {
      const exec = process.env.CROSSHAIRX_LAUNCHER || process.execPath;
      fs.mkdirSync(path.dirname(AUTOSTART_FILE), { recursive: true });
      fs.writeFileSync(AUTOSTART_FILE, [
        "[Desktop Entry]", "Type=Application", "Name=Crosshair X",
        `Exec="${exec}"`, "Icon=crosshairx", "X-GNOME-Autostart-enabled=true", "",
      ].join("\n"));
    } else if (fs.existsSync(AUTOSTART_FILE)) {
      fs.unlinkSync(AUTOSTART_FILE);
    }
  } catch (e) {
    console.warn("[linux] autostart update failed:", e.message);
  }
};
app.getLoginItemSettings = () => ({ openAtLogin: fs.existsSync(AUTOSTART_FILE), openAsHidden: false, wasOpenedAtLogin: false });

app.on("before-quit", () => {
  try { require("./platform/input.js").stop(); } catch {}
});

// ----------------------------------------------------------------- go ----
console.log(`[linux] Crosshair X Linux bootstrap (Electron ${process.versions.electron}, ${os.release()})`);
require(path.join(APP_ROOT, "out", "main", "index.js"));
