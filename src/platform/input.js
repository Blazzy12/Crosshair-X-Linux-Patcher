"use strict";
// Main-thread side of the input/focus worker. Lazily started the first time a
// shim needs it; exposes plain events plus the latest gamepad snapshot.

const path = require("path");
const { Worker } = require("worker_threads");
const { EventEmitter } = require("events");

const hub = new EventEmitter();
hub.setMaxListeners(50);
hub.pad = { connected: false, state: null };
hub.focus = null;
hub.status = { evdevKeyboardMouse: false };

let worker = null;
// CROSSHAIRX_DEBUG_INPUT=1 logs every key/button and focus change.
const DEBUG = process.env.CROSSHAIRX_DEBUG_INPUT === "1";

function koffiPath() {
  // koffi's .node binaries live in app.asar.unpacked when packed, or next to
  // the sources in an unpacked app directory; require.resolve handles both.
  return path.dirname(require.resolve("koffi/package.json"));
}

hub.start = function start() {
  if (worker) return hub;
  worker = new Worker(path.join(__dirname, "input-worker.js"), {
    workerData: { koffiPath: koffiPath() },
  });
  worker.unref();
  worker.on("message", (m) => {
    switch (m.t) {
      case "input":
        if (DEBUG) console.log(`[linux-input] ${m.type} ${m.keyName}${m.ctrlKey ? " +ctrl" : ""}${m.shiftKey ? " +shift" : ""}${m.altKey ? " +alt" : ""}`);
        hub.emit("input", m);
        break;
      case "pad": hub.pad = { connected: m.connected, state: m.state }; hub.emit("pad", hub.pad); break;
      case "focus":
        if (DEBUG) console.log(`[linux-input] focus window=0x${m.wid.toString(16)} pid=${m.pid}`);
        hub.focus = m;
        hub.emit("focus", m);
        break;
      case "status": hub.status = m; hub.emit("status", m); break;
      case "log": console.log(m.msg); break;
    }
  });
  worker.on("error", (e) => console.error("[linux-input] worker error:", e));
  worker.on("exit", (code) => {
    console.warn("[linux-input] worker exited with code", code);
    worker = null;
  });
  return hub;
};

hub.stop = function stop() {
  if (worker) worker.postMessage({ cmd: "stop" });
};

module.exports = hub;
