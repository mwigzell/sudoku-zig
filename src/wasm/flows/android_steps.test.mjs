// android_steps.test.mjs — the Android step handlers over a fake file bridge, driven by core flows.

import assert from "node:assert/strict";
import * as androidSteps from "./android_steps.js";
import * as stepRunner from "./step_runner.js";
import { errorModalStub, moveWithAutosave, withCoreFlow } from "../test_support.mjs";

const okFetch = async () => ({ ok: true, status: 204 });

/** Autosave session with nothing written yet, over a fake game whose saved bytes are [4, 2]. */
async function autosaveGame() {
  const game = await withCoreFlow({ serialize: () => ({ ok: true, bytes: new Uint8Array([4, 2]) }) }, { autoSave: true });
  const session = { legend: {}, state: { cells: [] }, config: { auto_save: true }, default_save_filename: "sudoku.sud" };
  return { game, session };
}

{
  // Nothing bound: autosave hands the bytes to the bridge's default file, then keeps the host restore copy.
  const { game, session } = await autosaveGame();
  const bridgeWrites = [];
  const hostNames = [];
  const bridge = {
    saveCurrentSudokuFile(base64, suggestedName) {
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
  const prevChoose = globalThis.__sudokuChoose;
  globalThis.__sudokuChoose = async () => true;
  const bridge = {
    saveCurrentSudokuFile(_b64, suggestedName) {
      bridgeWrites.push(suggestedName);
      return { ok: true, name: "bound.sud" };
    },
    currentSudokuFileName: () => "bound.sud",
  };
  try {
    await moveWithAutosave(game, session, { steps: androidSteps.androidSteps(game, session, bridge, { fetchFn: okFetch }) });
  } finally {
    globalThis.__sudokuChoose = prevChoose;
  }
  assert.equal(bridgeWrites.length, 1, "one bridge write, after core allows replacing");
}

{
  // Autosave adopts the file name the bridge actually wrote.
  const { game, session } = await autosaveGame();
  const hostNames = [];
  const bridge = { saveCurrentSudokuFile: () => ({ ok: true, name: "game2.sud" }), currentSudokuFileName: () => "" };
  const fetchFn = async (url, init) => {
    if (url === "./current-file") hostNames.push(init.headers["X-Sudoku-Filename"]);
    return { ok: true, status: 204 };
  };
  await moveWithAutosave(game, session, { steps: androidSteps.androidSteps(game, session, bridge, { fetchFn }) });
  assert.equal(session.boundFilename, "game2.sud");
  assert.deepEqual(hostNames, ["game2.sud"]);
}

{
  // Default file taken by an earlier install: core asks pick-or-rename; New name is save_as, Pick it is reclaim_file.
  const { game, session } = await autosaveGame();
  const prevChoose = globalThis.__sudokuChoose;
  const calls = [];
  const answers = [false, true];
  globalThis.__sudokuChoose = async (message, labels) => {
    calls.push(["ask", labels.okLabel, labels.cancelLabel]);
    assert.equal(labels.title, "Autosave file");
    assert.match(message, /sudoku\.sud in Download\/Sudoku/);
    return answers.shift();
  };
  const bridge = {
    saveCurrentSudokuFile: () => {
      calls.push(["autosave"]);
      return { ok: false, reason: "default_taken", name: "sudoku.sud", dir: "Download/Sudoku" };
    },
    saveSudokuFile: (_b64, name, saveAs) => {
      calls.push(["save_as", name, saveAs]);
      return { ok: false, cancelled: true };
    },
    saveSudokuFileToExisting: () => {
      calls.push(["reclaim_file"]);
      return { ok: true, name: "sudoku.sud" };
    },
    currentSudokuFileName: () => "",
  };
  const errorModal = errorModalStub();
  try {
    await moveWithAutosave(game, session, { steps: androidSteps.androidSteps(game, session, bridge, { fetchFn: okFetch, errorModal }) });
  } finally {
    globalThis.__sudokuChoose = prevChoose;
  }
  assert.deepEqual(calls, [
    ["autosave"],
    ["ask", "Pick it", "New name"],
    ["save_as", "sudoku.sud", true],
    ["ask", "Pick it", "New name"],
    ["reclaim_file"],
  ]);
  assert.equal(errorModal.el.hidden, true);
  assert.equal(session.boundFilename, "sudoku.sud");
}

{
  // Save writes the bound file through the bridge; Save As always asks the bridge for a new file.
  const game = await withCoreFlow({ serialize: () => ({ ok: true, bytes: new Uint8Array([1]) }) }, { opened: "bound.sud" });
  const session = { legend: { save: true, save_as: true }, state: { cells: [] }, default_save_filename: "sudoku.sud" };
  const saves = [];
  const bridge = {
    saveSudokuFile: (_b64, name, saveAs) => {
      saves.push([name, saveAs]);
      return saveAs ? { ok: false, cancelled: true } : { ok: true, name };
    },
    currentSudokuFileName: () => "bound.sud",
  };
  const steps = androidSteps.androidSteps(game, session, bridge, { fetchFn: okFetch });
  assert.equal((await stepRunner.runCommand(game, { action: "save" }, steps)).kind, "show_status");
  assert.deepEqual(await stepRunner.runCommand(game, { action: "save_as" }, steps), { kind: "done" }, "a closed picker ends quietly");
  assert.deepEqual(saves, [["bound.sud", false], ["bound.sud", true]]);
}

{
  // Open and Import read through the bridge's picker; closing it is a cancel.
  const bytes = new Uint8Array([2, 4, 6, 8]);
  const answers = [{ ok: true, name: "bridge.sud", base64: Buffer.from(bytes).toString("base64") }, { ok: false, cancelled: true }];
  const bridge = { openSudokuFile: async () => answers.shift() };
  const steps = androidSteps.androidSteps({}, {}, bridge);
  const picked = await steps.open(null);
  assert.equal(picked.ok, true);
  assert.equal(picked.name, "bridge.sud");
  assert.deepEqual([...picked.bytes], [...bytes]);
  assert.deepEqual(await steps.importPuzzle(null), { ok: false, cancelled: true });
}

console.log("android_steps.test.mjs OK");
