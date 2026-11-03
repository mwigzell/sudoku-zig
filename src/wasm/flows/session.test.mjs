// session.test.mjs — web session: startup shape, outcomes and the current-file label.

import assert from "node:assert/strict";
import * as sessionMod from "./session.js";

{
  const ready = {
    state: { cells: [] },
    legend: { new: true },
    config: { auto_save: true },
    default_save_filename: "sudoku.sud",
  };
  const session = sessionMod.createWebSessionFromStartup(ready);
  assert.equal(session.default_save_filename, "sudoku.sud");
  assert.equal(session.boundFilename, null);
  assert.equal(session.fileHandle, null);
}

{
  for (const key of sessionMod.REQUIRED_STARTUP_READY_KEYS) {
    const ready = {
      state: { cells: [] },
      legend: {},
      config: {},
      default_save_filename: "sudoku.sud",
    };
    delete ready[key];
    assert.throws(
      () => sessionMod.createWebSessionFromStartup(ready),
      new RegExp(`missing ${key}`),
    );
  }
}

{
  assert.equal(sessionMod.currentFileLabel({}), sessionMod.CURRENT_FILE_UNSAVED_LABEL);
  assert.equal(sessionMod.currentFileLabel({ default_save_filename: "sudoku.sud" }), sessionMod.CURRENT_FILE_UNSAVED_LABEL);
  assert.equal(sessionMod.currentFileLabel({ boundFilename: "game.sud" }), "game.sud");
}

{
  const session = {
    state: { cells: [] },
    legend: { save: false },
    config: { theme: "dark" },
  };
  const nextState = { cells: [{ value: 2, given: false, conflict: false }] };
  const nextLegend = { save: true };
  sessionMod.applySessionOutcome(session, { state: nextState, legend: nextLegend });
  assert.equal(session.state, nextState);
  assert.equal(session.legend, nextLegend);
  assert.equal(session.config.theme, "dark");
}

{
  const status = { textContent: "old", className: "" };
  const labels = { [sessionMod.CURRENT_FILE_DESKTOP_ID]: { textContent: "" } };
  const root = {
    getElementById(id) {
      return labels[id] ?? null;
    },
  };
  const session = {
    default_save_filename: "save.sud",
    state: { cells: [] },
    legend: {},
    config: {},
  };
  const nextState = { cells: [{ value: 7, given: false, conflict: false }] };
  sessionMod.applySessionOutcomeStatus(session, status, { state: nextState, msg: "updated" });
  sessionMod.syncCurrentFileLabels(session, root);
  assert.equal(session.state, nextState);
  assert.equal(status.textContent, "updated");
  assert.equal(labels[sessionMod.CURRENT_FILE_DESKTOP_ID].textContent, sessionMod.CURRENT_FILE_UNSAVED_LABEL);
}

{
  const nodes = {
    [sessionMod.CURRENT_FILE_DESKTOP_ID]: { textContent: "" },
  };
  const root = {
    getElementById(id) {
      return nodes[id] ?? null;
    },
  };
  sessionMod.syncCurrentFileLabels({ boundFilename: "alpha.sud" }, root);
  assert.equal(nodes[sessionMod.CURRENT_FILE_DESKTOP_ID].textContent, "alpha.sud");
}
