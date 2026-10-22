"use strict";
// Maps Linux evdev key/button codes to the key names produced by the Windows
// `wininputjs` hook (GetKeyNameTextW on a US layout plus its own overrides),
// so keybinds saved on Windows keep working and the UI shows familiar names.
// X11 keycodes are evdev codes + 8.

const KEY_NAMES = {
  1: "Esc",
  2: "1", 3: "2", 4: "3", 5: "4", 6: "5", 7: "6", 8: "7", 9: "8", 10: "9", 11: "0",
  12: "-", 13: "=", 14: "Backspace", 15: "Tab",
  16: "Q", 17: "W", 18: "E", 19: "R", 20: "T", 21: "Y", 22: "U", 23: "I", 24: "O", 25: "P",
  26: "[", 27: "]", 28: "Enter", 29: "Ctrl",
  30: "A", 31: "S", 32: "D", 33: "F", 34: "G", 35: "H", 36: "J", 37: "K", 38: "L",
  39: ";", 40: "'", 41: "`", 42: "Shift", 43: "\\",
  44: "Z", 45: "X", 46: "C", 47: "V", 48: "B", 49: "N", 50: "M",
  51: ",", 52: ".", 53: "/", 54: "Shift", 55: "Num *", 56: "Alt", 57: "Space", 58: "CapsLock",
  59: "F1", 60: "F2", 61: "F3", 62: "F4", 63: "F5", 64: "F6", 65: "F7", 66: "F8", 67: "F9", 68: "F10",
  69: "Num Lock", 70: "ScrollLock",
  71: "Num 7", 72: "Num 8", 73: "Num 9", 74: "Num -",
  75: "Num 4", 76: "Num 5", 77: "Num 6", 78: "Num +",
  79: "Num 1", 80: "Num 2", 81: "Num 3", 82: "Num 0", 83: "Num Del",
  86: "\\", 87: "F11", 88: "F12",
  96: "Num Enter", 97: "Ctrl", 98: "Num /", 99: "PrintScreen", 100: "Alt",
  102: "Home", 103: "Up", 104: "PageUp", 105: "Left", 106: "Right",
  107: "End", 108: "Down", 109: "PageDown", 110: "Insert", 111: "Delete",
  113: "Mute", 114: "Volume Down", 115: "Volume Up",
  119: "Pause", 125: "Win", 126: "Win", 127: "Application",
  183: "F13", 184: "F14", 185: "F15", 186: "F16", 187: "F17", 188: "F18",
  189: "F19", 190: "F20", 191: "F21", 192: "F22", 193: "F23", 194: "F24",
  // Mouse buttons
  0x110: "LeftClick", 0x111: "RightClick", 0x112: "MiddleClick",
  0x113: "MouseBack", 0x114: "MouseForward",
  0x115: "MouseForward", 0x116: "MouseBack",
};

// X11 core pointer buttons -> names (4-7 are wheel "clicks").
const X_BUTTON_NAMES = {
  1: "LeftClick", 2: "MiddleClick", 3: "RightClick",
  4: "WheelUp", 5: "WheelDown", 6: "WheelLeft", 7: "WheelRight",
  8: "MouseBack", 9: "MouseForward",
};

const MODIFIER_OF = { Shift: "shiftKey", Ctrl: "ctrlKey", Alt: "altKey", Win: "metaKey" };

// Gamepad buttons -> xinputjs state keys.
const PAD_BUTTONS = {
  0x130: "faceSouth", 0x131: "faceEast", 0x133: "faceNorth", 0x134: "faceWest",
  0x136: "bumperLeft", 0x137: "bumperRight",
  0x138: "leftTrigger", 0x139: "rightTrigger",
  0x13a: "centerLeft", 0x13b: "centerRight",
  0x13d: "stickLeft", 0x13e: "stickRight",
  0x220: "dpadUp", 0x221: "dpadDown", 0x222: "dpadLeft", 0x223: "dpadRight",
};

const PAD_STATE_KEYS = [
  "faceSouth", "faceEast", "faceWest", "faceNorth", "bumperLeft", "bumperRight",
  "leftTrigger", "rightTrigger", "centerLeft", "centerRight", "stickLeft", "stickRight",
  "dpadUp", "dpadDown", "dpadLeft", "dpadRight",
];

function keyName(code) {
  return KEY_NAMES[code] || "unknown key";
}

module.exports = { KEY_NAMES, X_BUTTON_NAMES, MODIFIER_OF, PAD_BUTTONS, PAD_STATE_KEYS, keyName };
