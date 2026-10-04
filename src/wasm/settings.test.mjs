// settings.test.mjs — Settings dialog contract.

import assert from "node:assert/strict";
import { hostViewPrefsForPersist } from "./shell.js";
import { syncSettingsModal, showSettingsModal, wireSettingsMenu } from "./settings.js";

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
  syncSettingsModal(modal, { warn_solvability: true, difficulty: 2, log_level: 2, auto_restore: true, auto_new: true, auto_save: true });
  assert.equal(modal.checkbox.checked, true);
  assert.equal(modal.difficultySelect.value, "medium");
  assert.equal(modal.logLevelSelect.value, "warn");
  assert.equal(modal.autoRestoreCheckbox.checked, true);
  assert.equal(modal.autoNewCheckbox.checked, true);
  assert.equal(modal.autoSaveCheckbox.checked, true);
  syncSettingsModal(modal, { warn_solvability: false });
  assert.equal(modal.checkbox.checked, false);
}

{
  const modal = {
    el: { hidden: true },
    checkbox: { checked: false },
  };
  showSettingsModal(modal, { warn_solvability: true });
  assert.equal(modal.el.hidden, false);
  assert.equal(modal.checkbox.checked, true);
}

{
  const execCalls = [];
  const persistCalls = [];
  const game = {
    getConfig() {
      return {
        theme: "dark",
        show_region: false,
        warn_solvability: execCalls.at(-1)?.enabled === true,
        auto_restore: false,
        auto_new: false,
        auto_save: false,
      };
    },
    exec(action) {
      execCalls.push(action);
      return { ok: true };
    },
  };
  const session = { config: { warn_solvability: false } };
  const modal = {
    el: { hidden: true },
    checkbox: { checked: false, addEventListener(type, fn) { this[`on${type}`] = fn; } },
    dismissEl: { addEventListener(type, fn) { this[`on${type}`] = fn; } },
  };
  let openSettings;
  const btn = {
    addEventListener(type, fn) {
      if (type === "click") openSettings = fn;
    },
  };
  let dismissSettings;
  modal.dismissEl.addEventListener = (type, fn) => {
    if (type === "click") dismissSettings = fn;
  };
  let onCheckboxChange;
  modal.checkbox.addEventListener = (type, fn) => {
    if (type === "change") onCheckboxChange = fn;
  };

  wireSettingsMenu(btn, game, session, modal, {
    onPersist: async (cfg) => {
      persistCalls.push(cfg);
    },
  });

  openSettings();
  assert.equal(modal.el.hidden, false);

  modal.checkbox.checked = true;
  await onCheckboxChange();
  assert.deepEqual(execCalls[0], { action: "set_warn_solvability", enabled: true });
  assert.equal(session.config.warn_solvability, true);
  assert.equal(persistCalls.length, 1);
  assert.deepEqual(hostViewPrefsForPersist(persistCalls[0]), {
    difficulty: "easy",
    log_level: "info",
    theme: "dark",
    show_region: false,
    warn_solvability: true,
    auto_restore: false,
    auto_new: false,
    auto_save: false,
  });

  dismissSettings();
  assert.equal(modal.el.hidden, true);
}

{
  const execCalls = [];
  const game = {
    getConfig() {
      const last = execCalls.at(-1);
      return {
        difficulty: last?.difficulty === "hard" ? 3 : 1,
        log_level: 1,
        warn_solvability: false,
      };
    },
    exec(action) {
      execCalls.push(action);
      return { ok: true };
    },
  };
  const session = { config: { difficulty: 1 } };
  let onDifficultyChange;
  const modal = {
    el: { hidden: true },
    checkbox: { addEventListener() {} },
    difficultySelect: {
      value: "easy",
      addEventListener(type, fn) {
        if (type === "change") onDifficultyChange = fn;
      },
    },
    logLevelSelect: { addEventListener() {} },
    dismissEl: { addEventListener() {} },
  };
  wireSettingsMenu({ addEventListener() {} }, game, session, modal, {});
  modal.difficultySelect.value = "hard";
  await onDifficultyChange();
  assert.deepEqual(execCalls[0], { action: "set_difficulty", difficulty: "hard" });
  assert.equal(session.config.difficulty, 3);
}

{
  const execCalls = [];
  const game = {
    getConfig() {
      return { auto_save: execCalls.at(-1)?.enabled === true };
    },
    exec(action) {
      execCalls.push(action);
      return { ok: true };
    },
  };
  const session = { config: { auto_save: false } };
  let onAutoSaveChange;
  const modal = {
    el: { hidden: true },
    checkbox: { addEventListener() {} },
    difficultySelect: { addEventListener() {} },
    logLevelSelect: { addEventListener() {} },
    autoSaveCheckbox: {
      checked: false,
      addEventListener(type, fn) {
        if (type === "change") onAutoSaveChange = fn;
      },
    },
    dismissEl: { addEventListener() {} },
  };
  wireSettingsMenu({ addEventListener() {} }, game, session, modal, {});
  modal.autoSaveCheckbox.checked = true;
  await onAutoSaveChange();
  assert.deepEqual(execCalls[0], { action: "set_auto_save", enabled: true });
  assert.equal(session.config.auto_save, true);
}

console.log("settings.test.mjs OK");
