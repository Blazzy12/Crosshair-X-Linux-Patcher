"use strict";
// Process enumeration for Linux, shaped like the Windows `wineventjs` results.
//
// Games under Wine/Proton show up as wine(64)-preloader processes whose argv[0]
// is the Windows path of the .exe, so we report that .exe name (which is what the
// game database is keyed on) and translate its path back to the real file on
// disk. Native processes report their /proc/<pid>/exe target.

const fs = require("fs");
const path = require("path");
const os = require("os");

const WINE_LOADER = /^(wine|wine64|wine-preloader|wine64-preloader)$/;

// Native Linux builds of games, mapped to the Windows exe name the game
// database knows. Deliberately a short explicit list: blanket "name.exe"
// aliasing collides with desktop apps (e.g. KDE's `dolphin`).
const NATIVE_ALIASES = {
  cs2: "cs2.exe",
  dota2: "dota2.exe",
  hl2_linux: "hl2.exe",
  tf_linux64: "tf_win64.exe",
  csgo_linux64: "csgo.exe",
};

function readCmdline(pid) {
  try {
    return fs.readFileSync(`/proc/${pid}/cmdline`, "latin1").split("\0").filter(Boolean);
  } catch {
    return [];
  }
}

function readExe(pid) {
  try {
    return fs.readlinkSync(`/proc/${pid}/exe`).replace(/ \(deleted\)$/, "");
  } catch {
    return null;
  }
}

function readComm(pid) {
  try {
    return fs.readFileSync(`/proc/${pid}/comm`, "utf8").trim();
  } catch {
    return null;
  }
}

function winePrefixOf(pid) {
  try {
    const env = fs.readFileSync(`/proc/${pid}/environ`, "latin1").split("\0");
    const kv = env.find((e) => e.startsWith("WINEPREFIX="));
    if (kv) return kv.slice("WINEPREFIX=".length);
  } catch {}
  return path.join(os.homedir(), ".wine");
}

// "Z:\home\me\game.exe" -> "/home/me/game.exe"; "C:\x\y.exe" -> "<prefix>/drive_c/x/y.exe"
function windowsToUnixPath(winPath, pid) {
  const m = /^([A-Za-z]):[\\/](.*)$/.exec(winPath);
  if (!m) return null;
  const rest = m[2].replace(/\\/g, "/");
  const drive = m[1].toLowerCase();
  if (drive === "z") return "/" + rest;
  const prefix = winePrefixOf(pid);
  const viaLink = path.join(prefix, "dosdevices", drive + ":");
  try {
    return path.join(fs.realpathSync(viaLink), rest);
  } catch {
    return path.join(prefix, "drive_" + drive, rest);
  }
}

// Returns { name, path, wine } or null for kernel threads / vanished processes.
function describe(pid) {
  const exe = readExe(pid);
  const argv = readCmdline(pid);
  if (!exe && argv.length === 0) return null;
  const exeBase = exe ? path.basename(exe) : "";
  const argv0 = argv[0] || "";

  const looksWindows = /\.exe$/i.test(argv0) && (/^[A-Za-z]:[\\/]/.test(argv0) || argv0.includes("\\"));
  if (looksWindows || (WINE_LOADER.test(exeBase) && /\.exe$/i.test(argv0))) {
    const name = argv0.split(/[\\/]/).pop();
    const unix = windowsToUnixPath(argv0, pid);
    return { name, path: unix || argv0, wine: true };
  }
  if (!exe) return null;
  const base = exeBase || readComm(pid) || String(pid);
  return { name: NATIVE_ALIASES[base] || base, path: exe, wine: false };
}

function listPids() {
  let entries;
  try {
    entries = fs.readdirSync("/proc");
  } catch {
    return [];
  }
  return entries.filter((e) => /^\d+$/.test(e)).map(Number);
}

function getProcessList() {
  const out = [];
  for (const pid of listPids()) {
    const d = describe(pid);
    if (d) out.push({ pid, name: d.name });
  }
  return out;
}

function getProcessPath(pid) {
  const d = describe(Number(pid));
  return d ? d.path : null;
}

function isProcessRunning(name) {
  const want = String(name).toLowerCase();
  for (const pid of listPids()) {
    const d = describe(pid);
    if (d && d.name.toLowerCase() === want) return true;
  }
  return false;
}

module.exports = { describe, getProcessList, getProcessPath, isProcessRunning, windowsToUnixPath };
