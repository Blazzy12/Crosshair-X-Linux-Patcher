"use strict";
// Linux replacement for `cpgwinrt` (WinRT: Xbox Game Bar widget package
// management and URI launching). There is no Game Bar on Linux.

const { shell } = require("electron");

module.exports = {
  packageManager: {
    isPackageInstalled: () => false,
    getPackageInfo: async () => null,
  },
  launcher: {
    launchUri: (uri) => {
      if (/^https?:/i.test(uri)) return shell.openExternal(uri).then(() => true, () => false);
      return Promise.resolve(false);
    },
  },
  startupTask: {
    getStartupTaskStatus: async () => "disabled",
    enableAutoLaunch: async () => false,
    disableAutoLaunch: async () => false,
  },
};
