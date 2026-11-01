// step_runner.test.mjs — core save/autosave/startup/command flows driven through the web step runner (real wasm).

import assert from "node:assert/strict";
import * as stepRunner from "./step_runner.js";
import { loadCoreFlow, loadGame, openAs, PUZZLE_LINE, startNewGame } from "../test_support.mjs";

/** Handlers that record every step and answer from `answers`. */
function recordingHandlers({ exists = false, yes = false, write = (name) => ({ ok: true, name }), defaultName = "sudoku.sud" } = {}) {
  const log = [];
  return {
    log,
    resolveDefaultTarget: () => {
      log.push(["default"]);
      return defaultName;
    },
    checkTarget: (name) => {
      log.push(["check", name]);
      return exists;
    },
    ask: (step) => {
      log.push(["ask", step.title, step.text, step.ok_label, step.cancel_label]);
      return yes;
    },
    write: (name) => {
      log.push(["write", name]);
      return write(name);
    },
    showGame: () => {},
    showStatus: (text) => log.push(["status", text]),
    showError: (text) => log.push(["error", text]),
  };
}

const FILL = { action: "fill", row: 0, col: 2, digit: 4 };
const SAVE = { action: "save" };
const SAVE_AS = { action: "save_as" };
const DEFAULT = ["default"];

/** Recording handlers whose default target is `game.sud`. */
const saveHandlers = (options = {}) => recordingHandlers({ defaultName: "game.sud", ...options });

const REPLACE_ASK = ["ask", "Replace file?", "The file game.sud already exists. Do you want to replace it?", "Replace", "Cancel"];

// Save with no working file names the default target, writes and reports the core status text.
{
  const core = await loadCoreFlow();
  const handlers = saveHandlers({ exists: false });
  const outcome = await stepRunner.runCommand(core, SAVE, handlers);
  assert.deepEqual(handlers.log, [DEFAULT, ["check", "game.sud"], ["write", "game.sud"], ["status", "saved to: game.sud"]]);
  assert.deepEqual(outcome, { kind: "show_status", text: "saved to: game.sud" });
}

// Save after New onto an existing file asks once; declining writes nothing.
{
  const core = await loadCoreFlow();
  startNewGame(core);
  const handlers = saveHandlers({ exists: true, yes: false });
  const outcome = await stepRunner.runCommand(core, SAVE, handlers);
  assert.deepEqual(handlers.log, [DEFAULT, ["check", "game.sud"], REPLACE_ASK, ["status", "cancelled"]]);
  assert.equal(outcome.kind, "show_status");
}

// Accepting the replace question writes; the next Save continues the file without asking.
{
  const core = await loadCoreFlow();
  const accept = saveHandlers({ exists: true, yes: true });
  await stepRunner.runCommand(core, SAVE, accept);
  assert.deepEqual(accept.log, [DEFAULT, ["check", "game.sud"], REPLACE_ASK, ["write", "game.sud"], ["status", "saved to: game.sud"]]);
  const again = saveHandlers({ exists: true });
  await stepRunner.runCommand(core, SAVE, again);
  assert.deepEqual(again.log, [["check", "game.sud"], ["write", "game.sud"], ["status", "saved to: game.sud"]]);
}

// Save As suggests the opened file and continues it; after New the same Save As asks.
{
  const core = await loadCoreFlow();
  openAs(core, "game.sud");
  const continuing = saveHandlers({ exists: true });
  await stepRunner.runCommand(core, SAVE_AS, continuing);
  assert.deepEqual(continuing.log, [["check", "game.sud"], ["write", "game.sud"], ["status", "saved to: game.sud"]]);
  startNewGame(core);
  const detached = saveHandlers({ exists: true, yes: false });
  await stepRunner.runCommand(core, SAVE_AS, detached);
  assert.deepEqual(detached.log, [["check", "game.sud"], REPLACE_ASK, ["status", "cancelled"]]);
}

// The name the platform actually wrote becomes the status and the working file.
{
  const core = await loadCoreFlow({ autoSave: true });
  const handlers = saveHandlers({ write: () => ({ ok: true, name: "picked.sud" }) });
  await stepRunner.runCommand(core, SAVE_AS, handlers);
  assert.deepEqual(handlers.log.at(-1), ["status", "saved to: picked.sud"]);
  const autosave = recordingHandlers({ exists: true });
  await stepRunner.runCommand(core, FILL, autosave);
  assert.deepEqual(autosave.log, [["check", "picked.sud"], ["write", "picked.sud"]], "autosave continues the saved file");
}

// A manual Save while Auto Save is on writes nothing and says why; the legend offers no Save.
{
  const core = await loadCoreFlow({ autoSave: true });
  assert.equal(core.getLegend().save, false);
  const handlers = saveHandlers();
  const outcome = await stepRunner.runCommand(core, SAVE, handlers);
  assert.deepEqual(handlers.log, [["status", "Auto Save is on, so your game is already saved."]]);
  assert.equal(outcome.kind, "show_status");
}

// A picker the user closed ends quietly; a failed write shows the error.
{
  const core = await loadCoreFlow();
  const closed = saveHandlers({ write: () => ({ ok: false, cancelled: true }) });
  assert.deepEqual(await stepRunner.runCommand(core, SAVE, closed), { kind: "done" });
  const failed = saveHandlers({
    write: () => {
      throw new Error("disk full");
    },
  });
  await stepRunner.runCommand(core, SAVE, failed);
  assert.deepEqual(failed.log.at(-1), ["error", "disk full"]);
}

// A move's first autosave with no working file resolves the default target, then asks if it exists.
{
  const core = await loadCoreFlow({ autoSave: true });
  const handlers = recordingHandlers({ exists: true, yes: false });
  const outcome = await stepRunner.runCommand(core, FILL, handlers);
  assert.deepEqual(handlers.log, [
    ["default"],
    ["check", "sudoku.sud"],
    ["ask", "Replace file?", "The file sudoku.sud already exists. Do you want to replace it?", "Replace", "Cancel"],
  ]);
  assert.deepEqual(outcome, { kind: "done" }, "declined autosave ends without a status");
}

// Autosave off: after showing the move core ends the command before any platform work.
{
  const core = await loadCoreFlow({ autoSave: false });
  const handlers = recordingHandlers();
  assert.deepEqual(await stepRunner.runCommand(core, FILL, handlers), { kind: "done" });
  assert.deepEqual(handlers.log, []);
}

// A handler that throws outside write ends the flow with its message; the next flow still runs.
{
  const core = await loadCoreFlow();
  const broken = saveHandlers();
  broken.checkTarget = () => {
    throw new Error("host unreachable");
  };
  assert.deepEqual(await stepRunner.runCommand(core, SAVE, broken), { kind: "show_error", text: "host unreachable" });
  const next = saveHandlers();
  await stepRunner.runCommand(core, SAVE, next);
  assert.deepEqual(next.log.at(-1), ["status", "saved to: game.sud"]);
}

// The web dialog gets the core title, text and button labels.
{
  const seen = [];
  const win = {
    __sudokuChoose: async (text, labels) => {
      seen.push({ text, labels });
      return true;
    },
  };
  const yes = await stepRunner.askWithDialog({ step: "ask", title: "T", text: "Q?", ok_label: "Yes", cancel_label: "No" }, win);
  assert.equal(yes, true);
  assert.deepEqual(seen, [{ text: "Q?", labels: { title: "T", okLabel: "Yes", cancelLabel: "No" } }]);
  assert.equal(await stepRunner.askWithDialog({ step: "ask", text: "Q?" }, {}), false, "no dialog means no");
}

/** Startup handlers that record each step; `read` and `generated` script the platform results. */
function startupRecorder({ read, generated, yes = false } = {}) {
  const log = [];
  return {
    log,
    readFile: (path) => {
      log.push(["read", path]);
      if (read instanceof Error) throw read;
      return read;
    },
    showGame: (step) => log.push(["show", step.text, step.file]),
    ask: (step) => {
      log.push(["ask", step.title]);
      return yes;
    },
    generate: (difficulty) => {
      log.push(["generate", difficulty]);
      return generated;
    },
    forgetCurrentFile: (forget) => log.push(["forget", forget.path, forget.delete]),
    showError: (text) => log.push(["error", text]),
  };
}

const WELCOME = "Welcome to sudoku-zig! Choose New or Open to play";

// read_file bytes go to core through flowFileRead; the restored game is shown with its file name.
{
  const source = await loadGame();
  startNewGame(source);
  const game = await loadGame({ auto_restore: true });
  const handlers = startupRecorder({ read: { ok: true, bytes: source.serialize().bytes } });
  const outcome = await stepRunner.runFlow(game, { flow: stepRunner.FLOW_STARTUP, path: "/current-file", name: "game.sud" }, handlers);
  assert.equal(outcome.kind, "done");
  assert.deepEqual(handlers.log[0], ["read", "/current-file"]);
  assert.equal(handlers.log[1][0], "show");
  assert.equal(handlers.log[1][2], "game.sud");
}

// A throwing reader is a failed read: idle board, delete question, forget without deleting.
{
  const game = await loadGame({ auto_restore: true });
  const handlers = startupRecorder({ read: new Error("network down") });
  await stepRunner.runFlow(game, { flow: stepRunner.FLOW_STARTUP, path: "/current-file", name: "game.sud" }, handlers);
  assert.deepEqual(handlers.log, [
    ["read", "/current-file"],
    ["show", WELCOME, null],
    ["ask", "Restore failed"],
    ["forget", "/current-file", false],
  ]);
}

// generate reports the line, cancellation, or failure to core.
{
  const line = "530070000600195000098000060800060003400803001700020006060000280000419005000080079";
  const ok = startupRecorder({ generated: { ok: true, line } });
  assert.equal((await stepRunner.runFlow(await loadGame({ auto_new: true, difficulty: 2 }), { flow: stepRunner.FLOW_STARTUP }, ok)).kind, "done");
  assert.deepEqual(ok.log[0], ["generate", 2]);
  assert.notEqual(ok.log[1][1], WELCOME);

  const cancelled = startupRecorder({ generated: { ok: false, cancelled: true } });
  await stepRunner.runFlow(await loadGame({ auto_new: true }), { flow: stepRunner.FLOW_STARTUP }, cancelled);
  assert.deepEqual(cancelled.log, [["generate", 1], ["show", WELCOME, null]]);

  const failed = startupRecorder({ generated: { ok: false } });
  const outcome = await stepRunner.runFlow(await loadGame({ auto_new: true }), { flow: stepRunner.FLOW_STARTUP }, failed);
  assert.equal(outcome.kind, "show_error");
  assert.deepEqual(failed.log.at(-1), ["error", "A new game could not be generated (generation failed)."]);
}

// A command runs end to end in core: show_game carries what the adapter draws, then
// persist_settings hands core's settings over; failures and throws come back as core's sentence.
{
  const game = await loadGame({ theme: "dark" });
  const shown = [];
  const persisted = [];
  const errors = [];
  const handlers = {
    showGame: (step) => shown.push(step),
    persistSettings: (settings) => {
      persisted.push(settings.theme);
      return { ok: true };
    },
    showError: (text) => errors.push(text),
  };
  assert.deepEqual(await stepRunner.runCommand(game, { action: "set_theme", theme: "light" }, handlers), { kind: "done" });
  assert.equal(shown[0].config.theme, "light");
  assert.equal(shown[0].legend.fill, true);
  assert.equal(shown[0].state.cells.length, 81);
  assert.deepEqual(persisted, ["light"]);

  const failed = await stepRunner.runCommand(game, { action: "toggle_region" }, {
    ...handlers,
    persistSettings: () => ({ ok: false }),
  });
  assert.deepEqual(failed, { kind: "show_error", text: "Your settings could not be saved (settings write failed)." });

  const thrown = await stepRunner.runCommand(game, { action: "toggle_region" }, {
    ...handlers,
    persistSettings: () => {
      throw new Error("offline");
    },
  });
  assert.equal(thrown.text, "Your settings could not be saved (offline).");
  assert.equal(errors.length, 2);
  assert.equal(game.getConfig().show_region, false, "two toggles leave the setting where it started");
}

// A command core rejects ends with its error and shows nothing.
{
  const game = await loadGame();
  const shown = [];
  const outcome = await stepRunner.runCommand(game, { action: "undo" }, { showGame: (step) => shown.push(step), showError() {} });
  assert.equal(outcome.kind, "show_error");
  assert.equal(shown.length, 0);
}

// pick_open hands core the picked bytes and name; closing the picker ends quietly; a failed pick is core's error.
{
  const source = await loadGame();
  startNewGame(source);
  const bytes = source.serialize().bytes;
  const game = await loadGame();
  const shown = [];
  const picks = [];
  const handlers = (pickOpen) => ({ pickOpen, showGame: (step) => shown.push(step), showError() {} });

  const opened = await stepRunner.runCommand(game, { action: "open" }, handlers((step) => {
    picks.push([step.kind, step.path]);
    return { ok: true, bytes, name: "game.sud" };
  }));
  assert.deepEqual(opened, { kind: "done" });
  assert.deepEqual(picks, [["game", null]]);
  assert.equal(shown[0].loaded, true);
  assert.equal(shown[0].file, "game.sud");
  assert.equal(shown[0].text, "opened: game.sud");

  assert.deepEqual(await stepRunner.runCommand(game, { action: "import" }, handlers(() => ({ ok: false, cancelled: true }))), { kind: "done" });
  const failed = await stepRunner.runCommand(game, { action: "import" }, handlers(() => ({ ok: false, error: "unreadable" })));
  assert.deepEqual(failed, { kind: "show_error", text: "unreadable" });
  assert.equal(shown.length, 1, "a cancelled or failed pick shows nothing");
}

// read_clipboard hands core the text; a denied read is core's error and keeps the board.
{
  const game = await loadGame();
  const shown = [];
  const pasted = await stepRunner.runCommand(game, { action: "paste" }, {
    readClipboard: () => ({ ok: true, text: PUZZLE_LINE }),
    showGame: (step) => shown.push(step),
  });
  assert.deepEqual(pasted, { kind: "done" });
  assert.equal(shown[0].text, "paste: puzzle loaded");
  const before = game.getState();
  const denied = await stepRunner.runCommand(game, { action: "paste" }, { readClipboard: () => ({ ok: false, error: "denied" }), showError() {} });
  assert.deepEqual(denied, { kind: "show_error", text: "denied" });
  assert.deepEqual(game.getState(), before);
}

console.log("step_runner.test.mjs OK");
