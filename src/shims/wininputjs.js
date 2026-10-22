"use strict";
// Linux replacement for `wininputjs` (global raw keyboard/mouse hook).
// Emits ("keydown"|"keyup", { keyName, combination, ctrlKey, metaKey,
// shiftKey, altKey, isOnlyModifier }) exactly like the Windows module.

const input = require("../platform/input.js");

let callbackSet = false;
const combination = [];

function setInputCallback(cb) {
  if (callbackSet) throw new Error("Attempted to call setInputCallback() more than once -- this is illegal.");
  callbackSet = true;
  input.start().on("input", (m) => {
    const idx = combination.indexOf(m.keyName);
    if (m.type === "keydown" && idx === -1) combination.push(m.keyName);
    if (m.type === "keyup" && idx !== -1) combination.splice(idx, 1);
    try {
      cb(m.type, {
        keyName: m.keyName,
        combination: [...combination],
        ctrlKey: m.ctrlKey,
        metaKey: m.metaKey,
        shiftKey: m.shiftKey,
        altKey: m.altKey,
        isOnlyModifier: ["Shift", "Ctrl", "Alt", "Win"].includes(m.keyName),
      });
    } catch (e) {
      console.error("UNHANDLED EXCEPTION INSIDE CALLBACK: " + (e && e.message));
    }
  });
  console.log("Set input hook function.");
}

module.exports = {
  setInputCallback,
  isInputCallbackSet: () => callbackSet,
};
