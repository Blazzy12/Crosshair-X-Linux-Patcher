#!/usr/bin/env node
"use strict";
// Developer build: a runnable Linux bundle of Crosshair X from an existing
// Windows install. (End users get the same result from install.sh, which
// patches their Steam copy.)
//
//   node build.js [path/to/CrosshairX-windows-install] [output dir]
//
// The Windows install directory is the one containing CrosshairX.exe and
// resources/app.asar. Defaults to the parent of this folder.

const fs = require("fs");
const path = require("path");
const os = require("os");
const { execFileSync } = require("child_process");
const { patchApp, PatchError } = require("./patcher/patch.js");

const HERE = __dirname;
const SRC_INSTALL = path.resolve(process.argv[2] || path.join(HERE, ".."));
const OUT = path.resolve(process.argv[3] || path.join(HERE, "dist", "CrosshairX"));
const ELECTRON_DIST = path.join(HERE, "node_modules", "electron", "dist");
const EXPECTED_ELECTRON = "31.7.7";

function step(msg) { console.log("==> " + msg); }
function die(msg) { console.error("error: " + msg); process.exit(1); }

function copyDir(src, dst) {
  fs.cpSync(src, dst, { recursive: true, dereference: false, preserveTimestamps: true });
}

// npm >= 11 skips dependency install scripts unless approved, so Electron's
// binary may never have been downloaded/extracted. Do it here if needed.
function ensureElectron() {
  if (fs.existsSync(path.join(ELECTRON_DIST, "electron"))) return;
  step("fetching Electron " + EXPECTED_ELECTRON);
  try {
    execFileSync(process.execPath, [path.join(HERE, "node_modules", "electron", "install.js")], { stdio: "inherit" });
  } catch {}
  if (fs.existsSync(path.join(ELECTRON_DIST, "electron"))) return;
  // install.js downloads into the cache but its unzip step can fail on very
  // new Node versions; extract the cached archive ourselves.
  const zipName = `electron-v${EXPECTED_ELECTRON}-linux-x64.zip`;
  const cache = path.join(process.env.electron_config_cache || path.join(os.homedir(), ".cache", "electron"));
  let zip = null;
  if (fs.existsSync(cache)) {
    for (const d of fs.readdirSync(cache)) {
      const cand = path.join(cache, d, zipName);
      if (fs.existsSync(cand)) zip = cand;
      if (d === zipName) zip = path.join(cache, d);
    }
  }
  if (!zip) die(`Electron ${EXPECTED_ELECTRON} could not be downloaded (no ${zipName} in ${cache})`);
  fs.rmSync(ELECTRON_DIST, { recursive: true, force: true });
  fs.mkdirSync(ELECTRON_DIST, { recursive: true });
  execFileSync("unzip", ["-q", zip, "-d", ELECTRON_DIST], { stdio: "inherit" });
  fs.writeFileSync(path.join(HERE, "node_modules", "electron", "path.txt"), "electron");
}

// ---------------------------------------------------------------------------
const asarPath = path.join(SRC_INSTALL, "resources", "app.asar");
if (!fs.existsSync(asarPath)) die(`no resources/app.asar under ${SRC_INSTALL}`);
ensureElectron();
const ev = fs.readFileSync(path.join(ELECTRON_DIST, "version"), "utf8").trim().replace(/^v/, "");
if (ev !== EXPECTED_ELECTRON) console.warn(`warning: bundled Electron is ${ev}, the app was built for ${EXPECTED_ELECTRON}`);

step(`output: ${OUT}`);
fs.rmSync(OUT, { recursive: true, force: true });
fs.mkdirSync(OUT, { recursive: true });

step("copying Linux Electron runtime");
copyDir(ELECTRON_DIST, OUT);
fs.renameSync(path.join(OUT, "electron"), path.join(OUT, "crosshairx"));
fs.rmSync(path.join(OUT, "resources", "default_app.asar"), { force: true });

try {
  patchApp({
    gameDir: SRC_INSTALL,
    runtimeDir: OUT,
    layerDir: path.join(HERE, "src"),
    steamworksDir: path.join(HERE, "node_modules", "steamworks.js", "dist", "linux64"),
    portVersion: "dev",
    log: step,
  });
} catch (e) {
  die(e instanceof PatchError ? e.message : e.stack || String(e));
}

step("writing launcher");
fs.copyFileSync(path.join(HERE, "launcher", "crosshairx.sh"), path.join(OUT, "crosshairx.sh"));
fs.chmodSync(path.join(OUT, "crosshairx.sh"), 0o755);
fs.copyFileSync(path.join(HERE, "launcher", "install.sh"), path.join(OUT, "install.sh"));
fs.chmodSync(path.join(OUT, "install.sh"), 0o755);

console.log(`\nDone. Run:  ${path.join(OUT, "crosshairx.sh")}\nInstall menu entry:  ${path.join(OUT, "install.sh")}`);
