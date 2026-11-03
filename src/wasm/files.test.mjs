// files.test.mjs — browser file I/O: picker start, download, save picker and open picker.

import assert from "node:assert/strict";
import * as files from "./files.js";

{
  assert.equal(files.filePickerStartIn({}), "documents");
  assert.equal(files.filePickerStartIn({ fileHandle: { name: "game.sud" } }).name, "game.sud");
}

{
  const links = [];
  const urls = [];
  const doc = {
    defaultView: {
      URL: {
        createObjectURL: () => "blob:mock",
        revokeObjectURL: (url) => urls.push(url),
      },
    },
    createElement(tag) {
      return {
        tag,
        click() {
          links.push(this);
        },
      };
    },
  };
  const out = files.downloadBytes(new Uint8Array([1, 2, 3]), "game.sud", doc);
  assert.equal(out.ok, true);
  assert.equal(links[0].download, "game.sud");
}

{
  // Without a save picker the bytes download under the suggested name.
  let downloaded = null;
  const out = await files.persistBytes(new Uint8Array([4, 5]), {}, "sudoku_save.sud", {
    win: {},
    download(bytes, name) {
      downloaded = { bytes, name };
    },
  });
  assert.equal(out.ok, true);
  assert.deepEqual([...downloaded.bytes], [4, 5]);
  assert.equal(out.filename, "sudoku_save.sud");
}

{
  // The save picker writes the picked handle and hands it back; closing it is a cancel.
  let written = null;
  const handle = {
    name: "picked.sud",
    async createWritable() {
      return { async write(data) { written = data; }, async close() {} };
    },
  };
  const win = { showSaveFilePicker: async () => handle };
  const saved = await files.persistBytes(new Uint8Array([7]), {}, "sudoku.sud", { win, download: () => assert.fail("no download") });
  assert.equal(saved.ok, true);
  assert.equal(saved.handle, handle);
  assert.deepEqual([...written], [7]);
  const abort = Object.assign(new Error("closed"), { name: "AbortError" });
  const closed = await files.persistBytes(new Uint8Array([7]), {}, "sudoku.sud", { win: { showSaveFilePicker: async () => { throw abort; } } });
  assert.deepEqual(closed, { ok: false, cancelled: true });
}

{
  const doc = {
    defaultView: {
      showOpenFilePicker: async () => [
        {
          async getFile() {
            return {
              name: "picked.sud",
              async arrayBuffer() {
                return new Uint8Array([8, 8]).buffer;
              },
            };
          },
        },
      ],
    },
    createElement() {
      throw new Error("fallback input should not run");
    },
  };
  const picked = await files.pickBytes(doc, { fileHandle: { name: "prior.sud" } });
  assert.equal(picked.ok, true);
  assert.equal(picked.name, "picked.sud");
  assert.ok(picked.handle, "the picked handle comes back for binding");
  assert.deepEqual([...picked.bytes], [8, 8]);
}

console.log("files.test.mjs OK");
