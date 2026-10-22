"use strict";
// Linux replacement for `winreg`. A tiny read-only "registry" that answers the
// handful of keys the app actually relies on from Linux equivalents, and
// reports everything else as missing (the app handles missing keys).

const fs = require("fs");
const path = require("path");
const os = require("os");

function findSteamRoot() {
  const home = os.homedir();
  const candidates = [
    path.join(home, ".steam", "steam"),
    path.join(home, ".local", "share", "Steam"),
    path.join(home, ".steam", "root"),
    path.join(home, ".var", "app", "com.valvesoftware.Steam", ".local", "share", "Steam"),
    path.join(home, "snap", "steam", "common", ".local", "share", "Steam"),
  ];
  for (const c of candidates) {
    try {
      const real = fs.realpathSync(c);
      if (fs.existsSync(path.join(real, "steamapps"))) return real;
    } catch {}
  }
  return null;
}

function machineGuid() {
  for (const f of ["/etc/machine-id", "/var/lib/dbus/machine-id"]) {
    try {
      const id = fs.readFileSync(f, "utf8").trim();
      if (/^[0-9a-f]{32}$/i.test(id)) {
        return [id.slice(0, 8), id.slice(8, 12), id.slice(12, 16), id.slice(16, 20), id.slice(20)].join("-");
      }
    } catch {}
  }
  return null;
}

const norm = (hive, key) => (hive + key).toLowerCase().replace(/\\+$/, "");

// "HIVE\\key" (lower-case) -> () => { valueName: value }
const VIRTUAL = {
  [norm("HKCU", "\\Software\\Valve\\Steam")]: () => {
    const p = findSteamRoot();
    return p ? { SteamPath: p } : {};
  },
  [norm("HKLM", "\\Software\\Microsoft\\Cryptography")]: () => {
    const g = machineGuid();
    return g ? { MachineGuid: g } : {};
  },
  [norm("HKLM", "\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion")]: () => ({
    ProductName: "Linux " + os.release(),
    DisplayVersion: os.release(),
    CurrentBuildNumber: "0",
  }),
};

class Registry {
  constructor(opts = {}) {
    this.hive = opts.hive || Registry.HKLM;
    this.key = opts.key || "";
    this.host = "";
    this.arch = opts.arch;
    this.path = this.hive + this.key;
  }
  _values() {
    const fn = VIRTUAL[norm(this.hive, this.key)];
    return fn ? fn() : null;
  }
  _item(name, value) {
    return { host: "", hive: this.hive, key: this.key, name, type: Registry.REG_SZ, value: String(value), arch: this.arch };
  }
  get(name, cb) {
    const vals = this._values();
    process.nextTick(() => {
      if (!vals || !(name in vals)) cb(new Error("The system was unable to find the specified registry key or value."));
      else cb(null, this._item(name, vals[name]));
    });
    return this;
  }
  values(cb) {
    const vals = this._values();
    process.nextTick(() => {
      if (!vals) cb(new Error("The system was unable to find the specified registry key or value."));
      else cb(null, Object.entries(vals).map(([k, v]) => this._item(k, v)));
    });
    return this;
  }
  keys(cb) {
    process.nextTick(() => cb(null, []));
    return this;
  }
  keyExists(cb) {
    const vals = this._values();
    process.nextTick(() => cb(null, !!vals));
    return this;
  }
  valueExists(name, cb) {
    const vals = this._values();
    process.nextTick(() => cb(null, !!vals && name in vals));
    return this;
  }
  set(_name, _type, _value, cb) {
    process.nextTick(() => cb && cb(null));
    return this;
  }
  remove(_name, cb) {
    process.nextTick(() => cb && cb(null));
    return this;
  }
  create(cb) { process.nextTick(() => cb && cb(null)); return this; }
  destroy(cb) { process.nextTick(() => cb && cb(null)); return this; }
  clear(cb) { process.nextTick(() => cb && cb(null)); return this; }
}

Object.assign(Registry, {
  HKLM: "HKLM", HKCU: "HKCU", HKCR: "HKCR", HKU: "HKU", HKCC: "HKCC",
  HIVES: ["HKLM", "HKCU", "HKCR", "HKU", "HKCC"],
  REG_SZ: "REG_SZ", REG_MULTI_SZ: "REG_MULTI_SZ", REG_EXPAND_SZ: "REG_EXPAND_SZ",
  REG_DWORD: "REG_DWORD", REG_QWORD: "REG_QWORD", REG_BINARY: "REG_BINARY", REG_NONE: "REG_NONE",
  REG_TYPES: ["REG_SZ", "REG_MULTI_SZ", "REG_EXPAND_SZ", "REG_DWORD", "REG_QWORD", "REG_BINARY", "REG_NONE"],
  DEFAULT_VALUE: "",
});

module.exports = Registry;
