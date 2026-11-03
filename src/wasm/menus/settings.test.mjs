// settings.test.mjs — Settings dialog contract.

import assert from "node:assert/strict";
import * as settings from "./settings.js";
import * as webSteps from "../flows/web_steps.js";
import { loadGame } from "../test_support.mjs";

{
  const modal = {
    el: { hidden: true },
    checkbox: { checked: false },
    difficultySelect: { value: "easy" },
    logLevelSelect: { value: "info" },
    autoRestoreCheckbox: { checked: false },
    autoNewCheckbox: { checked: false },
    autoSaveCheckbox: { checked: false },
  };
  settings.syncSettingsModal(modal, { warn_solvability: true, difficulty: 2, log_level: 2, auto_restore: true, auto_new: true, auto_save: true });
  assert.equal(modal.checkbox.checked, true);
  assert.equal(modal.difficultySelect.value, "medium");
  assert.equal(modal.logLevelSelect.value, "warn");
  assert.equal(modal.autoRestoreCheckbox.checked, true);
  assert.equal(modal.autoNewCheckbox.checked, true);
  assert.equal(modal.autoSaveCheckbox.checked, true);
  settings.syncSettingsModal(modal, { warn_solvability: false });
  assert.equal(modal.checkbox.checked, false);
}

{
  const modal = {
    el: { hidden: true },
    checkbox: { checked: false },
  };
  settings.showSettingsModal(modal, { warn_solvability: true });
  assert.equal(modal.el.hidden, false);
  assert.equal(modal.checkbox.checked, true);
}

/** Real wasm game, its session, and web step handlers that record every settings write. */
async function settingsHarness() {
  const game = await loadGame();
  const session = { config: game.getConfig(), legend: game.getLegend(), state: game.getState() };
  const persisted = [];
  const steps = webSteps.webSteps(game, session, {
    fetchFn: async (url, init) => {
      persisted.push(JSON.parse(init.body));
      return { ok: true, status: 204 };
    },
  });
  return { game, session, persisted, steps };
}

/** A control that records its listener for `type` under `on<type>`. */
const control = (extra = {}) => ({
  ...extra,
  addEventListener(type, fn) {
    this[`on${type}`] = fn;
  },
});

{
  const { game, session, persisted, steps } = await settingsHarness();
  const modal = { el: { hidden: true }, checkbox: control({ checked: false }), dismissEl: control() };
  const btn = control();
  settings.wireSettingsMenu(btn, game, session, modal, { steps });

  btn.onclick();
  assert.equal(modal.el.hidden, false);

  modal.checkbox.checked = true;
  await modal.checkbox.onchange();
  assert.equal(session.config.warn_solvability, true);
  assert.equal(modal.checkbox.checked, true);
  assert.equal(persisted.length, 1, "core asks to persist after the settings change");
  assert.equal(persisted[0].warn_solvability, true);

  modal.dismissEl.onclick();
  assert.equal(modal.el.hidden, true);
}

{
  const { game, session, steps } = await settingsHarness();
  const modal = {
    el: { hidden: true },
    checkbox: control(),
    difficultySelect: control({ value: "easy" }),
    logLevelSelect: control(),
    dismissEl: control(),
  };
  settings.wireSettingsMenu(control(), game, session, modal, { steps });
  modal.difficultySelect.value = "hard";
  await modal.difficultySelect.onchange();
  assert.equal(session.config.difficulty, 3);
  assert.equal(modal.difficultySelect.value, "hard");
}

{
  const { game, session, persisted, steps } = await settingsHarness();
  const modal = {
    el: { hidden: true },
    checkbox: control(),
    difficultySelect: control(),
    logLevelSelect: control(),
    autoSaveCheckbox: control({ checked: false }),
    dismissEl: control(),
  };
  settings.wireSettingsMenu(control(), game, session, modal, { steps });
  modal.autoSaveCheckbox.checked = true;
  await modal.autoSaveCheckbox.onchange();
  assert.equal(session.config.auto_save, true);
  assert.equal(persisted.at(-1).auto_save, true);
}

console.log("settings.test.mjs OK");
