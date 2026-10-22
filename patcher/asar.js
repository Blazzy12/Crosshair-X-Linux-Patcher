"use strict";
// Minimal, dependency-free asar extractor (read-only).
//
// Layout: [u32 4][u32 headerPickleSize][pickle: u32 payload, u32 jsonLen, json]
// followed by file contents; file offsets are relative to the end of the
// header. Entries marked "unpacked" live in "<archive>.unpacked/".
//
// Electron's fs treats *.asar files as directories; callers running under
// Electron (including ELECTRON_RUN_AS_NODE) set process.noAsar = true first.

const fs = require("fs");
const path = require("path");

function readHeader(fd) {
  const sizeBuf = Buffer.alloc(8);
  fs.readSync(fd, sizeBuf, 0, 8, 0);
  const headerSize = sizeBuf.readUInt32LE(4);
  const headerBuf = Buffer.alloc(headerSize);
  fs.readSync(fd, headerBuf, 0, headerSize, 8);
  const jsonLen = headerBuf.readUInt32LE(4);
  const header = JSON.parse(headerBuf.subarray(8, 8 + jsonLen).toString("utf8"));
  return { header, base: 8 + headerSize };
}

function safeJoin(root, rel) {
  const out = path.resolve(root, rel);
  if (out !== root && !out.startsWith(root + path.sep)) throw new Error(`asar entry escapes destination: ${rel}`);
  return out;
}

function extractAll(archive, dest) {
  dest = path.resolve(dest);
  const unpackedRoot = archive + ".unpacked";
  const fd = fs.openSync(archive, "r");
  try {
    const { header, base } = readHeader(fd);
    fs.mkdirSync(dest, { recursive: true });
    const walk = (node, rel) => {
      for (const [name, entry] of Object.entries(node.files || {})) {
        if (name.includes("/") || name.includes("\\") || name === ".." || name === ".") throw new Error(`bad asar entry name: ${name}`);
        const r = rel ? rel + "/" + name : name;
        const out = safeJoin(dest, r);
        if (entry.files) {
          fs.mkdirSync(out, { recursive: true });
          walk(entry, r);
        } else if (entry.link) {
          const target = safeJoin(dest, entry.link); // validate it stays inside
          fs.symlinkSync(path.relative(path.dirname(out), target), out);
        } else if (entry.unpacked) {
          fs.copyFileSync(path.join(unpackedRoot, r), out);
          if (entry.executable) fs.chmodSync(out, 0o755);
        } else {
          const size = entry.size;
          const buf = Buffer.alloc(size);
          let done = 0;
          const start = base + Number(entry.offset);
          while (done < size) done += fs.readSync(fd, buf, done, size - done, start + done);
          fs.writeFileSync(out, buf, { mode: entry.executable ? 0o755 : 0o644 });
        }
      }
    };
    walk(header, "");
  } finally {
    fs.closeSync(fd);
  }
}

module.exports = { extractAll };
