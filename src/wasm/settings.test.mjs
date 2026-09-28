// settings.test.mjs — Settings dialog contract.

import assert from "node:assert/strict";
import { hostViewPrefsForPersist } from "./shell.js";
import { syncSettingsModal, showSettingsModal, wireSettingsMenu } from "./settings.js";

{
  const modal = {
    el: { hidden: true },
    checkbox: { checked: false },
  };
  syncSettingsModal(modal, { warn_solvability: true });
  assert.equal(modal.checkbox.checked, true);
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
  });

  dismissSettings();
  assert.equal(modal.el.hidden, true);
}

console.log("settings.test.mjs OK");
