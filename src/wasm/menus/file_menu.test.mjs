// file_menu.test.mjs — File menu session contract.

import assert from "node:assert/strict";
import * as fileMenu from "./file_menu.js";
import * as commandFlowMod from "../flows/command_flow.js";
import * as errorModalMod from "../dialogs/error_modal.js";
import { PUZZLE_LINE, hostFetch, loadGame, moveWithAutosave, openAs, postedCurrentFile, startNewGame, withCoreFlow } from "../test_support.mjs";
import * as menuBar from "./menu_bar.js";

async function flushDialogPaint() {
  if (typeof requestAnimationFrame === "function") {
    await new Promise((resolve) => {
      requestAnimationFrame(() => requestAnimationFrame(resolve));
    });
  }
  await Promise.resolve();
}

function makeBtn() {
  return {
    disabled: false,
    handlers: {},
    addEventListener(type, fn) {
      this.handlers[type] = fn;
    },
    async click() {
      const r = this.handlers.click?.();
      if (r != null && typeof r.then === "function") await r;
      return r;
    },
  };
}

function makeBoard() {
  return { children: [], replaceChildren(...nodes) { this.children = nodes; } };
}

function makeRenderElement() {
  return (tag) => ({ tag, classList: { add() {}, remove() {} }, textContent: "", dataset: {}, setAttribute() {} });
}

{
  assert.equal(fileMenu.filePickerStartIn({}), "documents");
  assert.equal(fileMenu.filePickerStartIn({ fileHandle: { name: "game.sud" } }).name, "game.sud");
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
  const out = fileMenu.downloadBytes(new Uint8Array([1, 2, 3]), "game.sud", doc);
  assert.equal(out.ok, true);
  assert.equal(links[0].download, "game.sud");
}


/** Web command handlers on a real game; `generate` answers New from `generated` and records the difficulty. */
function loadFlow(game, session, { statusEl = null, errorModal = makeErrorModal(), fetchFn = hostFetch().fetchFn, generated = [] } = {}) {
  const difficulties = [];
  const flow = {
    ...commandFlowMod.commandHandlers(game, session, { fetchFn, statusEl, onError: (failed) => errorModalMod.showErrorModal(errorModal, failed.error) }),
    generate: async (difficulty) => {
      difficulties.push(difficulty);
      return generated.shift() ?? { ok: true, line: PUZZLE_LINE };
    },
  };
  return { flow, difficulties };
}

function makeErrorModal(text = "") {
  return { el: { hidden: true }, msgEl: { textContent: text } };
}

/** File menu over a real game; options reach `wireFileMenu`. */
function wireLoads(controls, game, session, { statusEl = makeStatus(), errorModal = makeErrorModal(), commandFlow, ...options } = {}) {
  fileMenu.wireFileMenu(controls, game, makeBoard(), { select: () => {}, deselect: () => {} }, statusEl, errorModal, session, { sync() {} }, {
    difficultyDialog: { el: { hidden: true }, buttons: [] },
    download() {},
    pick: async () => ({ ok: false, cancelled: true }),
    createElement: makeRenderElement(),
    commandFlow: commandFlow ?? loadFlow(game, session, { statusEl, errorModal }).flow,
    ...options,
  });
}

function makeStatus() {
  return { textContent: "", className: "" };
}

function easyDialog() {
  return { el: { hidden: true }, buttons: fileMenu.DIFFICULTIES.map((d) => ({ ...d, el: makeBtn() })) };
}

{
  // New then Save: the generated game downloads under the host default name and keeps a host copy.
  const game = await loadGame();
  const session = { legend: { new: true, save: true }, state: { cells: [] }, default_save_filename: "host-default.sud" };
  let downloaded = null;
  const statusEl = makeStatus();
  const controls = { new: makeBtn(), save: makeBtn() };
  const difficultyDialog = easyDialog();
  wireLoads(controls, game, session, {
    statusEl,
    difficultyDialog,
    download(bytes, name) {
      downloaded = { bytes, name };
    },
  });
  controls.new.click();
  assert.equal(difficultyDialog.el.hidden, false);
  await difficultyDialog.buttons[0].el.click();
  assert.equal(difficultyDialog.el.hidden, true, "difficulty dismissed after the pick");
  assert.equal(session.state.cells[0].value, 5, "board shows the generated puzzle");
  const host = hostFetch();
  const prevFetch = globalThis.fetch;
  globalThis.fetch = host.fetchFn;
  await controls.save.click();
  globalThis.fetch = prevFetch;
  assert.deepEqual([...downloaded.bytes], [...game.serialize().bytes]);
  assert.equal(downloaded.name, "host-default.sud");
  assert.equal(session.boundFilename, "host-default.sud");
  assert.equal(statusEl.textContent, "The game was saved to host-default.sud.", "core composes the save status");
  const hosted = postedCurrentFile(host.calls);
  assert.equal(hosted?.init?.headers?.["X-Sudoku-Restore-Copy"], "true", "downloaded save keeps a hidden host copy");
}

{
  // Without a host default name there is nothing to suggest, so Save As writes nothing.
  const game = await loadGame();
  const session = { legend: { save_as: true }, state: { cells: [] } };
  let downloaded = null;
  const errorModal = makeErrorModal();
  const controls = { saveAs: makeBtn() };
  wireLoads(controls, game, session, {
    errorModal,
    download(bytes, name) {
      downloaded = { bytes, name };
    },
  });
  const prevFetch = globalThis.fetch;
  globalThis.fetch = async () => ({ ok: true, status: 204 });
  await controls.saveAs.click();
  globalThis.fetch = prevFetch;
  assert.equal(downloaded, null, "save-as requires host-provided default filename");
  assert.equal(errorModal.el.hidden, false);
}

{
  // Save As with no working file suggests the host default; the host copy is filed under it.
  const game = await loadGame();
  const session = { legend: { save_as: true }, state: { cells: [] }, default_save_filename: "host-default.sud" };
  const controls = { saveAs: makeBtn() };
  const fetchCalls = [];
  const prevFetch = globalThis.fetch;
  globalThis.fetch = async (url, init) => {
    fetchCalls.push({ url, init });
    return { ok: true, status: 204 };
  };
  wireLoads(controls, game, session);
  await controls.saveAs.click();
  globalThis.fetch = prevFetch;
  const currentFilePost = fetchCalls.find((c) => c.url === "./current-file");
  assert.equal(currentFilePost?.init?.headers?.["X-Sudoku-Filename"], "host-default.sud");
}

{
  // Save after Open suggests the opened file, not the host default.
  const game = await loadGame();
  openAs(game, "opened.sud");
  const session = { legend: { save: true }, state: { cells: [] }, default_save_filename: "host-default.sud" };
  let downloaded = null;
  const controls = { save: makeBtn() };
  wireLoads(controls, game, session, {
    download(bytes, name) {
      downloaded = { bytes, name };
    },
  });
  const prevFetch = globalThis.fetch;
  globalThis.fetch = hostFetch().fetchFn;
  await controls.save.click();
  globalThis.fetch = prevFetch;
  assert.equal(downloaded?.name, "opened.sud");
}

{
  // New opens the difficulty dialog; the picked difficulty reaches core's generate step.
  const game = await loadGame();
  const session = { state: { cells: [] }, legend: { new: true } };
  const { flow, difficulties } = loadFlow(game, session);
  const difficultyDialog = easyDialog();
  const controls = { new: makeBtn() };
  wireLoads(controls, game, session, { difficultyDialog, commandFlow: flow });
  controls.new.click();
  assert.equal(difficultyDialog.el.hidden, false, "New opens the difficulty dialog");
  assert.equal(difficulties.length, 0, "no puzzle generated until a difficulty is picked");
  await difficultyDialog.buttons[1].el.click();
  assert.equal(difficultyDialog.el.hidden, true, "dialog closes after a pick");
  assert.deepEqual(difficulties, [2], "the picked difficulty is generated");
  assert.equal(session.state.cells[0].value, 5, "board resets to the generated game");
}

{
  // A failed generation surfaces core's error; the board stays.
  const game = await loadGame();
  const session = { state: { cells: [] }, legend: { new: true } };
  const errorModal = makeErrorModal();
  const { flow } = loadFlow(game, session, { errorModal, generated: [{ ok: false, error: "gen failed" }] });
  const difficultyDialog = easyDialog();
  wireLoads({ new: makeBtn() }, game, session, { difficultyDialog, errorModal, commandFlow: flow });
  await difficultyDialog.buttons[0].el.click();
  assert.equal(errorModal.el.hidden, false, "error modal shown");
  assert.equal(errorModal.msgEl.textContent, "A new game could not be generated.");
  assert.deepEqual(session.state.cells, []);
}

{
  // New drops the picked save handle; the file label follows the game core shows.
  const game = await loadGame();
  const session = { state: { cells: [] }, legend: { new: true }, fileHandle: { name: "bound.sud" }, boundFilename: "bound.sud" };
  const difficultyDialog = easyDialog();
  wireLoads({ new: makeBtn() }, game, session, { difficultyDialog });
  await difficultyDialog.buttons[2].el.click();
  assert.equal(session.fileHandle, null, "save target unbound after New");
  assert.equal(session.boundFilename, null, "a new game has no file");
}

{
  const session = { state: { cells: [] }, legend: {} };
  const game = await loadGame();
  const { flow, difficulties } = loadFlow(game, session);
  const newBtn = makeBtn();
  const difficultyDialog = easyDialog();
  wireLoads({ new: newBtn }, game, session, { difficultyDialog, commandFlow: flow });
  newBtn.click();
  assert.equal(difficultyDialog.el.hidden, true, "legend.new off → dialog stays closed");
  assert.equal(difficulties.length, 0, "legend.new off → no generation");
}

{
  assert.equal(fileMenu.DIFFICULTIES.length, 3);
  assert.deepEqual(
    fileMenu.DIFFICULTIES.map((d) => d.difficulty),
    [1, 2, 3],
    "web New dialog matches native easy/medium/hard wire values",
  );
  let chosen = null;
  const dialog = {
    el: { hidden: true },
    buttons: fileMenu.DIFFICULTIES.map((d) => ({ ...d, el: makeBtn() })),
  };
  fileMenu.wireDifficultyDialog(dialog, (difficulty) => {
    chosen = difficulty;
  });
  await dialog.buttons[2].el.click();
  assert.equal(chosen, 3);
  assert.equal(dialog.el.hidden, true);
}

{
  let chosen = null;
  const dialog = {
    el: { hidden: false },
    buttons: fileMenu.DIFFICULTIES.map((d) => ({ ...d, el: makeBtn() })),
    cancelBtn: makeBtn(),
  };
  fileMenu.wireDifficultyDialog(dialog, (difficulty) => {
    chosen = difficulty;
  });
  await dialog.cancelBtn.click();
  assert.equal(dialog.el.hidden, true);
  assert.equal(chosen, null);
}

{
  let downloaded = null;
  const session = {};
  const out = await fileMenu.persistBytes(new Uint8Array([4, 5]), session, "sudoku_save.sud", {
    download(bytes, name) {
      downloaded = { bytes, name };
    },
  });
  assert.equal(out.ok, true);
  assert.deepEqual([...downloaded.bytes], [4, 5]);
}

{
  let last = null;
  const out = await fileMenu.persistBytes(new Uint8Array([9, 8, 7]), {}, "android.sud", {
    bridge: {
      async saveSudokuFile(base64, suggestedName, saveAs) {
        last = { base64, suggestedName, saveAs };
        return { ok: true, name: "picked.sud" };
      },
    },
    win: {},
    download() {
      throw new Error("download fallback must not run");
    },
  });
  assert.equal(out.ok, true);
  assert.equal(out.filename, "picked.sud");
  assert.equal(out.binding?.kind, "android_bridge");
  assert.equal(last.suggestedName, "android.sud");
  assert.equal(last.saveAs, false);
}

{
  const out = await fileMenu.persistBytes(new Uint8Array([1]), {}, "android.sud", {
    saveAs: true,
    bridge: {
      async saveSudokuFile(_base64, _suggestedName, saveAs) {
        assert.equal(saveAs, true);
        return { ok: false, cancelled: true };
      },
    },
    win: {},
  });
  assert.equal(out.ok, false);
  assert.equal(out.cancelled, true);
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
  const saved = await fileMenu.persistBytes(bytes, session, "sudoku_save.sud", {
    // Suggested name comes from caller when no host-provided session default is present.
    saveAs: false,
    win: { showSaveFilePicker: async () => { throw new Error("no picker"); } },
    download() { throw new Error("no download"); },
  });
  assert.equal(saved.ok, true);
  assert.equal(saved.binding?.kind, "file_handle");
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
  const picked = await fileMenu.pickBytes(doc, { fileHandle: { name: "prior.sud" } });
  assert.equal(picked.ok, true);
  assert.equal(picked.name, "picked.sud");
  assert.equal(picked.binding?.kind, "file_handle");
  assert.deepEqual([...picked.bytes], [8, 8]);
}

{
  const bytes = new Uint8Array([2, 4, 6, 8]);
  const base64 = Buffer.from(bytes).toString("base64");
  const doc = {
    defaultView: {
      AndroidFileBridge: {
        async openSudokuFile() {
          return { ok: true, name: "bridge.sud", base64 };
        },
      },
    },
    createElement() {
      throw new Error("input fallback should not run");
    },
  };
  const picked = await fileMenu.pickBytes(doc, {});
  assert.equal(picked.ok, true);
  assert.equal(picked.name, "bridge.sud");
  assert.equal(picked.binding?.kind, "android_bridge");
  assert.deepEqual([...picked.bytes], [...bytes]);
}

{
  const doc = {
    defaultView: {
      AndroidFileBridge: {
        async openSudokuFile() {
          return { ok: false, cancelled: true };
        },
      },
    },
  };
  const picked = await fileMenu.pickBytes(doc, {});
  assert.equal(picked.ok, false);
  assert.equal(picked.cancelled, true);
}


// Import loads a valid one-line puzzle file, resets the board, and unbinds the save target
{
  const game = await loadGame();
  const session = {
    legend: { import: true },
    state: { cells: [] },
    fileHandle: { name: "game.sud" },
    boundFilename: "game.sud",
  };
  const errorModal = makeErrorModal("old");
  const importBtn = makeBtn();
  wireLoads({ import: importBtn }, game, session, {
    errorModal,
    pick: async (sessionArg, opts) => {
      assert.equal(opts.accept, ".txt,text/plain", "puzzle picker targets text files");
      assert.equal(sessionArg, session);
      return { ok: true, name: "puzzle.txt", bytes: new TextEncoder().encode(PUZZLE_LINE) };
    },
  });
  await importBtn.click();
  assert.equal(session.state.cells[0].value, 5, "board resets from the imported puzzle");
  assert.equal(session.fileHandle, null, "save target unbound after import");
  assert.equal(session.boundFilename, null, "bound filename cleared after import");
  assert.equal(errorModal.el.hidden, true, "no error modal on success");
}

// Import with an invalid file surfaces core's error; board and save target stay intact
{
  const game = await loadGame();
  const session = {
    legend: { import: true },
    state: { cells: [{ value: 2, given: true, conflict: false }] },
    fileHandle: { name: "game.sud" },
    boundFilename: "game.sud",
  };
  const errorModal = makeErrorModal("old");
  const before = JSON.stringify(session.state);
  const importBtn = makeBtn();
  wireLoads({ import: importBtn }, game, session, {
    errorModal,
    pick: async () => ({ ok: true, name: "bad.txt", bytes: new TextEncoder().encode("oops") }),
  });
  await importBtn.click();
  assert.equal(errorModal.el.hidden, false, "error modal opens on invalid import");
  assert.match(errorModal.msgEl.textContent, /81/);
  assert.equal(JSON.stringify(session.state), before, "board untouched after failed import");
  assert.equal(session.fileHandle.name, "game.sud", "save target kept after failed import");
  assert.equal(session.boundFilename, "game.sud", "bound filename kept after failed import");
}

// Open binds the picked file: its handle becomes the save target and its name the label
{
  const game = await loadGame();
  const source = await loadGame();
  startNewGame(source);
  const handle = { name: "picked.sud" };
  const session = { legend: { open: true }, state: { cells: [] } };
  const openBtn = makeBtn();
  wireLoads({ open: openBtn }, game, session, {
    pick: async () => ({ ok: true, name: "picked.sud", handle, bytes: source.serialize().bytes }),
  });
  await openBtn.click();
  assert.equal(session.state.cells[0].value, 5);
  assert.equal(session.fileHandle, handle);
  assert.equal(session.boundFilename, "picked.sud");
}

// Import is a no-op when the legend does not offer it
{
  let picked = false;
  const session = { legend: {}, state: { cells: [] } };
  const importBtn = makeBtn();
  wireLoads({ import: importBtn }, await loadGame(), session, {
    pick: async () => {
      picked = true;
      return { ok: true };
    },
  });
  await importBtn.click();
  assert.equal(picked, false, "no picker when legend.import is off");
}


// Export writes bytes from exportPuzzle via the text save path; save target stays bound
{
  const lineBytes = new TextEncoder().encode("003020600900305001001806400008102900700000008006708200002609500800203009005010300");
  const session = {
    legend: { [menuBar.LEGEND_WIRE_EXPORT]: true },
    state: { cells: [{ value: 1, given: true, conflict: false }] },
    fileHandle: { name: "game.sud" },
    boundFilename: "game.sud",
  };
  let saved = null;
  const game = {
    exportPuzzle() {
      return { ok: true, bytes: lineBytes };
    },
  };
  const exportBtn = makeBtn();
  const statusEl = { textContent: "", className: "" };
  await withCoreFlow(game);
  fileMenu.wireFileMenu(
    { export: exportBtn },
    game,
    makeBoard(),
    { select: () => {}, deselect: () => {} },
    statusEl,
    { el: { hidden: true }, msgEl: { textContent: "" } },
    session,
    { sync() {} },
    {
      difficultyDialog: { el: { hidden: true }, buttons: [] },
      download() {},
      pick: async () => ({ ok: false, cancelled: true }),
      exportText: async (bytes, sessionArg, name) => {
        assert.equal(sessionArg, session);
        assert.equal(name, "puzzle.txt");
        saved = bytes;
        return { ok: true, filename: "puzzle.txt" };
      },
      createElement: makeRenderElement(),
    },
  );
  await exportBtn.click();
  assert.deepEqual([...saved], [...lineBytes], "save receives exportPuzzle bytes");
  assert.equal(statusEl.textContent, "The puzzle was exported to puzzle.txt.", "core owns the export status");
  assert.equal(session.fileHandle.name, "game.sud", "export must not bind SUD0 file handle");
  assert.equal(session.boundFilename, "game.sud");
}

// Export failure surfaces error; board and save target unchanged
{
  const session = {
    legend: { [menuBar.LEGEND_WIRE_EXPORT]: true },
    state: { cells: [{ value: 2, given: true, conflict: false }] },
    fileHandle: { name: "game.sud" },
    boundFilename: "game.sud",
  };
  const game = {
    exportPuzzle() {
      return { ok: true, bytes: new TextEncoder().encode("x".repeat(81)) };
    },
  };
  const errorModal = { el: { hidden: true }, msgEl: { textContent: "old" } };
  const before = JSON.stringify(session.state);
  const exportBtn = makeBtn();
  await withCoreFlow(game);
  fileMenu.wireFileMenu(
    { export: exportBtn },
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
      pick: async () => ({ ok: false, cancelled: true }),
      exportText: async () => ({ ok: false, error: "export: write failed" }),
      createElement: makeRenderElement(),
    },
  );
  await exportBtn.click();
  assert.equal(errorModal.el.hidden, false);
  assert.equal(errorModal.msgEl.textContent, "The puzzle could not be exported.");
  assert.equal(JSON.stringify(session.state), before);
  assert.equal(session.fileHandle.name, "game.sud");
}

// Export is a no-op when the legend does not offer it
{
  let called = false;
  const exportBtn = makeBtn();
  fileMenu.wireFileMenu(
    { export: exportBtn },
    { exportPuzzle() { called = true; return { ok: true }; } },
    makeBoard(),
    { select: () => {}, deselect: () => {} },
    { textContent: "", className: "" },
    { el: { hidden: true }, msgEl: { textContent: "" } },
    { legend: {}, state: { cells: [] } },
    { sync() {} },
    {
      difficultyDialog: { el: { hidden: true }, buttons: [] },
      download() {},
      pick: async () => ({ ok: false, cancelled: true }),
      exportText: async () => { throw new Error("must not run"); },
      createElement: makeRenderElement(),
    },
  );
  await exportBtn.click();
  assert.equal(called, false);
}

// First autosave with nothing bound writes the host default file only: no Save As, no download.
{
  let downloads = 0;
  let picks = 0;
  const hostWrites = [];
  const session = {
    legend: {},
    state: { cells: [] },
    config: { auto_save: true },
    default_save_filename: "sudoku.sud",
  };
  const game = { serialize: () => ({ ok: true, bytes: new Uint8Array([4, 2]) }) };
  await withCoreFlow(game, { autoSave: true });
  fileMenu.wireFileMenu(
    {},
    game,
    makeBoard(),
    { select: () => {}, deselect: () => {} },
    { textContent: "", className: "" },
    { el: { hidden: true }, msgEl: { textContent: "" } },
    session,
    { sync() {} },
    {
      difficultyDialog: { el: { hidden: true }, buttons: [] },
      download() {
        downloads += 1;
      },
      pick: async () => {
        picks += 1;
        return { ok: false, cancelled: true };
      },
      createElement: makeRenderElement(),
    },
  );
  const host = hostFetch();
  const fetchFn = async (url, init) => {
    if (url === "./current-file") hostWrites.push([...new Uint8Array(init.body)]);
    return host.fetchFn(url, init);
  };
  await moveWithAutosave(game, session, { fetchFn });
  assert.equal(downloads, 0, "autosave must not download");
  assert.equal(picks, 0, "autosave must not open a picker");
  assert.deepEqual(hostWrites, [[4, 2]]);
}

// Android with nothing bound: autosave after File → New still hands the bytes to the bridge default file.
{
  const bridgeWrites = [];
  const prevBridge = globalThis.AndroidFileBridge;
  const prevFetch = globalThis.fetch;
  globalThis.AndroidFileBridge = {
    saveCurrentSudokuFile(base64, suggestedName) {
      bridgeWrites.push(suggestedName);
      return { ok: true, name: suggestedName };
    },
    currentSudokuFileName: () => "",
  };
  globalThis.fetch = async () => ({ ok: true, status: 204, json: async () => ({}) });
  const session = {
    legend: { new: true },
    state: { cells: [] },
    config: { auto_save: true },
    default_save_filename: "sudoku.sud",
  };
  const game = await loadGame({ auto_save: true });
  const difficultyDialog = easyDialog();
  try {
    wireLoads({ new: makeBtn() }, game, session, { difficultyDialog });
    await difficultyDialog.buttons[0].el.click();
    bridgeWrites.length = 0;
    await moveWithAutosave(game, session, { fetchFn: globalThis.fetch });
    assert.deepEqual(bridgeWrites, ["sudoku.sud"]);
  } finally {
    globalThis.AndroidFileBridge = prevBridge;
    globalThis.fetch = prevFetch;
  }
}

// Android autosave adopts the file name the bridge actually wrote (e.g. a new name the user picked).
{
  const prevBridge = globalThis.AndroidFileBridge;
  const hostNames = [];
  globalThis.AndroidFileBridge = {
    saveCurrentSudokuFile: () => ({ ok: true, name: "game2.sud" }),
    currentSudokuFileName: () => "",
  };
  const session = {
    legend: {},
    state: { cells: [] },
    config: { auto_save: true },
    default_save_filename: "sudoku.sud",
  };
  const game = { serialize: () => ({ ok: true, bytes: new Uint8Array([4, 2]) }) };
  try {
    await withCoreFlow(game, { autoSave: true });
    fileMenu.wireFileMenu(
      {},
      game,
      makeBoard(),
      { select: () => {}, deselect: () => {} },
      { textContent: "", className: "" },
      { el: { hidden: true }, msgEl: { textContent: "" } },
      session,
      { sync() {} },
      {
        difficultyDialog: { el: { hidden: true }, buttons: [] },
        download() {},
        pick: async () => ({ ok: false, cancelled: true }),
        createElement: makeRenderElement(),
      },
    );
    const fetchFn = async (url, init) => {
      if (url === "./current-file") hostNames.push(init.headers?.["X-Sudoku-Filename"]);
      return { ok: true, status: 204 };
    };
    await moveWithAutosave(game, session, { fetchFn });
    assert.equal(session.boundFilename, "game2.sud");
    assert.deepEqual(hostNames, ["game2.sud"]);
  } finally {
    globalThis.AndroidFileBridge = prevBridge;
  }
}

// Android default file taken by an earlier install: core asks pick-or-rename until a picker writes a file.
{
  const prevBridge = globalThis.AndroidFileBridge;
  const prevChoose = globalThis.__sudokuChoose;
  const calls = [];
  const answers = [false, true];
  globalThis.__sudokuChoose = async (message, labels) => {
    calls.push(["ask", labels.okLabel, labels.cancelLabel]);
    assert.equal(labels.title, "Autosave file");
    assert.match(message, /sudoku\.sud in Download\/Sudoku/);
    return answers.shift();
  };
  globalThis.AndroidFileBridge = {
    saveCurrentSudokuFile: () => {
      calls.push(["current"]);
      return { ok: false, reason: "default_taken", name: "sudoku.sud", dir: "Download/Sudoku" };
    },
    saveSudokuFile: (_b64, name, saveAs) => {
      calls.push(["new_name", name, saveAs]);
      return { ok: false, cancelled: true };
    },
    saveSudokuFileToExisting: () => {
      calls.push(["pick_existing"]);
      return { ok: true, name: "sudoku.sud" };
    },
    currentSudokuFileName: () => "",
  };
  const session = {
    legend: {},
    state: { cells: [] },
    config: { auto_save: true },
    default_save_filename: "sudoku.sud",
  };
  const game = { serialize: () => ({ ok: true, bytes: new Uint8Array([4, 2]) }) };
  try {
    await withCoreFlow(game, { autoSave: true });
    fileMenu.wireFileMenu(
      {},
      game,
      makeBoard(),
      { select: () => {}, deselect: () => {} },
      { textContent: "", className: "" },
      { el: { hidden: true }, msgEl: { textContent: "" } },
      session,
      { sync() {} },
      {
        difficultyDialog: { el: { hidden: true }, buttons: [] },
        download() {},
        pick: async () => ({ ok: false, cancelled: true }),
        createElement: makeRenderElement(),
      },
    );
    let errors = 0;
    await moveWithAutosave(game, session, {
      fetchFn: async () => ({ ok: true, status: 204 }),
      onError: () => { errors += 1; },
    });
    assert.deepEqual(calls, [
      ["current"],
      ["ask", "Pick it", "New name"],
      ["new_name", "sudoku.sud", true],
      ["ask", "Pick it", "New name"],
      ["pick_existing"],
    ]);
    assert.equal(errors, 0);
    assert.equal(session.boundFilename, "sudoku.sud");
  } finally {
    globalThis.AndroidFileBridge = prevBridge;
    globalThis.__sudokuChoose = prevChoose;
  }
}

console.log("file_menu.test.mjs OK");
