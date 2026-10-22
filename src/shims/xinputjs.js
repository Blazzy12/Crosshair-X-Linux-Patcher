"use strict";
// Linux replacement for `xinputjs`: any evdev gamepad (Xbox, DualShock,
// DualSense, Steam virtual pads...) reported with the XInput state layout.

const input = require("../platform/input.js");

module.exports = {
  isConnected() {
    input.start();
    return input.pad.connected;
  },
  getState() {
    input.start();
    return input.pad.connected && input.pad.state ? { ...input.pad.state } : null;
  },
};
