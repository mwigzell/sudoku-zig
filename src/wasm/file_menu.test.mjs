// file_menu.test.mjs — File menu session contract.

import assert from "node:assert/strict";
import {
  refreshSession,
  downloadBytes,
  persistBytes,
  pickBytes,
  wireFileMenu,
  DEFAULT_SAVE_FILENAME,
  filePickerStartIn,
} from "./file_menu.js";

function makeBtn() {
  return { disabled: false, handlers: {}, addEventListener(type, fn) { this.handlers[type] = fn; }, click() { this.handlers.click?.(); } };
}

function makeBoard() {
  return { children: [], replaceChildren(...nodes) { this.children = nodes; } };
}

function makeRenderElement() {
  return (tag) => ({ tag, classList: { add() {}, remove() {} }, textContent: "", dataset: {}, setAttribute() {} });
}

{
  const board = makeBoard();
  const session = { state: { cells: [] }, legend: { save: true }, config: { theme: "dark", show_region: false } };
  let synced = false;
  refreshSession(
    board,
    { select: () => {} },
    { textContent: "old", className: "" },
    session,
    { sync: () => { synced = true; } },
    { cells: [{ value: 1, given: true, conflict: false }] },
    { save: true, undo: false },
    { theme: "light", show_region: true },
    makeRenderElement(),
  );
  assert.equal(session.state.cells[0].value, 1);
  assert.equal(session.legend.undo, false);
  assert.equal(session.config.theme, "light");
  assert.equal(synced, true);
}

{
  assert.equal(filePickerStartIn({}), "documents");
  assert.equal(filePickerStartIn({ fileHandle: { name: "game.sud" } }).name, "game.sud");
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
  const out = downloadBytes(new Uint8Array([1, 2, 3]), "game.sud", doc);
  assert.equal(out.ok, true);
  assert.equal(links[0].download, "game.sud");
}

{
  const board = makeBoard();
  const session = {
    legend: { new: true, open: true, save: true, save_as: true },
    state: { cells: [] },
  };
  let downloaded = null;
  const game = {
    init() {
      return { ok: true };
    },
    getState() {
      return { cells: [{ value: 0, given: false, conflict: false }] };
    },
    getLegend() {
      return { new: true, save: true, open: true, save_as: true, undo: false, redo: false };
    },
    getConfig() {
      return { theme: "dark", show_region: false };
    },
    serialize() {
      return new Uint8Array([9, 9, 9]);
    },
  };
  const controls = {
    new: makeBtn(),
    open: makeBtn(),
    save: makeBtn(),
    saveAs: makeBtn(),
  };
  const renderElement = makeRenderElement();

  wireFileMenu(
    controls,
    game,
    board,
    { select: () => {} },
    { textContent: "", className: "" },
    { el: { hidden: true }, msgEl: { textContent: "" } },
    session,
    { sync() {} },
    {
      difficulty: 1,
      download(bytes, name) {
        downloaded = { bytes, name };
      },
      pick: async () => ({ ok: false, cancelled: true }),
      createElement: renderElement,
    },
  );

  controls.new.click();
  assert.equal(session.state.cells.length, 1);
  controls.save.click();
  assert.deepEqual([...downloaded.bytes], [9, 9, 9]);
  assert.equal(downloaded.name, DEFAULT_SAVE_FILENAME);
}

{
  let downloaded = null;
  const session = {};
  const out = await persistBytes(new Uint8Array([4, 5]), session, DEFAULT_SAVE_FILENAME, {
    download(bytes, name) {
      downloaded = { bytes, name };
    },
  });
  assert.equal(out.ok, true);
  assert.deepEqual([...downloaded.bytes], [4, 5]);
}

{
  let written = null;
  const session = {
    fileHandle: {
      name: "opened.sud",
      async createWritable() {
        return {
          async write(data) {
            written = data;
          },
          async close() {},
        };
      },
    },
  };
  const bytes = new Uint8Array([7]);
  const saved = await persistBytes(bytes, session, DEFAULT_SAVE_FILENAME, {
    saveAs: false,
    win: { showSaveFilePicker: async () => { throw new Error("no picker"); } },
    download() { throw new Error("no download"); },
  });
  assert.equal(saved.ok, true);
  assert.deepEqual([...written], [7]);
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
  const picked = await pickBytes(doc, { fileHandle: { name: "prior.sud" } });
  assert.equal(picked.ok, true);
  assert.equal(picked.name, "picked.sud");
  assert.deepEqual([...picked.bytes], [8, 8]);
}

console.log("file_menu.test.mjs OK");
