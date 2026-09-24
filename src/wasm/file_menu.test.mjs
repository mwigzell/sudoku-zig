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
  return { disabled: false, handlers: {}, addEventListener(type, fn) { this.handlers[type] = fn; }, click() { return this.handlers.click?.(); } };
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
    { select: () => {}, deselect: () => {} },
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
  const board = makeBoard();
  const status = { textContent: "old", className: "" };
  refreshSession(
    board,
    { select: () => {}, deselect: () => {} },
    status,
    { state: { cells: [] }, legend: {}, config: {} },
    { sync() {} },
    { cells: [] },
    {},
    {},
    makeRenderElement(),
    undefined,
    "opened: game.sud; this puzzle has no solution",
  );
  assert.match(status.textContent, /no solution/i);
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
      return { ok: true, bytes: new Uint8Array([9, 9, 9]) };
    },
  };
  const controls = {
    new: makeBtn(),
    open: makeBtn(),
    save: makeBtn(),
    saveAs: makeBtn(),
  };
  const renderElement = makeRenderElement();

  const newDialog = { el: { hidden: true }, buttons: [{ label: "Easy", difficulty: 1, el: makeBtn() }] };
  wireFileMenu(
    controls,
    game,
    board,
    { select: () => {}, deselect: () => {} },
    { textContent: "", className: "" },
    { el: { hidden: true }, msgEl: { textContent: "" } },
    session,
    { sync() {} },
    {
      difficultyDialog: newDialog,
      download(bytes, name) {
        downloaded = { bytes, name };
      },
      pick: async () => ({ ok: false, cancelled: true }),
      createElement: renderElement,
    },
  );

  controls.new.click();
  assert.equal(newDialog.el.hidden, false);
  newDialog.buttons[0].el.click();
  assert.equal(newDialog.el.hidden, true);
  assert.equal(session.state.cells.length, 1, "board reset from fresh puzzle");
  controls.save.click();
  assert.deepEqual([...downloaded.bytes], [9, 9, 9]);
  assert.equal(downloaded.name, DEFAULT_SAVE_FILENAME);
}

{
  // New is a sub-dialog: it opens a difficulty picker instead of generating immediately;
  // the picked difficulty drives generation, then the board resets.
  const session = { state: { cells: [] }, legend: { new: true, save: false, open: false, save_as: false } };
  const initCalls = [];
  const game = {
    init(opts) {
      initCalls.push(opts);
      return { ok: true };
    },
    getState() {
      return { cells: [{ value: 1, given: true, conflict: false }] };
    },
    getLegend() {
      return { new: true, save: true, open: true, save_as: true, undo: false, redo: false };
    },
    getConfig() {
      return { theme: "light", show_region: false };
    },
  };
  const difficultyDialog = {
    el: { hidden: true },
    buttons: [
      { label: "Easy", difficulty: 1, el: makeBtn() },
      { label: "Medium", difficulty: 2, el: makeBtn() },
      { label: "Hard", difficulty: 3, el: makeBtn() },
    ],
  };
  const controls = { new: makeBtn() };

  wireFileMenu(
    controls,
    game,
    makeBoard(),
    { select: () => {}, deselect: () => {} },
    { textContent: "", className: "" },
    { el: { hidden: true }, msgEl: { textContent: "" } },
    session,
    { sync() {} },
    {
      difficultyDialog,
      download() {},
      pick: async () => ({ ok: false, cancelled: true }),
      createElement: makeRenderElement(),
    },
  );

  controls.new.click();
  assert.equal(difficultyDialog.el.hidden, false, "New opens the difficulty dialog");
  assert.equal(initCalls.length, 0, "no puzzle generated until a difficulty is picked");

  difficultyDialog.buttons[1].el.click(); // Medium
  assert.equal(difficultyDialog.el.hidden, true, "dialog closes after a pick");
  assert.equal(initCalls.length, 1, "pick drives generation");
  assert.equal(initCalls[0].difficulty, 2, "the picked difficulty is used");
  assert.equal(session.state.cells.length, 1, "board resets from the fresh game");
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


// Import loads a valid one-line puzzle file, resets the board, and unbinds the save target
{
  const line = "123456789".repeat(9);
  const session = {
    legend: { import: true },
    state: { cells: [{ value: 1, given: true, conflict: false }] },
    fileHandle: { name: "game.sud" },
    boundFilename: "game.sud",
  };
  let imported = null;
  const game = {
    importPuzzle(text) {
      imported = text;
      return { ok: true, msg: "import: puzzle loaded" };
    },
    getState() {
      return { cells: [{ value: 9, given: false, conflict: false }] };
    },
    getLegend() {
      return { import: true, undo: false };
    },
    getConfig() {
      return { theme: "dark", show_region: false };
    },
  };
  const errorModal = { el: { hidden: true }, msgEl: { textContent: "old" } };
  const importBtn = makeBtn();
  wireFileMenu(
    { import: importBtn },
    game,
    makeBoard(),
    { select: () => {}, deselect: () => {} },
    { textContent: "", className: "" },
    errorModal,
    session,
    { sync() {} },
    {
      difficultyDialog: { el: { hidden: true }, buttons: [] },
      download() {},
      pick: async (sessionArg, opts) => {
        assert.equal(opts.accept, ".txt,text/plain", "puzzle picker targets text files");
        assert.equal(sessionArg, session);
        return { ok: true, name: "puzzle.txt", bytes: new TextEncoder().encode(line) };
      },
      createElement: makeRenderElement(),
    },
  );
  await importBtn.click();
  assert.equal(imported, line, "picked file text reaches the engine");
  assert.equal(session.state.cells.length, 1, "board resets from the imported puzzle");
  assert.equal(session.fileHandle, null, "save target unbound after import");
  assert.equal(session.boundFilename, null, "bound filename cleared after import");
  assert.equal(errorModal.el.hidden, true, "no error modal on success");
  assert.match(errorModal.msgEl.textContent, /old/, "status not clobbered");
}

// Import with an invalid file surfaces the engine error; board and save target stay intact
{
  const session = {
    legend: { import: true },
    state: { cells: [{ value: 2, given: true, conflict: false }] },
    fileHandle: { name: "game.sud" },
    boundFilename: "game.sud",
  };
  const game = {
    importPuzzle() {
      return { ok: false, error: "import: expected exactly 81 characters" };
    },
  };
  const errorModal = { el: { hidden: true }, msgEl: { textContent: "old" } };
  const before = JSON.stringify(session.state);
  const importBtn = makeBtn();
  wireFileMenu(
    { import: importBtn },
    game,
    makeBoard(),
    { select: () => {}, deselect: () => {} },
    { textContent: "", className: "" },
    errorModal,
    session,
    { sync() {} },
    {
      difficultyDialog: { el: { hidden: true }, buttons: [] },
      download() {},
      pick: async () => ({ ok: true, name: "bad.txt", bytes: new TextEncoder().encode("oops") }),
      createElement: makeRenderElement(),
    },
  );
  await importBtn.click();
  assert.equal(errorModal.el.hidden, false, "error modal opens on invalid import");
  assert.match(errorModal.msgEl.textContent, /expected exactly 81 characters/);
  assert.equal(JSON.stringify(session.state), before, "board untouched after failed import");
  assert.equal(session.fileHandle.name, "game.sud", "save target kept after failed import");
  assert.equal(session.boundFilename, "game.sud", "bound filename kept after failed import");
}

// Import is a no-op when the legend does not offer it
{
  let picked = false;
  const session = { legend: {}, state: { cells: [] } };
  const errorModal = { el: { hidden: true }, msgEl: { textContent: "" } };
  const importBtn = makeBtn();
  wireFileMenu(
    { import: importBtn },
    { importPuzzle() { throw new Error("must not run"); } },
    makeBoard(),
    { select: () => {}, deselect: () => {} },
    { textContent: "", className: "" },
    errorModal,
    session,
    { sync() {} },
    {
      difficultyDialog: { el: { hidden: true }, buttons: [] },
      download() {},
      pick: async () => { picked = true; return { ok: true }; },
      createElement: makeRenderElement(),
    },
  );
  await importBtn.click();
  assert.equal(picked, false, "no picker when legend.import is off");
}

console.log("file_menu.test.mjs OK");
