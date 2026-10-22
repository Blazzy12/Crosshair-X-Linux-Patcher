"use strict";
// Linux replacement for `wineventjs` (process list/paths, foreground window
// hook, exe icons). Foreground changes come from _NET_ACTIVE_WINDOW (X11 /
// XWayland); a Wayland-native or empty focus is reported as the Windows shell
// ("explorer.exe"), which the app already treats as "no application".

const input = require("../platform/input.js");
const procfs = require("../platform/procfs.js");

const DESKTOP_PATH = "C:\\Windows\\explorer.exe";

function resolveFocus(focus) {
  if (!focus || !focus.wid || !focus.pid) return { path: DESKTOP_PATH, pid: 0 };
  if (focus.pid === process.pid) return { path: process.execPath, pid: focus.pid };
  const d = procfs.describe(focus.pid);
  return d ? { path: d.path, pid: focus.pid } : { path: DESKTOP_PATH, pid: 0 };
}

module.exports = {
  getProcessList: () => procfs.getProcessList(),
  getProcessPath: (pid) => procfs.getProcessPath(pid),
  isProcessRunning: (name) => procfs.isProcessRunning(name),
  isProcessRunningElevated: () => false,
  isNamedWindowVisible: () => false,
  getCurrentSessionId: () => 1,
  // Returns a data URL on Windows; the UI falls back to a generic icon on null.
  getIconForExe: () => null,
  onSystemForeground(cb) {
    let last = null;
    const fire = (focus) => {
      const { path, pid } = resolveFocus(focus);
      const key = path + "|" + pid;
      if (key === last) return;
      last = key;
      try {
        cb("foreground", path, pid);
      } catch (e) {
        console.error("[wineventjs] foreground callback failed:", e);
      }
    };
    input.start().on("focus", fire);
    if (input.focus) fire(input.focus);
  },
};
