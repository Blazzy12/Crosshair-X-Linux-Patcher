"use strict";
// Worker thread that replaces the Windows raw-input / WinEvent hooks.
//
//  * Keyboard + mouse: read straight from evdev (/dev/input/event*) when every
//    keyboard/mouse node is readable (user in the `input` group). Otherwise fall
//    back to XInput2 raw events on the X root window, which XWayland delivers
//    while an X11 window (i.e. any Proton/Wine game) has focus.
//  * Gamepads: evdev (logind normally grants the seat user access to joysticks).
//  * Foreground window: _NET_ACTIVE_WINDOW / _NET_WM_PID via XCB.
//
// Everything is driven by a single poll() loop over raw fds via koffi, so no
// libuv threadpool threads are pinned by blocking reads.

const { parentPort, workerData } = require("worker_threads");
const fs = require("fs");
const koffi = require(workerData.koffiPath);
const { KEY_NAMES, X_BUTTON_NAMES, MODIFIER_OF, PAD_BUTTONS, PAD_STATE_KEYS } = require("./keymap.js");

const log = (...a) => parentPort.postMessage({ t: "log", msg: a.join(" ") });

// ---------------------------------------------------------------- libc ----
// Resolve libc symbols from the global scope rather than libc.so.6 directly:
// Electron replaces malloc/free (PartitionAlloc), and buffers returned by xcb
// must go back to *that* free, or the allocator deadlocks.
const libc = koffi.load(null);
const c_open = libc.func("int open(const char *path, int flags)");
const c_close = libc.func("int close(int fd)");
const c_read = libc.func("long read(int fd, void *buf, unsigned long count)");
const c_poll = libc.func("int poll(void *fds, unsigned long nfds, int timeout)");
const c_ioctl = libc.func("int ioctl(int fd, unsigned long req, ...)");
const c_free = libc.func("void free(void *ptr)");

const O_RDONLY = 0, O_NONBLOCK = 0o4000, O_CLOEXEC = 0o2000000;
const POLLIN = 1;
const EV_KEY = 1, EV_REL = 2, EV_ABS = 3;
const REL_HWHEEL = 6, REL_WHEEL = 8;
const ABS_Z = 2, ABS_RZ = 5, ABS_HAT0X = 16, ABS_HAT0Y = 17;
const EVENT_SIZE = 24; // struct input_event on 64-bit

// EVIOCGABS(abs) = _IOR('E', 0x40 + abs, struct input_absinfo[24 bytes])
const EVIOCGABS = (abs) => (2 * 2 ** 30) + (24 << 16) + (0x45 << 8) + (0x40 + abs);

// ---------------------------------------------------------- key state ----
const pressed = new Map(); // "src:code" -> key name
function modifierFlags() {
  const f = { ctrlKey: false, shiftKey: false, altKey: false, metaKey: false };
  for (const name of pressed.values()) if (MODIFIER_OF[name]) f[MODIFIER_OF[name]] = true;
  return f;
}
function emitKey(id, name, down) {
  if (down) {
    if (pressed.has(id)) return; // swallow auto-repeat
    pressed.set(id, name);
  } else {
    if (!pressed.has(id)) return;
    pressed.delete(id);
  }
  parentPort.postMessage({ t: "input", type: down ? "keydown" : "keyup", keyName: name, ...modifierFlags() });
}
function emitTap(name) {
  const f = modifierFlags();
  parentPort.postMessage({ t: "input", type: "keydown", keyName: name, ...f });
  parentPort.postMessage({ t: "input", type: "keyup", keyName: name, ...f });
}

// -------------------------------------------------------------- evdev ----
function parseBitmap(str) {
  // "/proc/bus/input/devices" prints 64-bit words, most significant first.
  const words = str.trim().split(/\s+/).reverse();
  const bits = new Set();
  words.forEach((w, i) => {
    let v = BigInt("0x" + w);
    for (let b = 0; v; b++, v >>= 1n) if (v & 1n) bits.add(i * 64 + b);
  });
  return bits;
}

function scanDevices() {
  let text;
  try { text = fs.readFileSync("/proc/bus/input/devices", "utf8"); } catch { return []; }
  const out = [];
  for (const block of text.split(/\n\s*\n/)) {
    const ev = /^H: Handlers=.*\b(event\d+)\b/m.exec(block);
    if (!ev) continue;
    const name = (/^N: Name="(.*)"/m.exec(block) || [])[1] || ev[1];
    const keyBits = parseBitmap((/^B: KEY=(.*)$/m.exec(block) || [, "0"])[1]);
    const relBits = parseBitmap((/^B: REL=(.*)$/m.exec(block) || [, "0"])[1]);
    const handlers = (/^H: Handlers=(.*)$/m.exec(block) || [, ""])[1];
    const isPad = keyBits.has(0x130) || keyBits.has(0x13b); // BTN_SOUTH / BTN_START
    const isMouse = keyBits.has(0x110) && relBits.has(0);   // BTN_LEFT + REL_X
    const isKeyboard = !isPad && /\bkbd\b/.test(handlers) && keyBits.has(30) && keyBits.has(57); // KEY_A, KEY_SPACE
    if (!isPad && !isMouse && !isKeyboard) continue;
    out.push({ node: "/dev/input/" + ev[1], name, isPad, isMouse, isKeyboard });
  }
  return out;
}

const devices = new Map(); // node -> { fd, info, pad? }
let useEvdevKbm = false;

function openDevice(info) {
  const fd = c_open(info.node, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
  if (fd < 0) return null;
  const dev = { fd, info, buf: Buffer.alloc(EVENT_SIZE * 64) };
  if (info.isPad) {
    dev.pad = { buttons: {}, abs: {} };
    for (const axis of [ABS_Z, ABS_RZ]) {
      const ai = Buffer.alloc(24);
      if (c_ioctl(fd, EVIOCGABS(axis), "void *", ai) === 0) {
        const min = ai.readInt32LE(4), max = ai.readInt32LE(8);
        // Only unipolar axes are triggers; centred Z/RZ are a right stick.
        if (min >= 0 && max > min) dev.pad.abs[axis] = { min, max };
      }
    }
  }
  return dev;
}

function closeDevice(node) {
  const dev = devices.get(node);
  if (!dev) return;
  c_close(dev.fd);
  devices.delete(node);
  for (const id of [...pressed.keys()]) if (id.startsWith(node + ":")) emitKey(id, pressed.get(id), false);
  if (dev.pad) publishPad();
}

let lastScanSig = "";
function refreshDevices(force) {
  const found = scanDevices();
  const sig = found.map((d) => d.node).join(",");
  if (!force && sig === lastScanSig) return;
  lastScanSig = sig;

  // Keyboard/mouse via evdev only if we can read *all* of them, otherwise we
  // would silently miss keys typed on an unreadable device.
  const kbm = found.filter((d) => (d.isKeyboard || d.isMouse) && !d.isPad);
  const readable = (d) => { try { fs.accessSync(d.node, fs.constants.R_OK); return true; } catch { return false; } };
  const kbmOk = kbm.length > 0 && kbm.every(readable);
  if (kbmOk !== useEvdevKbm || force) {
    useEvdevKbm = kbmOk;
    parentPort.postMessage({ t: "status", evdevKeyboardMouse: kbmOk });
    log(kbmOk ? "[input] using evdev for keyboard/mouse" : "[input] /dev/input keyboard/mouse not readable; using XInput2 raw events");
    ensureXInput();
  }

  const wanted = new Set(found.filter((d) => d.isPad || (useEvdevKbm && (d.isKeyboard || d.isMouse))).map((d) => d.node));
  for (const node of [...devices.keys()]) if (!wanted.has(node)) closeDevice(node);
  for (const info of found) {
    if (!wanted.has(info.node) || devices.has(info.node)) continue;
    const dev = openDevice(info);
    if (dev) {
      devices.set(info.node, dev);
      log("[input] opened", info.node, JSON.stringify(info.name), info.isPad ? "(gamepad)" : "");
      if (dev.pad) publishPad();
    }
  }
}

function handleDeviceEvents(dev) {
  for (;;) {
    const n = Number(c_read(dev.fd, dev.buf, dev.buf.length));
    if (n <= 0) {
      if (n < 0 && koffi.errno() === 11) return; // EAGAIN
      closeDevice(dev.info.node);                 // ENODEV: unplugged
      return;
    }
    for (let off = 0; off + EVENT_SIZE <= n; off += EVENT_SIZE) {
      const type = dev.buf.readUInt16LE(off + 16);
      const code = dev.buf.readUInt16LE(off + 18);
      const value = dev.buf.readInt32LE(off + 20);
      if (dev.pad) handlePadEvent(dev, type, code, value);
      else handleKbmEvent(dev, type, code, value);
    }
  }
}

function handleKbmEvent(dev, type, code, value) {
  if (type === EV_KEY) {
    const name = KEY_NAMES[code];
    if (!name || value === 2) return;
    emitKey(dev.info.node + ":" + code, name, value === 1);
  } else if (type === EV_REL && value !== 0) {
    if (code === REL_WHEEL) emitTap(value > 0 ? "WheelUp" : "WheelDown");
    else if (code === REL_HWHEEL) emitTap(value > 0 ? "WheelRight" : "WheelLeft");
  }
}

// ----------------------------------------------------------- gamepads ----
function handlePadEvent(dev, type, code, value) {
  const p = dev.pad;
  if (type === EV_KEY && PAD_BUTTONS[code]) {
    p.buttons[PAD_BUTTONS[code]] = value !== 0;
  } else if (type === EV_ABS) {
    if (code === ABS_HAT0X) { p.buttons.dpadLeft = value < 0; p.buttons.dpadRight = value > 0; }
    else if (code === ABS_HAT0Y) { p.buttons.dpadUp = value < 0; p.buttons.dpadDown = value > 0; }
    else if (p.abs[code]) {
      const { min, max } = p.abs[code];
      p.buttons[code === ABS_Z ? "leftTriggerAxis" : "rightTriggerAxis"] = (value - min) / (max - min) > 0.25;
    } else return;
  } else return;
  publishPad();
}

let lastPadJson = "";
function publishPad() {
  const pads = [...devices.values()].filter((d) => d.pad);
  const state = {};
  for (const k of PAD_STATE_KEYS) state[k] = 0;
  for (const d of pads) {
    const b = d.pad.buttons;
    for (const k of PAD_STATE_KEYS) if (b[k]) state[k] = 1;
    if (b.leftTriggerAxis) state.leftTrigger = 1;
    if (b.rightTriggerAxis) state.rightTrigger = 1;
  }
  const msg = { t: "pad", connected: pads.length > 0, state };
  const json = JSON.stringify(msg);
  if (json === lastPadJson) return;
  lastPadJson = json;
  parentPort.postMessage(msg);
}

// ---------------------------------------------------------------- XCB ----
let X = null;
function initX() {
  if (!process.env.DISPLAY) return null;
  try {
    const xcb = koffi.load("libxcb.so.1");
    const Cookie = koffi.struct("xcb_cookie_t", { sequence: "uint32_t" });
    const ScreenIter = koffi.struct("xcb_screen_iterator_t", { data: "void *", rem: "int", index: "int" });
    const f = {
      connect: xcb.func("void *xcb_connect(const char *name, void *screenp)"),
      has_error: xcb.func("int xcb_connection_has_error(void *c)"),
      get_setup: xcb.func("void *xcb_get_setup(void *c)"),
      roots: xcb.func("xcb_screen_iterator_t xcb_setup_roots_iterator(void *setup)"),
      intern_atom: xcb.func("xcb_cookie_t xcb_intern_atom(void *c, uint8_t only_if_exists, uint16_t len, const char *name)"),
      intern_atom_reply: xcb.func("void *xcb_intern_atom_reply(void *c, xcb_cookie_t ck, void *e)"),
      get_property: xcb.func("xcb_cookie_t xcb_get_property(void *c, uint8_t del, uint32_t win, uint32_t prop, uint32_t type, uint32_t off, uint32_t len)"),
      get_property_reply: xcb.func("void *xcb_get_property_reply(void *c, xcb_cookie_t ck, void *e)"),
      change_attrs: xcb.func("xcb_cookie_t xcb_change_window_attributes(void *c, uint32_t win, uint32_t mask, const void *values)"),
      query_extension: xcb.func("xcb_cookie_t xcb_query_extension(void *c, uint16_t len, const char *name)"),
      query_extension_reply: xcb.func("void *xcb_query_extension_reply(void *c, xcb_cookie_t ck, void *e)"),
      flush: xcb.func("int xcb_flush(void *c)"),
      fd: xcb.func("int xcb_get_file_descriptor(void *c)"),
      poll_for_event: xcb.func("void *xcb_poll_for_event(void *c)"),
    };
    const conn = f.connect(null, null);
    if (!conn || f.has_error(conn)) { log("[x11] cannot connect to", process.env.DISPLAY); return null; }
    const root = koffi.decode(f.roots(f.get_setup(conn)).data, "uint32_t");
    const atom = (name) => {
      const r = f.intern_atom_reply(conn, f.intern_atom(conn, 0, name.length, name), null);
      if (!r) return 0;
      const a = koffi.decode(r, 8, "uint32_t");
      c_free(r);
      return a;
    };
    const x = { xcb, f, conn, root, fd: f.fd(conn), xiOpcode: -1, xiSelected: false };
    x.NET_ACTIVE_WINDOW = atom("_NET_ACTIVE_WINDOW");
    x.NET_WM_PID = atom("_NET_WM_PID");
    // PropertyChangeMask on the root so we hear about focus changes.
    const vals = Buffer.alloc(4); vals.writeUInt32LE(1 << 22);
    f.change_attrs(conn, root, 1 << 11 /* XCB_CW_EVENT_MASK */, vals);
    f.flush(conn);
    return x;
  } catch (e) {
    log("[x11] init failed:", e && e.message);
    return null;
  }
}

function getCardinal(win, prop) {
  const { f, conn } = X;
  const r = f.get_property_reply(conn, f.get_property(conn, 0, win, prop, 0, 0, 1), null);
  if (!r) return 0;
  const format = koffi.decode(r, 1, "uint8_t");
  const len = koffi.decode(r, 16, "uint32_t");
  const v = format === 32 && len > 0 ? koffi.decode(r, 32, "uint32_t") : 0;
  c_free(r);
  return v;
}

let lastFocus = null;
function checkFocus() {
  if (!X) return;
  const wid = getCardinal(X.root, X.NET_ACTIVE_WINDOW);
  const pid = wid ? getCardinal(wid, X.NET_WM_PID) : 0;
  const key = wid + ":" + pid;
  if (key === lastFocus) return;
  lastFocus = key;
  parentPort.postMessage({ t: "focus", wid, pid });
}

function ensureXInput() {
  if (!X || useEvdevKbm || X.xiSelected) return;
  try {
    const xi = koffi.load("libxcb-xinput.so.0");
    const qv = xi.func("xcb_cookie_t xcb_input_xi_query_version(void *c, uint16_t major, uint16_t minor)");
    const qvr = xi.func("void *xcb_input_xi_query_version_reply(void *c, xcb_cookie_t ck, void *e)");
    const sel = xi.func("xcb_cookie_t xcb_input_xi_select_events(void *c, uint32_t win, uint16_t n, const void *masks)");
    const { f, conn } = X;
    const ext = f.query_extension_reply(conn, f.query_extension(conn, 15, "XInputExtension"), null);
    if (!ext) return;
    const present = koffi.decode(ext, 8, "uint8_t");
    X.xiOpcode = koffi.decode(ext, 9, "uint8_t");
    c_free(ext);
    if (!present) { log("[x11] XInputExtension missing"); return; }
    const v = qvr(conn, qv(conn, 2, 2), null);
    if (v) c_free(v);
    // xcb_input_event_mask_t { deviceid=XIAllMasterDevices, mask_len=1 } + mask
    const m = Buffer.alloc(8);
    m.writeUInt16LE(1, 0); m.writeUInt16LE(1, 2);
    m.writeUInt32LE((1 << 13) | (1 << 14) | (1 << 15) | (1 << 16), 4); // Raw{Key,Button}{Press,Release}
    sel(conn, X.root, 1, m);
    f.flush(conn);
    X.xiSelected = true;
    log("[x11] XInput2 raw input selected");
  } catch (e) {
    log("[x11] XInput2 unavailable:", e && e.message);
  }
}

function handleXEvents() {
  const { f, conn } = X;
  for (;;) {
    const ev = f.poll_for_event(conn);
    if (!ev) break;
    const type = koffi.decode(ev, 0, "uint8_t") & 0x7f;
    if (type === 28 /* PropertyNotify */) {
      if (koffi.decode(ev, 8, "uint32_t") === X.NET_ACTIVE_WINDOW) checkFocus();
    } else if (type === 35 /* GenericEvent */ && koffi.decode(ev, 1, "uint8_t") === X.xiOpcode && !useEvdevKbm) {
      const evtype = koffi.decode(ev, 8, "uint16_t");
      const detail = koffi.decode(ev, 16, "uint32_t");
      if (evtype === 13 || evtype === 14) {
        const name = KEY_NAMES[detail - 8];
        if (name) emitKey("x:k" + detail, name, evtype === 13);
      } else if (evtype === 15 || evtype === 16) {
        const name = X_BUTTON_NAMES[detail];
        if (!name) { /* unknown button */ }
        else if (detail >= 4 && detail <= 7) { if (evtype === 15) emitTap(name); }
        else emitKey("x:b" + detail, name, evtype === 15);
      }
    }
    c_free(ev);
  }
  if (f.has_error(conn)) { log("[x11] connection lost"); X = null; }
}

// --------------------------------------------------------------- loop ----
let running = true;
let lastRescan = 0;
let lastFocusPoll = 0;
parentPort.on("message", (m) => { if (m && m.cmd === "stop") running = false; });

X = initX();
refreshDevices(true);
checkFocus();

function tick() {
  if (!running) {
    for (const node of [...devices.keys()]) closeDevice(node);
    return;
  }
  const list = [...devices.values()];
  const n = list.length + (X ? 1 : 0);
  const pfd = Buffer.alloc(Math.max(n, 1) * 8);
  list.forEach((d, i) => { pfd.writeInt32LE(d.fd, i * 8); pfd.writeInt16LE(POLLIN, i * 8 + 4); });
  if (X) { pfd.writeInt32LE(X.fd, list.length * 8); pfd.writeInt16LE(POLLIN, list.length * 8 + 4); }

  const r = n ? c_poll(pfd, n, 100) : (Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 100), 0);
  if (r > 0) {
    list.forEach((d, i) => {
      const rev = pfd.readInt16LE(i * 8 + 6);
      if (rev && devices.get(d.info.node) === d) handleDeviceEvents(d);
    });
  }
  // xcb may already have buffered events even if the fd isn't readable.
  if (X) handleXEvents();

  const now = Date.now();
  if (now - lastRescan > 2000) { lastRescan = now; refreshDevices(false); }
  if (now - lastFocusPoll > 1000) { lastFocusPoll = now; checkFocus(); }
  setImmediate(tick);
}
tick();
