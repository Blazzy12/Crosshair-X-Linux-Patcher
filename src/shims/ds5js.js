"use strict";
// Linux replacement for `ds5js`. DualSense pads are already exposed through the
// generic evdev gamepad backend (see xinputjs shim), so this reports nothing to
// avoid double-handling every button press.

module.exports = {
  isConnected: () => false,
  getState: () => null,
  tryConnect: () => false,
};
