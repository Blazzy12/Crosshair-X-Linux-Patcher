"use strict";
// Small XCB helpers (via koffi) used on the main thread.
//
// KWin stacks an *active fullscreen* window above every "keep above" window, so
// a plain always-on-top Electron window disappears behind fullscreen games.
// Windows typed as on-screen-display (KDE) / notification live in higher
// layers, so we retype the crosshair overlay before it is first mapped.

const koffi = require("koffi");

let X;
function x() {
  if (X !== undefined) return X;
  X = null;
  if (!process.env.DISPLAY) return X;
  try {
    const xcb = koffi.load("libxcb.so.1");
    // Global scope, so `free` is Electron's allocator (see input-worker.js).
    const libc = koffi.load(null);
    const Cookie = koffi.struct("cx_xcb_cookie_t", { sequence: "uint32_t" });
    const f = {
      connect: xcb.func("void *xcb_connect(const char *name, void *screenp)"),
      has_error: xcb.func("int xcb_connection_has_error(void *c)"),
      intern_atom: xcb.func("cx_xcb_cookie_t xcb_intern_atom(void *c, uint8_t only_if_exists, uint16_t len, const char *name)"),
      intern_atom_reply: xcb.func("void *xcb_intern_atom_reply(void *c, cx_xcb_cookie_t ck, void *e)"),
      change_property: xcb.func("cx_xcb_cookie_t xcb_change_property(void *c, uint8_t mode, uint32_t win, uint32_t prop, uint32_t type, uint8_t format, uint32_t len, const void *data)"),
      flush: xcb.func("int xcb_flush(void *c)"),
      free: libc.func("void free(void *p)"),
    };
    void Cookie;
    const conn = f.connect(null, null);
    if (!conn || f.has_error(conn)) return X;
    const atoms = {};
    const atom = (name) => {
      if (atoms[name]) return atoms[name];
      const r = f.intern_atom_reply(conn, f.intern_atom(conn, 0, name.length, name), null);
      if (!r) return 0;
      const a = koffi.decode(r, 8, "uint32_t");
      f.free(r);
      return (atoms[name] = a);
    };
    X = { f, conn, atom };
  } catch (e) {
    console.warn("[linux-x11] XCB unavailable:", e && e.message);
  }
  return X;
}

function xidOf(win) {
  const h = win.getNativeWindowHandle();
  return h.length >= 8 ? Number(h.readBigUInt64LE(0)) : h.readUInt32LE(0);
}

function setAtomList(xid, prop, names) {
  const c = x();
  const buf = Buffer.alloc(4 * names.length);
  names.forEach((n, i) => buf.writeUInt32LE(c.atom(n), i * 4));
  c.f.change_property(c.conn, 0 /* Replace */, xid, c.atom(prop), 4 /* ATOM */, 32, names.length, buf);
}

// Make `win` an overlay that sits above fullscreen windows and never shows up
// in the taskbar, pager or alt-tab.
function makeOverlay(win) {
  const c = x();
  if (!c) return false;
  try {
    const xid = xidOf(win);
    setAtomList(xid, "_NET_WM_WINDOW_TYPE", [
      "_KDE_NET_WM_WINDOW_TYPE_ON_SCREEN_DISPLAY",
      "_NET_WM_WINDOW_TYPE_NOTIFICATION",
      "_NET_WM_WINDOW_TYPE_UTILITY",
    ]);
    setAtomList(xid, "_NET_WM_STATE", ["_NET_WM_STATE_ABOVE", "_NET_WM_STATE_SKIP_TASKBAR", "_NET_WM_STATE_SKIP_PAGER"]);
    c.f.flush(c.conn);
    return true;
  } catch (e) {
    console.warn("[linux-x11] could not retype overlay window:", e && e.message);
    return false;
  }
}

module.exports = { makeOverlay };
