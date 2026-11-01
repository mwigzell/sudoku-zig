// settings.js — File → Settings: warn, default difficulty, log level.

import { applyConfigOutcomeStatus, difficultyName, logLevelName, persistSettingsAfter } from "./shell.js";

/** @typedef {import("./types").ExecAction} ExecAction */
/** @typedef {import("./types").FlowHandlers} FlowHandlers */

/** Sync controls from wasm getConfig(). */
export function syncSettingsModal(modal, config) {
  if (modal.checkbox) modal.checkbox.checked = config.warn_solvability === true;
  if (modal.difficultySelect) modal.difficultySelect.value = difficultyName(config);
  if (modal.logLevelSelect) modal.logLevelSelect.value = logLevelName(config);
  if (modal.autoRestoreCheckbox) modal.autoRestoreCheckbox.checked = config.auto_restore === true;
  if (modal.autoNewCheckbox) modal.autoNewCheckbox.checked = config.auto_new === true;
  if (modal.autoSaveCheckbox) modal.autoSaveCheckbox.checked = config.auto_save === true;
}

/** Open the settings dialog with current config. */
export function showSettingsModal(modal, config) {
  syncSettingsModal(modal, config);
  modal.el.hidden = false;
}

/**
 * Run one settings command, then the core settings flow for it.
 * @param {ExecAction} action
 * @param {FlowHandlers} [settingsFlow]
 */
async function applySettingChange(game, session, modal, settingsFlow, action) {
  const result = game.exec(action);
  if (!applyConfigOutcomeStatus(session, game, null, result)) {
    syncSettingsModal(modal, session.config ?? game.getConfig());
    return;
  }
  await persistSettingsAfter(game, action.action, settingsFlow);
}

/**
 * File → Settings dialog.
 * @param {{ settingsFlow?: FlowHandlers, onDismiss?: () => void, closeMenus?: () => void }} [options]
 */
export function wireSettingsMenu(
  settingsBtn,
  game,
  session,
  modal,
  { settingsFlow, onDismiss, closeMenus } = {},
) {
  if (!settingsBtn || !modal?.el) return;
  settingsBtn.addEventListener("click", () => {
    closeMenus?.();
    showSettingsModal(modal, session.config ?? game.getConfig());
  });

  const change = (action) => applySettingChange(game, session, modal, settingsFlow, action);

  modal.checkbox?.addEventListener("change", async () => {
    await change({ action: "set_warn_solvability", enabled: modal.checkbox.checked });
  });

  modal.difficultySelect?.addEventListener("change", async () => {
    await change({ action: "set_difficulty", difficulty: modal.difficultySelect.value });
  });

  modal.logLevelSelect?.addEventListener("change", async () => {
    await change({ action: "set_log_level", log_level: modal.logLevelSelect.value });
  });

  modal.autoRestoreCheckbox?.addEventListener("change", async () => {
    await change({ action: "set_auto_restore", enabled: modal.autoRestoreCheckbox.checked });
  });

  modal.autoNewCheckbox?.addEventListener("change", async () => {
    await change({ action: "set_auto_new", enabled: modal.autoNewCheckbox.checked });
  });

  modal.autoSaveCheckbox?.addEventListener("change", async () => {
    await change({ action: "set_auto_save", enabled: modal.autoSaveCheckbox.checked });
  });

  modal.dismissEl?.addEventListener("click", () => {
    modal.el.hidden = true;
    onDismiss?.();
  });
}
