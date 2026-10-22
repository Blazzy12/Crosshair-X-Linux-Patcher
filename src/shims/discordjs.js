"use strict";
// The Discord Social SDK binding is Windows-only. The app already treats a
// failed load as "Discord features disabled".
throw new Error("discordjs native module is not available on Linux");
