"use strict";
// Steam text-VDF helpers for the installer.
//
//   steamcfg.js find-game   <steamRoot> <appid>          -> prints install dir
//   steamcfg.js get-compat  <steamRoot> <appid>          -> prints tool name
//   steamcfg.js set-compat  <steamRoot> <appid> <tool>   (Steam must be closed)
//   steamcfg.js unset-compat <steamRoot> <appid> <tool>  (Steam must be closed)
//
// The parser keeps key order and original key spelling so that rewriting
// config.vdf only changes the entry we touch.

const fs = require("fs");
const path = require("path");

// Object nodes are arrays of [key, value] pairs; values are strings or nodes.
function parse(text) {
  let i = 0;
  const n = text.length;
  const skip = () => {
    for (;;) {
      while (i < n && /\s/.test(text[i])) i++;
      if (text[i] === "/" && text[i + 1] === "/") { while (i < n && text[i] !== "\n") i++; continue; }
      break;
    }
  };
  const str = () => {
    if (text[i] === '"') {
      i++;
      let s = "";
      while (i < n && text[i] !== '"') {
        if (text[i] === "\\" && i + 1 < n) {
          const c = text[i + 1];
          s += c === "n" ? "\n" : c === "t" ? "\t" : c;
          i += 2;
        } else s += text[i++];
      }
      i++;
      return s;
    }
    let s = "";
    while (i < n && !/[\s{}"]/.test(text[i])) s += text[i++];
    return s;
  };
  const obj = (top) => {
    const out = [];
    for (;;) {
      skip();
      if (i >= n) { if (top) return out; throw new Error("unexpected end of VDF"); }
      if (text[i] === "}") { if (top) throw new Error("unbalanced } in VDF"); i++; return out; }
      const key = str();
      skip();
      // Conditional suffixes like [$WIN32] are rare in these files; skip them.
      if (text[i] === "[") { while (i < n && text[i] !== "]") i++; i++; skip(); }
      if (text[i] === "{") { i++; out.push([key, obj(false)]); }
      else out.push([key, str()]);
    }
  };
  return obj(true);
}

const esc = (s) => String(s).replace(/\\/g, "\\\\").replace(/"/g, '\\"');
function stringify(node, depth = 0) {
  const tabs = "\t".repeat(depth);
  let out = "";
  for (const [k, v] of node) {
    if (Array.isArray(v)) out += `${tabs}"${esc(k)}"\n${tabs}{\n${stringify(v, depth + 1)}${tabs}}\n`;
    else out += `${tabs}"${esc(k)}"\t\t"${esc(v)}"\n`;
  }
  return out;
}

const getKey = (node, key) => node.find(([k]) => k.toLowerCase() === key.toLowerCase());
function child(node, key, create) {
  let e = getKey(node, key);
  if (!e && create) { e = [key, []]; node.push(e); }
  return e && Array.isArray(e[1]) ? e[1] : null;
}
function walk(node, keys, create) {
  for (const k of keys) { node = child(node, k, create); if (!node) return null; }
  return node;
}

function writeAtomic(file, text) {
  const tmp = file + ".cx-tmp";
  fs.writeFileSync(tmp, text);
  fs.renameSync(tmp, file);
}

function libraries(steamRoot) {
  const libs = new Set([path.resolve(steamRoot)]);
  for (const f of [path.join(steamRoot, "steamapps", "libraryfolders.vdf"), path.join(steamRoot, "config", "libraryfolders.vdf")]) {
    try {
      const root = parse(fs.readFileSync(f, "utf8"));
      const lf = child(root, "libraryfolders", false) || [];
      for (const [, v] of lf) {
        if (Array.isArray(v)) { const p = getKey(v, "path"); if (p) libs.add(p[1]); }
        else if (typeof v === "string" && v.startsWith("/")) libs.add(v); // old format
      }
    } catch {}
  }
  return [...libs];
}

function findGame(steamRoot, appid) {
  for (const lib of libraries(steamRoot)) {
    const acf = path.join(lib, "steamapps", `appmanifest_${appid}.acf`);
    if (!fs.existsSync(acf)) continue;
    try {
      const st = child(parse(fs.readFileSync(acf, "utf8")), "AppState", false);
      const dir = st && getKey(st, "installdir");
      if (!dir) continue;
      const full = path.join(lib, "steamapps", "common", dir[1]);
      if (fs.existsSync(path.join(full, "resources", "app.asar"))) return full;
    } catch {}
  }
  return null;
}

const COMPAT_PATH = ["InstallConfigStore", "Software", "Valve", "Steam", "CompatToolMapping"];

function getCompat(steamRoot, appid) {
  const file = path.join(steamRoot, "config", "config.vdf");
  try {
    const m = walk(parse(fs.readFileSync(file, "utf8")), COMPAT_PATH, false);
    const e = m && child(m, String(appid), false);
    const name = e && getKey(e, "name");
    return name ? name[1] : "";
  } catch {
    return "";
  }
}

function setCompat(steamRoot, appid, tool) {
  const file = path.join(steamRoot, "config", "config.vdf");
  const text = fs.readFileSync(file, "utf8");
  const root = parse(text);
  if (!getKey(root, "InstallConfigStore")) throw new Error("config.vdf has unexpected layout");
  const mapping = walk(root, COMPAT_PATH, true);
  const idx = mapping.findIndex(([k]) => k === String(appid));
  const entry = [String(appid), [["name", tool], ["config", ""], ["priority", "250"]]];
  if (idx >= 0) mapping[idx] = entry; else mapping.push(entry);
  const backup = file + ".crosshairx-backup";
  if (!fs.existsSync(backup)) fs.writeFileSync(backup, text);
  writeAtomic(file, stringify(root));
}

function unsetCompat(steamRoot, appid, tool) {
  const file = path.join(steamRoot, "config", "config.vdf");
  const root = parse(fs.readFileSync(file, "utf8"));
  const mapping = walk(root, COMPAT_PATH, false);
  if (!mapping) return false;
  const idx = mapping.findIndex(([k, v]) => k === String(appid) && Array.isArray(v) && (getKey(v, "name") || [])[1] === tool);
  if (idx < 0) return false;
  mapping.splice(idx, 1);
  writeAtomic(file, stringify(root));
  return true;
}

module.exports = { parse, stringify, libraries, findGame, getCompat, setCompat, unsetCompat };

if (require.main === module) {
  const [cmd, root, appid, tool] = process.argv.slice(2);
  try {
    switch (cmd) {
      case "find-game": { const g = findGame(root, appid); if (!g) process.exit(1); console.log(g); break; }
      case "get-compat": console.log(getCompat(root, appid)); break;
      case "set-compat": setCompat(root, appid, tool); break;
      case "unset-compat": unsetCompat(root, appid, tool); break;
      default: console.error("unknown command"); process.exit(2);
    }
  } catch (e) {
    console.error("error: " + e.message);
    process.exit(1);
  }
}
