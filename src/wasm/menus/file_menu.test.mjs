// file_menu.test.mjs — File menu session contract on the browser's step handlers.

import assert from "node:assert/strict";
import * as fileMenu from "./file_menu.js";
import * as webSteps from "../flows/web_steps.js";
import { PUZZLE_LINE, noPromptDialog, promptDialogStub, hostFetch, loadGame, moveWithAutosave, openAs, postedCurrentFile, startNewGame, withCoreFlow, coreText, configTable, fakeElement, fillText } from "../test_support.mjs";
import * as settings from "./settings.js";
import * as menuBar from "./menu_bar.js";

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

/**
 * File menu over `game` with the browser's step handlers; `generated` answers New and records
 * the difficulty, the rest of `options` reach `webSteps` (pick, download, exportText, ...).
 */
function wireFile(controls, game, session, { statusEl = makeStatus(), difficultyDialog = { el: { hidden: true }, buttons: [] }, generated = [], ...options } = {}) {
  const difficulties = [];
  const steps = {
    ...webSteps.webSteps(game, session, {
      statusEl,
      download() {},
      pick: async () => ({ ok: false, cancelled: true }),
      ...options,
    }),
    generateGame: async (difficulty) => {
      difficulties.push(difficulty);
      return generated.shift() ?? { ok: true, line: PUZZLE_LINE };
    },
  };
  fileMenu.wireFileMenu(controls, game, makeBoard(), statusEl, session, { sync() {} }, {
    difficultyDialog,
    createElement: makeRenderElement(),
    steps,
  });
  return { difficulties, steps };
}

/** New's difficulty buttons as the page wires them: one per choice of the table's difficulty row, by name. */
const DIFFICULTY_BUTTONS = settings
  .configRow(configTable, settings.DIFFICULTY_FIELD)
  .choices.map((c) => ({ label: c.label, difficulty: c.name }));

// ── New's buttons are generated from the table: core's label, the choice's name ──
{
  const container = fakeElement("div");
  const buttons = fileMenu.buildDifficultyButtons(container, configTable, fakeElement);
  assert.deepEqual(buttons.map((b) => [b.difficulty, b.el.textContent]), DIFFICULTY_BUTTONS.map((d) => [d.difficulty, d.label]));
  assert.equal(container.children.length, buttons.length);
  assert.equal(buttons[0].el.className, "new-difficulty-btn");
}

function makeStatus() {
  return { textContent: "", className: "" };
}

function easyDialog() {
  return { el: { hidden: true }, buttons: DIFFICULTY_BUTTONS.map((d) => ({ ...d, el: makeBtn() })) };
}

{
  // New then Save: the generated game downloads under the host default name and keeps a host copy.
  const game = await loadGame();
  const session = { legend: { new: true, save: true }, state: { cells: [] }, default_save_filename: "host-default.sud" };
  let downloaded = null;
  const statusEl = makeStatus();
  const controls = { new: makeBtn(), save: makeBtn() };
  const difficultyDialog = easyDialog();
  wireFile(controls, game, session, {
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
  assert.deepEqual([...downloaded.bytes], [...game.toSaveFormat().bytes]);
  assert.equal(downloaded.name, "host-default.sud");
  assert.equal(session.boundFilename, "host-default.sud");
  assert.equal(statusEl.textContent, fillText(coreText.SAVED_TO_FMT, "host-default.sud"), "core composes the save status");
  const hosted = postedCurrentFile(host.calls);
  assert.equal(hosted?.init?.headers?.["X-Sudoku-Restore-Copy"], "true", "downloaded save keeps a hidden host copy");
}

{
  // Without a host default name there is nothing to suggest, so Save As writes nothing.
  const game = await loadGame();
  const session = { legend: { save_as: true }, state: { cells: [] } };
  let downloaded = null;
  const prompts = promptDialogStub();
  const controls = { saveAs: makeBtn() };
  wireFile(controls, game, session, {
    promptDialog: prompts,
    download(bytes, name) {
      downloaded = { bytes, name };
    },
  });
  const prevFetch = globalThis.fetch;
  globalThis.fetch = async () => ({ ok: true, status: 204 });
  await controls.saveAs.click();
  globalThis.fetch = prevFetch;
  assert.equal(downloaded, null, "save-as requires host-provided default filename");
  assert.equal(prompts.shown.length, 1);
}

{
  // Save As with no current file suggests the host default; the host copy is filed under it.
  const game = await loadGame();
  const session = { legend: { save_as: true }, state: { cells: [] }, default_save_filename: "host-default.sud" };
  const controls = { saveAs: makeBtn() };
  const fetchCalls = [];
  const prevFetch = globalThis.fetch;
  globalThis.fetch = async (url, init) => {
    fetchCalls.push({ url, init });
    return { ok: true, status: 204 };
  };
  wireFile(controls, game, session);
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
  wireFile(controls, game, session, {
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
  const difficultyDialog = easyDialog();
  const controls = { new: makeBtn() };
  const { difficulties } = wireFile(controls, game, session, { difficultyDialog });
  controls.new.click();
  assert.equal(difficultyDialog.el.hidden, false, "New opens the difficulty dialog");
  assert.equal(difficulties.length, 0, "no puzzle generated until a difficulty is picked");
  await difficultyDialog.buttons[1].el.click();
  assert.equal(difficultyDialog.el.hidden, true, "dialog closes after a pick");
  assert.deepEqual(difficulties, ["medium"], "the picked difficulty is generated");
  assert.equal(session.state.cells[0].value, 5, "board resets to the generated game");
}

{
  // A failed generation surfaces core's error; the board stays.
  const game = await loadGame();
  const session = { state: { cells: [] }, legend: { new: true } };
  const prompts = promptDialogStub();
  const difficultyDialog = easyDialog();
  wireFile({ new: makeBtn() }, game, session, { difficultyDialog, promptDialog: prompts, generated: [{ ok: false, error: "gen failed" }] });
  await difficultyDialog.buttons[0].el.click();
  assert.equal(prompts.shown.length, 1, "error modal shown");
  assert.equal(prompts.lastText, coreText.GENERATE_FAILED_MSG);
  assert.deepEqual(session.state.cells, []);
}

{
  // New drops the picked save handle; the file label follows the game core shows.
  const game = await loadGame();
  const session = { state: { cells: [] }, legend: { new: true }, fileHandle: { name: "bound.sud" }, boundFilename: "bound.sud" };
  const difficultyDialog = easyDialog();
  wireFile({ new: makeBtn() }, game, session, { difficultyDialog });
  await difficultyDialog.buttons[2].el.click();
  assert.equal(session.fileHandle, null, "save target unbound after New");
  assert.equal(session.boundFilename, null, "a new game has no file");
}

{
  const session = { state: { cells: [] }, legend: {} };
  const game = await loadGame();
  const newBtn = makeBtn();
  const difficultyDialog = easyDialog();
  const { difficulties } = wireFile({ new: newBtn }, game, session, { difficultyDialog });
  newBtn.click();
  assert.equal(difficultyDialog.el.hidden, true, "legend.new off → dialog stays closed");
  assert.equal(difficulties.length, 0, "legend.new off → no generation");
}

{
  assert.deepEqual(DIFFICULTY_BUTTONS.map((d) => d.difficulty), ["easy", "medium", "hard"]);
  let chosen = null;
  const dialog = {
    el: { hidden: true },
    buttons: DIFFICULTY_BUTTONS.map((d) => ({ ...d, el: makeBtn() })),
  };
  fileMenu.wireDifficultyDialog(dialog, (difficulty) => {
    chosen = difficulty;
  });
  await dialog.buttons[2].el.click();
  assert.equal(chosen, "hard");
  assert.equal(dialog.el.hidden, true);
}

{
  let chosen = null;
  const dialog = {
    el: { hidden: false },
    buttons: DIFFICULTY_BUTTONS.map((d) => ({ ...d, el: makeBtn() })),
    cancelBtn: makeBtn(),
  };
  fileMenu.wireDifficultyDialog(dialog, (difficulty) => {
    chosen = difficulty;
  });
  await dialog.cancelBtn.click();
  assert.equal(dialog.el.hidden, true);
  assert.equal(chosen, null);
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
  const prompts = promptDialogStub();
  const importBtn = makeBtn();
  wireFile({ import: importBtn }, game, session, {
    promptDialog: prompts,
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
  assert.equal(prompts.shown.length, 0, "no error modal on success");
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
  const prompts = promptDialogStub();
  const before = JSON.stringify(session.state);
  const importBtn = makeBtn();
  wireFile({ import: importBtn }, game, session, {
    promptDialog: prompts,
    pick: async () => ({ ok: true, name: "bad.txt", bytes: new TextEncoder().encode("oops") }),
  });
  await importBtn.click();
  assert.equal(prompts.shown.length, 1, "error modal opens on invalid import");
  assert.match(prompts.lastText, /81/);
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
  wireFile({ open: openBtn }, game, session, {
    pick: async () => ({ ok: true, name: "picked.sud", handle, bytes: source.toSaveFormat().bytes }),
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
  wireFile({ import: importBtn }, await loadGame(), session, {
    pick: async () => {
      picked = true;
      return { ok: true };
    },
  });
  await importBtn.click();
  assert.equal(picked, false, "no picker when legend.import is off");
}


// Export writes bytes from toPuzzle via the text save path; save target stays bound
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
    toPuzzle() {
      return { ok: true, bytes: lineBytes };
    },
  };
  const exportBtn = makeBtn();
  const statusEl = { textContent: "", className: "" };
  await withCoreFlow(game);
  wireFile({ export: exportBtn }, game, session, {
    statusEl,
    exportText: async (bytes, sessionArg, name) => {
      assert.equal(sessionArg, session);
      assert.equal(name, "puzzle.txt");
      saved = bytes;
      return { ok: true, filename: "puzzle.txt" };
    },
  });
  await exportBtn.click();
  assert.deepEqual([...saved], [...lineBytes], "save receives toPuzzle bytes");
  assert.equal(statusEl.textContent, fillText(coreText.EXPORTED_TO_FMT, "puzzle.txt"), "core owns the export status");
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
    toPuzzle() {
      return { ok: true, bytes: new TextEncoder().encode("x".repeat(81)) };
    },
  };
  const prompts = promptDialogStub();
  const before = JSON.stringify(session.state);
  const exportBtn = makeBtn();
  await withCoreFlow(game);
  wireFile({ export: exportBtn }, game, session, {
    promptDialog: prompts,
    exportText: async () => ({ ok: false, error: "export: write failed" }),
  });
  await exportBtn.click();
  assert.equal(prompts.shown.length, 1);
  assert.equal(prompts.lastText, coreText.EXPORT_FAILED_MSG);
  assert.equal(JSON.stringify(session.state), before);
  assert.equal(session.fileHandle.name, "game.sud");
}

// Export is a no-op when the legend does not offer it
{
  let called = false;
  const exportBtn = makeBtn();
  wireFile({ export: exportBtn }, { toPuzzle() { called = true; return { ok: true }; } }, { legend: {}, state: { cells: [] } }, {
    exportText: async () => { throw new Error("must not run"); },
  });
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
  const game = { toSaveFormat: () => ({ ok: true, bytes: new Uint8Array([4, 2]) }) };
  await withCoreFlow(game, { autoSave: true });
  const host = hostFetch();
  const fetchFn = async (url, init) => {
    if (url === "./current-file") hostWrites.push([...new Uint8Array(init.body)]);
    return host.fetchFn(url, init);
  };
  const { steps } = wireFile({}, game, session, {
    fetchFn,
    download() {
      downloads += 1;
    },
    pick: async () => {
      picks += 1;
      return { ok: false, cancelled: true };
    },
  });
  await moveWithAutosave(game, session, { steps });
  assert.equal(downloads, 0, "autosave must not download");
  assert.equal(picks, 0, "autosave must not open a picker");
  assert.deepEqual(hostWrites, [[4, 2]]);
}

// Save on a bound handle writes it again without a picker or a question; the host keeps the restore copy.
{
  const game = await loadGame();
  openAs(game, "bound.sud");
  const written = [];
  const fileHandle = {
    name: "bound.sud",
    async createWritable() {
      return { async write(bytes) { written.push([...bytes]); }, async close() {} };
    },
  };
  const session = { legend: { save: true }, state: { cells: [] }, fileHandle, boundFilename: "bound.sud" };
  const host = hostFetch();
  const statusEl = makeStatus();
  const controls = { save: makeBtn() };
  wireFile(controls, game, session, {
    statusEl,
    fetchFn: host.fetchFn,
    promptDialog: noPromptDialog("continuing the bound file must not ask"),
    pick: async () => assert.fail("no picker for a bound file"),
    download: () => assert.fail("no download for a bound file"),
  });
  await controls.save.click();
  assert.deepEqual(written, [[...game.toSaveFormat().bytes]]);
  assert.equal(postedCurrentFile(host.calls)?.init?.headers?.["X-Sudoku-Restore-Copy"], "true");
  assert.equal(statusEl.textContent, fillText(coreText.SAVED_TO_FMT, "bound.sud"));
}

console.log("file_menu.test.mjs OK");
