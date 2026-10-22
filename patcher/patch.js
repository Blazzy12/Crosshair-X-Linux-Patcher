"use strict";
// Turns a Windows Crosshair X install into a Linux app directory.
//
// Library:  patchApp({ gameDir, runtimeDir, layerDir, steamworksDir, portVersion })
// CLI:      patch.js --game <dir> --runtime <electronDir> --layer <dir>
//                     [--steamworks <dir>] [--port-version <v>] [--if-needed]
//
// <runtimeDir> is a Linux Electron 31.7.7 tree; the patched app is written to
// <runtimeDir>/resources/app (built in a temp dir and swapped in, so a failed
// patch never breaks a previously working build).

process.noAsar = true; // we read app.asar as a file, also when run by Electron

const fs = require("fs");
const path = require("path");
const asar = require("./asar.js");

const STAMP = ".cx-linux.json";

function copyDir(src, dst) {
  fs.cpSync(src, dst, { recursive: true, dereference: false, preserveTimestamps: true });
}

class PatchError extends Error {}

function patchFile(file, patches) {
  let s = fs.readFileSync(file, "utf8");
  for (const { find, replace, all } of patches) {
    const count = s.split(find).length - 1;
    if (count === 0) throw new PatchError(`patch target not found in ${path.basename(file)}: ${find}\nThis Crosshair X version is not supported by this patch yet.`);
    if (count > 1 && !all) throw new PatchError(`patch target is ambiguous (${count} matches) in ${path.basename(file)}: ${find}`);
    s = all ? s.split(find).join(replace) : s.replace(find, () => replace);
  }
  fs.writeFileSync(file, s);
}

// The 256px entry of the app's ICO is a plain PNG (Linux can't read .ico).
function extractPngFromIco(icoPath, pngPath) {
  const d = fs.readFileSync(icoPath);
  const n = d.readUInt16LE(4);
  let best = null;
  for (let i = 0; i < n; i++) {
    const e = 6 + 16 * i;
    const w = d[e] || 256;
    const size = d.readUInt32LE(e + 8), off = d.readUInt32LE(e + 12);
    if (d.readUInt32BE(off) === 0x89504e47 && (!best || w > best.w)) best = { w, size, off };
  }
  if (!best) return false;
  fs.writeFileSync(pngPath, d.subarray(best.off, best.off + best.size));
  return true;
}

function sourceStamp(gameDir, portVersion) {
  const st = fs.statSync(path.join(gameDir, "resources", "app.asar"));
  return { portVersion: String(portVersion || "dev"), asarSize: st.size, asarMtimeMs: Math.floor(st.mtimeMs) };
}

function isUpToDate({ gameDir, runtimeDir, portVersion }) {
  try {
    const have = JSON.parse(fs.readFileSync(path.join(runtimeDir, "resources", "app", STAMP), "utf8"));
    const want = sourceStamp(gameDir, portVersion);
    return have.portVersion === want.portVersion && have.asarSize === want.asarSize && have.asarMtimeMs === want.asarMtimeMs;
  } catch {
    return false;
  }
}

function patchApp({ gameDir, runtimeDir, layerDir, steamworksDir, portVersion, log = console.log }) {
  const asarPath = path.join(gameDir, "resources", "app.asar");
  if (!fs.existsSync(asarPath)) throw new PatchError(`Crosshair X not found: ${asarPath} does not exist`);
  const resources = path.join(runtimeDir, "resources");
  const finalApp = path.join(resources, "app");
  const APP = path.join(resources, "app.new");
  fs.rmSync(APP, { recursive: true, force: true });

  log("extracting app.asar");
  asar.extractAll(asarPath, APP);
  const pkg = JSON.parse(fs.readFileSync(path.join(APP, "package.json"), "utf8"));
  log(`Crosshair X ${pkg.version}`);

  log("copying app resources");
  for (const dir of ["resources", "translations"]) {
    const src = path.join(gameDir, "resources", dir);
    if (!fs.existsSync(src)) continue;
    fs.rmSync(path.join(resources, dir), { recursive: true, force: true });
    copyDir(src, path.join(resources, dir));
  }
  const ico = path.join(resources, "resources", "logo.ico");
  if (fs.existsSync(ico)) extractPngFromIco(ico, ico.replace(/\.ico$/, ".png"));

  log("removing Windows-only binaries");
  for (const rel of [
    "dllsForJavascriptError",
    "node_modules/@sentry/cli-win32-x64",
    "node_modules/discordjs/lib",
    "node_modules/discordjs/build",
    "node_modules/@centerpoint-gaming/steamworks.js/dist/win64",
  ]) fs.rmSync(path.join(APP, rel), { recursive: true, force: true });
  for (const mod of ["cpgwinrt", "ds5js", "wineventjs", "wininputjs", "xinputjs", "node-hid"]) {
    fs.rmSync(path.join(APP, "node_modules", mod, "build"), { recursive: true, force: true });
  }
  const koffiBuilds = path.join(APP, "node_modules", "koffi", "build", "koffi");
  if (fs.existsSync(koffiBuilds)) {
    for (const d of fs.readdirSync(koffiBuilds)) if (d !== "linux_x64") fs.rmSync(path.join(koffiBuilds, d), { recursive: true, force: true });
  }

  log("installing Linux runtime layer");
  copyDir(layerDir, path.join(APP, "linux"));
  if (steamworksDir && fs.existsSync(path.join(steamworksDir, "steamworksjs.linux-x64-gnu.node"))) {
    copyDir(steamworksDir, path.join(APP, "node_modules", "@centerpoint-gaming", "steamworks.js", "dist", "linux64"));
  } else {
    log("warning: no Linux steamworks.js binary; Steam features will be disabled");
  }
  pkg.main = "./linux/bootstrap.js";
  pkg.desktopName = "crosshairx-linux.desktop";
  fs.writeFileSync(path.join(APP, "package.json"), JSON.stringify(pkg, null, 2));

  log("patching Win32 assumptions");
  patchFile(path.join(APP, "out", "main", "index.js"), [
    {
      // The app refuses to start unless it detects Windows 10/11.
      find: 'if (!NotWindows10["isUserRunningWindows10"]()) NotWindows10["displayIncorrectVersionWindow"]();',
      replace: 'if (false) NotWindows10["displayIncorrectVersionWindow"]();',
    },
    {
      // Profile storage path is concatenated with "\" separators.
      find: 'return _0x3f5546.app["getPath"]("userData") + "\\\\" + PROFILE_DIR + "\\\\";',
      replace: 'return _0x3f5546.app["getPath"]("userData") + "/" + PROFILE_DIR + "/";',
    },
  ]);
  const rendererDir = path.join(APP, "out", "renderer", "assets");
  let rendererPatched = false;
  for (const f of fs.readdirSync(rendererDir)) {
    if (!f.endsWith(".js")) continue;
    const file = path.join(rendererDir, f);
    if (!fs.readFileSync(file, "utf8").includes("extractNameFromPath = (path) => {")) continue;
    patchFile(file, [
      // Process names are shown by splitting on "\"; accept "/" too.
      { find: 'return path.split("\\\\").pop() || "";', replace: 'return path.split(/[\\\\/]/).pop() || "";' },
      // Native Linux executables have no extension.
      { find: '{ name: "Executable Files", extensions: ["exe"] }', replace: '{ name: "Executable Files", extensions: ["exe"] }, { name: "All Files", extensions: ["*"] }', all: true },
    ]);
    rendererPatched = true;
  }
  if (!rendererPatched) throw new PatchError("renderer bundle not recognised; this Crosshair X version is not supported by this patch yet.");

  fs.writeFileSync(path.join(APP, STAMP), JSON.stringify({ ...sourceStamp(gameDir, portVersion), appVersion: pkg.version, builtAt: new Date().toISOString() }, null, 2));

  // Swap in atomically-ish: old build stays usable until the new one is ready.
  const old = path.join(resources, "app.old");
  fs.rmSync(old, { recursive: true, force: true });
  if (fs.existsSync(finalApp)) fs.renameSync(finalApp, old);
  fs.renameSync(APP, finalApp);
  fs.rmSync(old, { recursive: true, force: true });
  fs.rmSync(path.join(resources, "default_app.asar"), { force: true });
  return pkg.version;
}

module.exports = { patchApp, isUpToDate, PatchError };

if (require.main === module) {
  const args = process.argv.slice(2);
  const opt = (name) => { const i = args.indexOf(name); return i >= 0 ? args[i + 1] : undefined; };
  const o = {
    gameDir: opt("--game"),
    runtimeDir: opt("--runtime"),
    layerDir: opt("--layer"),
    steamworksDir: opt("--steamworks"),
    portVersion: opt("--port-version"),
  };
  if (!o.gameDir || !o.runtimeDir || !o.layerDir) {
    console.error("usage: patch.js --game <dir> --runtime <electronDir> --layer <dir> [--steamworks <dir>] [--port-version <v>] [--if-needed]");
    process.exit(2);
  }
  try {
    if (args.includes("--if-needed") && isUpToDate(o)) {
      console.log("up to date");
      process.exit(0);
    }
    const v = patchApp({ ...o, log: (m) => console.log("==> " + m) });
    console.log(`patched Crosshair X ${v}`);
  } catch (e) {
    console.error("error: " + (e instanceof PatchError ? e.message : e.stack || e));
    process.exit(1);
  }
}
