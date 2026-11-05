// step_runner.test.mjs — core save/autosave/startup/command flows driven through the web step runner (real wasm).

import assert from "node:assert/strict";
import * as stepRunner from "./step_runner.js";
import * as clientLog from "../client_log.js";
import { loadCoreFlow, loadGame, openAs, PUZZLE_LINE, startNewGame, coreText, fillText } from "../test_support.mjs";

/**
 * Record a prompt the way these tests read it: a one-button message as its type and text, a question as
 * `ask` with its title, text and buttons, answered with its default when `yes`, else by dismissing it.
 */
function recordPrompt(log, step, yes) {
  if (step.buttons.length === 1) {
    log.push([step.type, step.text]);
    return step.default;
  }
  log.push(["ask", step.title, step.text, step.buttons]);
  return yes ? step.default : step.dismiss;
}

/** Handlers that record every step and answer from the options; `exists` makes a write without `replace` find its file there. */
function recordingHandlers({ exists = false, yes = false, write = (name) => ({ ok: true, name }), defaultName = "sudoku.sud" } = {}) {
  const log = [];
  const writeStep = (step) => ({ name, replace }) => {
    log.push([step, name, replace]);
    if (exists && !replace) return { ok: false, exists: true };
    return write(name);
  };
  return {
    log,
    resolveDefaultTarget: () => {
      log.push(["default"]);
      return defaultName;
    },
    promptMessage: (step) => recordPrompt(log, step, yes),
    save: writeStep(stepRunner.STEP_SAVE),
    saveAs: writeStep(stepRunner.STEP_SAVE_AS),
    autosave: writeStep(stepRunner.STEP_AUTOSAVE),
    exportPuzzle: (name) => {
      log.push([stepRunner.STEP_EXPORT_PUZZLE, name]);
      return write(name);
    },
    showGame: () => {},
    showStatus: (text) => log.push(["status", text]),
  };
}

const FILL = { action: "fill", row: 0, col: 2, digit: 4 };
const SAVE = { action: "save" };
const SAVE_AS = { action: "save_as" };
const DEFAULT = ["default"];

/** Recording handlers whose default target is `game.sud`. */
const saveHandlers = (options = {}) => recordingHandlers({ defaultName: "game.sud", ...options });

const NOT_SAVED = coreText.WRITE_CANCELLED_MSG;
const REPLACE_BUTTONS = [coreText.REPLACE_CONFIRM_CANCEL_LABEL, coreText.REPLACE_CONFIRM_OK_LABEL];
const REPLACE_ASK = ["ask", coreText.REPLACE_CONFIRM_TITLE, fillText(coreText.REPLACE_CONFIRM_FMT, "game.sud"), REPLACE_BUTTONS];

// Save with no current file names the default target, writes and reports the core status text.
{
  const core = await loadCoreFlow();
  const handlers = saveHandlers({ exists: false });
  const outcome = await stepRunner.runCommand(core, SAVE, handlers);
  assert.deepEqual(handlers.log, [DEFAULT, ["save", "game.sud", false], ["status", fillText(coreText.SAVED_TO_FMT, "game.sud")]]);
  assert.deepEqual(outcome, { kind: "show_status", text: fillText(coreText.SAVED_TO_FMT, "game.sud") });
}

// Save after New onto a file already there asks once; declining writes nothing.
{
  const core = await loadCoreFlow();
  startNewGame(core);
  const handlers = saveHandlers({ exists: true, yes: false });
  const outcome = await stepRunner.runCommand(core, SAVE, handlers);
  assert.deepEqual(handlers.log, [DEFAULT, ["save", "game.sud", false], REPLACE_ASK, ["status", NOT_SAVED]]);
  assert.equal(outcome.kind, "show_status");
}

// Accepting the replace question writes with replace; the next Save continues the file without asking.
{
  const core = await loadCoreFlow();
  const accept = saveHandlers({ exists: true, yes: true });
  await stepRunner.runCommand(core, SAVE, accept);
  assert.deepEqual(accept.log, [DEFAULT, ["save", "game.sud", false], REPLACE_ASK, ["save", "game.sud", true], ["status", fillText(coreText.SAVED_TO_FMT, "game.sud")]]);
  const again = saveHandlers({ exists: true });
  await stepRunner.runCommand(core, SAVE, again);
  assert.deepEqual(again.log, [["save", "game.sud", false], ["save", "game.sud", true], ["status", fillText(coreText.SAVED_TO_FMT, "game.sud")]]);
}

// Save As suggests the opened file and asks before replacing it; after New it asks too.
{
  const core = await loadCoreFlow();
  openAs(core, "game.sud");
  const continuing = saveHandlers({ exists: true, yes: true });
  await stepRunner.runCommand(core, SAVE_AS, continuing);
  assert.deepEqual(continuing.log, [["save_as", "game.sud", false], REPLACE_ASK, ["save_as", "game.sud", true], ["status", fillText(coreText.SAVED_TO_FMT, "game.sud")]]);
  startNewGame(core);
  const detached = saveHandlers({ exists: true, yes: false });
  await stepRunner.runCommand(core, SAVE_AS, detached);
  assert.deepEqual(detached.log, [["save_as", "game.sud", false], REPLACE_ASK, ["status", NOT_SAVED]]);
}

// The name the platform actually wrote becomes the status and the current file.
{
  const core = await loadCoreFlow({ autoSave: true });
  const handlers = saveHandlers({ write: () => ({ ok: true, name: "picked.sud" }) });
  await stepRunner.runCommand(core, SAVE_AS, handlers);
  assert.deepEqual(handlers.log.at(-1), ["status", fillText(coreText.SAVED_TO_FMT, "picked.sud")]);
  const autosave = recordingHandlers({ exists: true });
  await stepRunner.runCommand(core, FILL, autosave);
  assert.deepEqual(autosave.log, [["autosave", "picked.sud", false], ["autosave", "picked.sud", true]], "autosave continues the saved file");
}

// Each command issues its own step, so the platform needs no knowledge of the command.
{
  const writes = (handlers) => handlers.log.filter(([step]) => step !== "default" && step !== "status").map(([step]) => step);
  const core = await loadCoreFlow({ autoSave: true });
  const saveAs = saveHandlers();
  await stepRunner.runCommand(core, SAVE_AS, saveAs);
  assert.deepEqual(writes(saveAs), [stepRunner.STEP_SAVE_AS]);
  const autosave = recordingHandlers();
  await stepRunner.runCommand(core, FILL, autosave);
  assert.deepEqual(writes(autosave), [stepRunner.STEP_AUTOSAVE]);
  const exported = recordingHandlers();
  await stepRunner.runCommand(core, { action: "export" }, exported);
  assert.deepEqual(writes(exported), [stepRunner.STEP_EXPORT_PUZZLE]);
  const core2 = await loadCoreFlow();
  const save = saveHandlers();
  await stepRunner.runCommand(core2, SAVE, save);
  assert.deepEqual(writes(save), [stepRunner.STEP_SAVE]);
}

// A manual Save while Auto Save is on writes nothing and says why; the legend offers no Save.
{
  const core = await loadCoreFlow({ autoSave: true });
  assert.equal(core.getLegend().save, false);
  const handlers = saveHandlers();
  const outcome = await stepRunner.runCommand(core, SAVE, handlers);
  assert.deepEqual(handlers.log, [["status", coreText.SAVE_WHILE_AUTO_SAVE_MSG]]);
  assert.equal(outcome.kind, "show_status");
}

// A picker the user closed ends quietly; a failed write shows core's sentence and only logs the thrown message.
{
  const core = await loadCoreFlow();
  const closed = saveHandlers({ write: () => ({ ok: false, cancelled: true }) });
  assert.deepEqual(await stepRunner.runCommand(core, SAVE, closed), { kind: "done" });
  const failed = saveHandlers({
    write: () => {
      throw new Error("disk full");
    },
  });
  const logged = [];
  const originalError = console.error;
  console.error = (line) => logged.push(line);
  clientLog.useCore(core);
  core.setLogListener(clientLog.coreLine);
  try {
    await stepRunner.runCommand(core, SAVE, failed);
  } finally {
    core.setLogListener(null);
    console.error = originalError;
  }
  assert.deepEqual(failed.log.at(-1), ["error", coreText.SAVE_FAILED_MSG]);
  assert.ok(logged.some((line) => String(line).includes("disk full")), "the thrown message is logged as an error");
}

// A move's first autosave with no current file resolves the default target, then asks when that file is there.
{
  const core = await loadCoreFlow({ autoSave: true });
  const handlers = recordingHandlers({ exists: true, yes: false });
  const outcome = await stepRunner.runCommand(core, FILL, handlers);
  assert.deepEqual(handlers.log, [
    ["default"],
    ["autosave", "sudoku.sud", false],
    ["ask", coreText.REPLACE_CONFIRM_TITLE, fillText(coreText.REPLACE_CONFIRM_FMT, "sudoku.sud"), REPLACE_BUTTONS],
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

// A handler that throws outside a write ends the flow with core's sentence, not the thrown message; the next flow still runs.
{
  const core = await loadCoreFlow();
  const broken = saveHandlers();
  broken.resolveDefaultTarget = () => {
    throw new Error("host unreachable");
  };
  assert.deepEqual(await stepRunner.runCommand(core, SAVE, broken), { kind: "done" });
  assert.deepEqual(broken.log.at(-1), ["error", coreText.UNEXPECTED_INPUT_MSG]);
  const next = saveHandlers();
  await stepRunner.runCommand(core, SAVE, next);
  assert.deepEqual(next.log.at(-1), ["status", fillText(coreText.SAVED_TO_FMT, "game.sud")]);
}

/** Handlers that answer every prompt with its default and keep its text in `texts`. */
function promptTexts() {
  const texts = [];
  return {
    texts,
    promptMessage: (step) => {
      texts.push(step.text);
      return step.default;
    },
  };
}

/** Startup handlers that record each step; `read` and `generated` script the platform results. */
function startupRecorder({ read, generated, yes = false } = {}) {
  const log = [];
  return {
    log,
    restore: (path) => {
      log.push(["read", path]);
      if (read instanceof Error) throw read;
      return read;
    },
    showGame: (step) => log.push(["show", step.text, step.file]),
    promptMessage: (step) => recordPrompt(log, step, yes),
    generateGame: (difficulty) => {
      log.push(["generate", difficulty]);
      return generated;
    },
    forgetCurrentFile: (forget) => log.push(["forget", forget.path, forget.delete]),
  };
}

const WELCOME = coreText.IDLE_STARTUP_STATUS;

// restore bytes go to core through flowRead; the restored game is shown with its file name.
{
  const source = await loadGame();
  startNewGame(source);
  const game = await loadGame({ auto_restore: true });
  const handlers = startupRecorder({ read: { ok: true, bytes: source.toSaveFormat().bytes } });
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
  assert.deepEqual(handlers.log.map((entry) => entry.slice(0, 2)), [
    ["read", "/current-file"],
    ["show", WELCOME],
    ["ask", "Restore failed"],
    ["forget", "/current-file"],
  ]);
  assert.equal(handlers.log[1][2], null);
  assert.equal(handlers.log[3][2], false);
}

// generate_game reports the line, cancellation, or failure to core.
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
  assert.equal(outcome.kind, "done");
  assert.deepEqual(failed.log.at(-1), ["error", coreText.GENERATE_FAILED_MSG]);
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
    promptMessage: (step) => {
      errors.push(step.text);
      return step.default;
    },
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
  assert.deepEqual(failed, { kind: "done" });

  const thrown = await stepRunner.runCommand(game, { action: "toggle_region" }, {
    ...handlers,
    persistSettings: () => {
      throw new Error("offline");
    },
  });
  assert.deepEqual(thrown, { kind: "done" });
  assert.deepEqual(errors, [coreText.PERSIST_FAILED_MSG, coreText.PERSIST_FAILED_MSG]);
  assert.equal(game.getConfig().show_region, false, "two toggles leave the setting where it started");
}

// A command core rejects ends with its error and shows nothing.
{
  const game = await loadGame();
  const shown = [];
  const prompts = promptTexts();
  const outcome = await stepRunner.runCommand(game, { action: "undo" }, { showGame: (step) => shown.push(step), ...prompts });
  assert.equal(outcome.kind, "done");
  assert.equal(prompts.texts.length, 1);
  assert.equal(shown.length, 0);
}

// open hands core the picked bytes and name; closing the picker clears the status; a failed pick is core's error, then clears it.
{
  const source = await loadGame();
  startNewGame(source);
  const bytes = source.toSaveFormat().bytes;
  const game = await loadGame();
  const shown = [];
  const picks = [];
  const prompts = promptTexts();
  const handlers = (pick) => ({ open: pick, importPuzzle: pick, showGame: (step) => shown.push(step), ...prompts });

  const opened = await stepRunner.runCommand(game, { action: "open" }, handlers((path) => {
    picks.push(path);
    return { ok: true, bytes, name: "game.sud" };
  }));
  assert.deepEqual(opened, { kind: "done" });
  assert.deepEqual(picks, [null]);
  assert.equal(shown[0].loaded, true);
  assert.equal(shown[0].file, "game.sud");
  assert.equal(shown[0].text, fillText(coreText.OPENED_FMT, "game.sud"));

  const loadEnded = { kind: stepRunner.STEP_SHOW_STATUS, text: coreText.LOAD_ENDED_STATUS };
  assert.deepEqual(await stepRunner.runCommand(game, { action: "import" }, handlers(() => ({ ok: false, cancelled: true }))), loadEnded);
  const failed = await stepRunner.runCommand(game, { action: "import" }, handlers(() => ({ ok: false, error: "unreadable" })));
  assert.deepEqual(failed, loadEnded);
  assert.deepEqual(prompts.texts, [coreText.IMPORT_FAILED_MSG]);
  assert.equal(shown.length, 1, "a cancelled or failed pick shows nothing");
}

// paste_puzzle hands core the clipboard text; a denied read is core's error and keeps the board.
{
  const game = await loadGame();
  const shown = [];
  const pasted = await stepRunner.runCommand(game, { action: "paste" }, {
    pastePuzzle: () => ({ ok: true, bytes: new TextEncoder().encode(PUZZLE_LINE) }),
    showGame: (step) => shown.push(step),
  });
  assert.deepEqual(pasted, { kind: "done" });
  assert.equal(shown[0].text, coreText.PASTED_MSG);
  const before = game.getState();
  const prompts = promptTexts();
  const denied = await stepRunner.runCommand(game, { action: "paste" }, { pastePuzzle: () => ({ ok: false, error: "denied" }), ...prompts });
  assert.deepEqual(denied, { kind: stepRunner.STEP_SHOW_STATUS, text: coreText.LOAD_ENDED_STATUS });
  assert.deepEqual(prompts.texts, [coreText.PASTE_FAILED_MSG]);
  assert.deepEqual(game.getState(), before);
}

// Paste and Import hand core the text untrimmed: every blank marker reads, surrounding whitespace is a wrong length.
{
  const game = await loadGame();
  const markers = "0.X*_ ";
  const blanks = Array.from({ length: 81 }, (_, i) => markers[i % markers.length]);
  blanks[0] = " ";
  blanks[80] = " ";
  blanks[7] = "5";
  const bytes = new TextEncoder().encode(blanks.join(""));
  const shown = [];
  for (const action of ["paste", "import"]) {
    const outcome = await stepRunner.runCommand(game, { action }, {
      pastePuzzle: () => ({ ok: true, bytes }),
      importPuzzle: () => ({ ok: true, bytes }),
      showGame: (step) => shown.push(step),
    });
    assert.deepEqual(outcome, { kind: "done" }, `${action} accepts every blank marker`);
  }
  assert.equal(game.getState().cells[7].value, 5);

  const padded = new TextEncoder().encode(`${PUZZLE_LINE}\n`);
  const prompts = promptTexts();
  const rejected = await stepRunner.runCommand(game, { action: "paste" }, { pastePuzzle: () => ({ ok: true, bytes: padded }), ...prompts });
  assert.deepEqual(rejected, { kind: stepRunner.STEP_SHOW_STATUS, text: coreText.LOAD_ENDED_STATUS });
  assert.deepEqual(prompts.texts, [coreText.PUZZLE_LENGTH_MSG]);
}

console.log("step_runner.test.mjs OK");
