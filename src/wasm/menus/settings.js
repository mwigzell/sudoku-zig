// settings.js — File → Settings: warn, default difficulty, log level.

import * as stepRunner from "../flows/step_runner.js";

/** @typedef {import("../types").ExecAction} ExecAction */
/** @typedef {import("../types").FlowHandlers} FlowHandlers */

const DIFFICULTY_WIRE = { 1: "easy", 2: "medium", 3: "hard" };
const LOG_WIRE = ["debug", "info", "warn", "err", "fatal"];

/** Normalize config difficulty enum/wire value to persisted settings string. */
export function difficultyName(config) {
  if (typeof config.difficulty === "string") return config.difficulty;
  return DIFFICULTY_WIRE[config.difficulty] ?? "easy";
}

/** Normalize config log level enum/wire value to persisted settings string. */
function logLevelName(config) {
  if (typeof config.log_level === "string") return config.log_level;
  return LOG_WIRE[config.log_level] ?? "info";
}

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
 * Run one settings command through core; the dialog re-syncs from the config core shows,
 * then from the session's config, which a rejected command leaves unchanged.
 * @param {ExecAction} action
 * @param {FlowHandlers} steps
 */
async function applySettingChange(game, session, modal, steps, action) {
  await stepRunner.runCommand(game, action, steps, (step) => syncSettingsModal(modal, step.config));
  syncSettingsModal(modal, session.config);
}

/**
 * File → Settings dialog.
 * @param {{ steps: FlowHandlers, onDismiss?: () => void, closeMenus?: () => void }} [options]
 */
export function wireSettingsMenu(
  settingsBtn,
  game,
  session,
  modal,
  { steps, onDismiss, closeMenus } = {},
) {
  if (!settingsBtn || !modal?.el) return;
  settingsBtn.addEventListener("click", () => {
    closeMenus?.();
    showSettingsModal(modal, session.config ?? game.getConfig());
  });

  const change = (action) => applySettingChange(game, session, modal, steps, action);

  modal.checkbox?.addEventListener("change", async () => {
    await change({ action: "toggle_warn_solvability" });
  });

  modal.difficultySelect?.addEventListener("change", async () => {
    await change({ action: "set_difficulty", difficulty: modal.difficultySelect.value });
  });

  modal.logLevelSelect?.addEventListener("change", async () => {
    await change({ action: "set_log_level", log_level: modal.logLevelSelect.value });
  });

  modal.autoRestoreCheckbox?.addEventListener("change", async () => {
    await change({ action: "toggle_auto_restore" });
  });

  modal.autoNewCheckbox?.addEventListener("change", async () => {
    await change({ action: "toggle_auto_new" });
  });

  modal.autoSaveCheckbox?.addEventListener("change", async () => {
    await change({ action: "toggle_auto_save" });
  });

  modal.dismissEl?.addEventListener("click", () => {
    modal.el.hidden = true;
    onDismiss?.();
  });
}
