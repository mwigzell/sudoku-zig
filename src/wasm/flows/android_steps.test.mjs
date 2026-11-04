// android_steps.test.mjs — the Android step handlers over a fake file bridge, driven by core flows.

import assert from "node:assert/strict";
import * as androidSteps from "./android_steps.js";
import * as autosave from "./autosave.js";
import * as stepRunner from "./step_runner.js";
import { coreText, promptDialogStub, fillText, moveWithAutosave, settleFlow, withCoreFlow } from "../test_support.mjs";

const okFetch = async () => ({ ok: true, status: 204 });

/** Autosave session with nothing written yet, over a fake game whose saved bytes are [4, 2]. */
async function autosaveGame() {
  const game = await withCoreFlow({ toSaveFormat: () => ({ ok: true, bytes: new Uint8Array([4, 2]) }) }, { autoSave: true });
  const session = { legend: {}, state: { cells: [] }, config: { auto_save: true }, default_save_filename: "sudoku.sud" };
  return { game, session };
}

{
  // Nothing bound: autosave hands the bytes to the bridge's default file, then keeps the host restore copy.
  const { game, session } = await autosaveGame();
  const bridgeWrites = [];
  const hostNames = [];
  const bridge = {
    autosave(base64, suggestedName) {
      bridgeWrites.push([base64, suggestedName]);
      return { ok: true, name: suggestedName };
    },
    currentSudokuFileName: () => "",
  };
  const fetchFn = async (url, init) => {
    if (url === "./current-file") hostNames.push([init.headers["X-Sudoku-Filename"], init.headers["X-Sudoku-Restore-Copy"]]);
    return { ok: true, status: 204 };
  };
  await moveWithAutosave(game, session, { steps: androidSteps.androidSteps(game, session, bridge, { fetchFn }) });
  assert.deepEqual(bridgeWrites, [[Buffer.from([4, 2]).toString("base64"), "sudoku.sud"]]);
  assert.deepEqual(hostNames, [["sudoku.sud", "true"]]);
}

{
  // A bound file is there: core's replace policy decides, and the replace write still goes through the bridge.
  const { game, session } = await autosaveGame();
  const bridgeWrites = [];
  const bridge = {
    autosave(_b64, suggestedName) {
      bridgeWrites.push(suggestedName);
      return { ok: true, name: "bound.sud" };
    },
    currentSudokuFileName: () => "bound.sud",
  };
  const replace = promptDialogStub((step) => step.default);
  await moveWithAutosave(game, session, { steps: androidSteps.androidSteps(game, session, bridge, { fetchFn: okFetch, promptDialog: replace }) });
  assert.equal(bridgeWrites.length, 1, "one bridge write, after core allows replacing");
}

{
  // Autosave adopts the file name the bridge actually wrote.
  const { game, session } = await autosaveGame();
  const hostNames = [];
  const bridge = { autosave: () => ({ ok: true, name: "game2.sud" }), currentSudokuFileName: () => "" };
  const fetchFn = async (url, init) => {
    if (url === "./current-file") hostNames.push(init.headers["X-Sudoku-Filename"]);
    return { ok: true, status: 204 };
  };
  await moveWithAutosave(game, session, { steps: androidSteps.androidSteps(game, session, bridge, { fetchFn }) });
  assert.equal(session.boundFilename, "game2.sud");
  assert.deepEqual(hostNames, ["game2.sud"]);
}

for (const bound of ["", "sudoku.sud"]) {
  // A file this install may not write, whether the default file or the bound one: core asks choose-or-rename;
  // New name is save_as, Choose file is reclaim_file.
  const { game, session } = await autosaveGame();
  const calls = [];
  const answers = [false, true];
  const prompts = promptDialogStub((step) => {
    if (step.title === coreText.REPLACE_CONFIRM_TITLE) return step.default;
    calls.push(["ask", step.type, step.title, step.text, step.buttons]);
    return answers.shift() ? step.default : step.dismiss;
  });
  const bridge = {
    autosave: () => {
      calls.push(["autosave"]);
      return { ok: false, reason: "taken", name: "sudoku.sud" };
    },
    saveAs: (_b64, name) => {
      calls.push(["save_as", name]);
      return { ok: false, cancelled: true };
    },
    reclaimFile: () => {
      calls.push(["reclaim_file"]);
      return { ok: true, name: "sudoku.sud" };
    },
    currentSudokuFileName: () => bound,
  };
  await moveWithAutosave(game, session, { steps: androidSteps.androidSteps(game, session, bridge, { fetchFn: okFetch, promptDialog: prompts }) });
  const ask = ["ask", "error", coreText.TAKEN_TITLE, fillText(coreText.TAKEN_FMT, "sudoku.sud"), [coreText.TAKEN_NEW_NAME_LABEL, coreText.TAKEN_PICK_LABEL]];
  assert.deepEqual(calls, [["autosave"], ask, ["save_as", "sudoku.sud"], ask, ["reclaim_file"]], `bound: "${bound}"`);
  assert.ok(prompts.shown.every((step) => step.buttons.length > 1), "no error shown");
  assert.equal(session.boundFilename, "sudoku.sud");
}

{
  // Save writes the bound file through the bridge; Save As always asks the bridge for a new file.
  const game = await withCoreFlow({ toSaveFormat: () => ({ ok: true, bytes: new Uint8Array([1]) }) }, { opened: "bound.sud" });
  const session = { legend: { save: true, save_as: true }, state: { cells: [] }, default_save_filename: "sudoku.sud" };
  const saves = [];
  const bridge = {
    save: (_b64, name) => {
      saves.push(["save", name]);
      return { ok: true, name };
    },
    saveAs: (_b64, name) => {
      saves.push(["save_as", name]);
      return { ok: false, cancelled: true };
    },
    currentSudokuFileName: () => "bound.sud",
  };
  const steps = androidSteps.androidSteps(game, session, bridge, { fetchFn: okFetch });
  assert.equal((await stepRunner.runCommand(game, { action: "save" }, steps)).kind, "show_status");
  assert.deepEqual(await stepRunner.runCommand(game, { action: "save_as" }, steps), { kind: "done" }, "a closed picker ends quietly");
  assert.deepEqual(saves, [["save", "bound.sud"], ["save_as", "bound.sud"]]);
}

{
  // Open reads through the bridge's saved-game picker; closing it is a cancel.
  const bytes = new Uint8Array([2, 4, 6, 8]);
  const answers = [{ ok: true, name: "bridge.sud", base64: Buffer.from(bytes).toString("base64") }, { ok: false, cancelled: true }];
  const bridge = { open: async () => answers.shift() };
  const steps = androidSteps.androidSteps({}, {}, bridge);
  const picked = await steps.open(null);
  assert.equal(picked.ok, true);
  assert.equal(picked.name, "bridge.sud");
  assert.deepEqual([...picked.bytes], [...bytes]);
  assert.deepEqual(await steps.open(null), { ok: false, cancelled: true });
}

{
  // Import reads through the bridge's puzzle picker; Export hands the puzzle to the bridge under core's name.
  const puzzle = "puzzle line 1";
  const exported = [];
  const bridge = {
    importPuzzle: () => ({ ok: true, name: "picked.txt", base64: Buffer.from(puzzle).toString("base64") }),
    exportPuzzle: (b64, name) => {
      exported.push([Buffer.from(b64, "base64").toString(), name]);
      return { ok: true, name: "written.txt" };
    },
    open: () => assert.fail("Import must not use the saved-game picker"),
  };
  const game = { toPuzzle: () => ({ ok: true, bytes: new TextEncoder().encode(puzzle) }) };
  const steps = androidSteps.androidSteps(game, {}, bridge, { exportText: () => assert.fail("Export must not use the browser picker") });
  const picked = await steps.importPuzzle(null);
  assert.equal(new TextDecoder().decode(picked.bytes), puzzle);
  assert.equal(picked.name, "picked.txt");
  assert.deepEqual(await steps.exportPuzzle("sudoku.txt"), { ok: true, name: "written.txt" });
  assert.deepEqual(exported, [[puzzle, "sudoku.txt"]]);
}

{
  // Each app close the Android entry reports flushes the host restore copy only, kept alive past the page.
  const game = await withCoreFlow({ toSaveFormat: () => ({ ok: true, bytes: new Uint8Array([3]) }) }, { autoSave: true, opened: "bound.sud" });
  const session = { config: { auto_save: true }, boundFilename: "bound.sud", default_save_filename: "sudoku.sud" };
  const flushes = [];
  const fetchFn = async (url, init) => {
    if (url === "./current-file") flushes.push([init.headers["X-Sudoku-Filename"], init.headers["X-Sudoku-Restore-Copy"], init.keepalive]);
    return { ok: true, status: 204 };
  };
  const win = { addEventListener() {} };
  autosave.wireFlushOnClose(game, androidSteps.androidSteps(game, session, {}, { fetchFn }), { win });
  win[autosave.FLUSH_ON_CLOSE_HOOK]();
  await settleFlow();
  win[autosave.FLUSH_ON_CLOSE_HOOK]();
  await settleFlow();
  assert.deepEqual(flushes, [
    ["bound.sud", "true", true],
    ["bound.sud", "true", true],
  ]);
}

console.log("android_steps.test.mjs OK");
