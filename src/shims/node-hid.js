"use strict";
// Linux replacement for `node-hid`, which the app only uses for DualShock 4
// polling. DS4 pads are handled by the evdev gamepad backend instead.

class HID {
  constructor() {
    throw new Error("node-hid is not available in the Linux build");
  }
}

module.exports = { HID, devices: () => [] };
