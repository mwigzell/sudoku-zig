// step_runner.test.mjs — core save/autosave flows driven through the web step runner (real wasm).

import assert from "node:assert/strict";
import { askWithDialog, FLOW_AUTOSAVE, FLOW_SAVE, FLOW_SAVE_AS, runFlow } from "./step_runner.js";
import { WRITE_CONTEXT_EVENT_NEW_GAME_SUCCESS, WRITE_CONTEXT_EVENT_OPEN_SUCCESS } from "./shell.js";
import { loadCoreFlow } from "./test_support.mjs";

/** Handlers that record every step and answer from `answers`. */
function recordingHandlers({ exists = false, yes = false, write = (name) => ({ ok: true, name }) } = {}) {
  const log = [];
  return {
    log,
    resolveDefaultTarget: () => {
      log.push(["default"]);
      return "sudoku.sud";
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
    showStatus: (text) => log.push(["status", text]),
    showError: (text) => log.push(["error", text]),
  };
}

const REPLACE_ASK = ["ask", "Replace file?", "game.sud already exists. Do you want to replace it?", "Replace", "Cancel"];

// Save onto a new name writes and reports the core status text.
{
  const core = await loadCoreFlow();
  const handlers = recordingHandlers({ exists: false });
  const outcome = await runFlow(core, { flow: FLOW_SAVE, name: "game.sud" }, handlers);
  assert.deepEqual(handlers.log, [["check", "game.sud"], ["write", "game.sud"], ["status", "saved to: game.sud"]]);
  assert.deepEqual(outcome, { kind: "show_status", text: "saved to: game.sud" });
}

// Save after New onto an existing file asks once; declining writes nothing.
{
  const core = await loadCoreFlow();
  assert.equal(core.fileSessionEvent(WRITE_CONTEXT_EVENT_NEW_GAME_SUCCESS).ok, true);
  const handlers = recordingHandlers({ exists: true, yes: false });
  const outcome = await runFlow(core, { flow: FLOW_SAVE, name: "game.sud" }, handlers);
  assert.deepEqual(handlers.log, [["check", "game.sud"], REPLACE_ASK, ["status", "cancelled"]]);
  assert.equal(outcome.kind, "show_status");
}

// Accepting the replace question writes; the next Save continues the file without asking.
{
  const core = await loadCoreFlow();
  const accept = recordingHandlers({ exists: true, yes: true });
  await runFlow(core, { flow: FLOW_SAVE, name: "game.sud" }, accept);
  assert.deepEqual(accept.log, [["check", "game.sud"], REPLACE_ASK, ["write", "game.sud"], ["status", "saved to: game.sud"]]);
  const again = recordingHandlers({ exists: true });
  await runFlow(core, { flow: FLOW_SAVE, name: "game.sud" }, again);
  assert.deepEqual(again.log, [["check", "game.sud"], ["write", "game.sud"], ["status", "saved to: game.sud"]]);
}

// Save As onto the opened file continues it; after New the same Save As asks.
{
  const core = await loadCoreFlow();
  assert.equal(core.fileSessionEvent(WRITE_CONTEXT_EVENT_OPEN_SUCCESS, "game.sud").ok, true);
  const continuing = recordingHandlers({ exists: true });
  await runFlow(core, { flow: FLOW_SAVE_AS, name: "game.sud" }, continuing);
  assert.deepEqual(continuing.log, [["check", "game.sud"], ["write", "game.sud"], ["status", "saved to: game.sud"]]);
  assert.equal(core.fileSessionEvent(WRITE_CONTEXT_EVENT_NEW_GAME_SUCCESS).ok, true);
  const detached = recordingHandlers({ exists: true, yes: false });
  await runFlow(core, { flow: FLOW_SAVE_AS, name: "game.sud" }, detached);
  assert.deepEqual(detached.log, [["check", "game.sud"], REPLACE_ASK, ["status", "cancelled"]]);
}

// The name the platform actually wrote becomes the status and the working file.
{
  const core = await loadCoreFlow({ autoSave: true });
  const handlers = recordingHandlers({ write: () => ({ ok: true, name: "picked.sud" }) });
  await runFlow(core, { flow: FLOW_SAVE, name: "game.sud" }, handlers);
  assert.deepEqual(handlers.log.at(-1), ["status", "saved to: picked.sud"]);
  const autosave = recordingHandlers({ exists: true });
  await runFlow(core, { flow: FLOW_AUTOSAVE, command: "fill" }, autosave);
  assert.deepEqual(autosave.log, [["check", "picked.sud"], ["write", "picked.sud"]], "autosave continues the saved file");
}

// A picker the user closed ends quietly; a failed write shows the error.
{
  const core = await loadCoreFlow();
  const closed = recordingHandlers({ write: () => ({ ok: false, cancelled: true }) });
  assert.deepEqual(await runFlow(core, { flow: FLOW_SAVE, name: "game.sud" }, closed), { kind: "done" });
  const failed = recordingHandlers({
    write: () => {
      throw new Error("disk full");
    },
  });
  await runFlow(core, { flow: FLOW_SAVE, name: "game.sud" }, failed);
  assert.deepEqual(failed.log.at(-1), ["error", "disk full"]);
}

// First autosave with no working file resolves the default target, then asks if it exists.
{
  const core = await loadCoreFlow({ autoSave: true });
  const handlers = recordingHandlers({ exists: true, yes: false });
  const outcome = await runFlow(core, { flow: FLOW_AUTOSAVE, command: "fill" }, handlers);
  assert.deepEqual(handlers.log, [
    ["default"],
    ["check", "sudoku.sud"],
    ["ask", "Replace file?", "sudoku.sud already exists. Do you want to replace it?", "Replace", "Cancel"],
  ]);
  assert.deepEqual(outcome, { kind: "done" }, "declined autosave ends without a status");
}

// Autosave off: core ends the flow before any platform work.
{
  const core = await loadCoreFlow({ autoSave: false });
  const handlers = recordingHandlers();
  assert.deepEqual(await runFlow(core, { flow: FLOW_AUTOSAVE, command: "fill" }, handlers), { kind: "done" });
  assert.deepEqual(handlers.log, []);
}

// A handler that throws outside write ends the flow with its message; the next flow still runs.
{
  const core = await loadCoreFlow();
  const broken = recordingHandlers();
  broken.checkTarget = () => {
    throw new Error("host unreachable");
  };
  assert.deepEqual(await runFlow(core, { flow: FLOW_SAVE, name: "game.sud" }, broken), { kind: "show_error", text: "host unreachable" });
  const next = recordingHandlers();
  await runFlow(core, { flow: FLOW_SAVE, name: "game.sud" }, next);
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
  const yes = await askWithDialog({ step: "ask", title: "T", text: "Q?", ok_label: "Yes", cancel_label: "No" }, win);
  assert.equal(yes, true);
  assert.deepEqual(seen, [{ text: "Q?", labels: { title: "T", okLabel: "Yes", cancelLabel: "No" } }]);
  assert.equal(await askWithDialog({ step: "ask", text: "Q?" }, {}), false, "no dialog means no");
}

console.log("step_runner.test.mjs OK");
