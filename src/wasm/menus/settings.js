// settings.js — File → Settings, generated from core's config table, and the `set_config` actions every Config control sends.

import * as stepRunner from "../flows/step_runner.js";

/** @typedef {import("../types").ExecAction} ExecAction */
/** @typedef {import("../types").FlowHandlers} FlowHandlers */
/** @typedef {import("../types").Config} Config */
/** @typedef {import("../types").ConfigTable} ConfigTable */
/** @typedef {import("../types").ConfigRow} ConfigRow */
/** @typedef {import("../types").SettingsModal} SettingsModal */

const SET_CONFIG = "set_config";

/** Config field names (core's config table) for the controls placed outside the Settings dialog. */
export const THEME_FIELD = "theme";
export const DIFFICULTY_FIELD = "difficulty";
export const SHOW_REGION_FIELD = "show_region";
export const SHOW_MARKS_FIELD = "show_marks";
export const AUTO_SAVE_FIELD = "auto_save";

/**
 * The action that sets one Config field; core checks the field and the value.
 * @param {string} field
 * @param {boolean | string} value
 * @returns {ExecAction}
 */
export function setConfigAction(field, value) {
  return { action: SET_CONFIG, field, value };
}

/**
 * The action that flips an on/off field from its value in `config`.
 * @param {Config} config
 * @param {string} field
 * @returns {ExecAction}
 */
export function toggleConfigAction(config, field) {
  return setConfigAction(field, config?.[field] !== true);
}

/**
 * The table's row for `field`.
 * @param {ConfigTable} table
 * @param {string} field
 * @returns {ConfigRow}
 */
export function configRow(table, field) {
  const row = table.rows.find((r) => r.field === field);
  if (!row) throw new Error(`config table has no row for ${field}`);
  return row;
}

/**
 * Core's label for the choice `name` of `field`.
 * @param {ConfigTable} table
 * @param {string} field
 * @param {string} name
 */
export function choiceLabel(table, field, name) {
  const choice = configRow(table, field).choices?.find((c) => c.name === name);
  if (!choice) throw new Error(`config table row ${field} has no choice ${name}`);
  return choice.label;
}

/**
 * Core's words for an on/off value.
 * @param {ConfigTable} table
 * @param {boolean} on
 */
export function onOffLabel(table, on) {
  return on ? table.on : table.off;
}

/**
 * One Settings control: a checkbox for an on/off row, a select of the row's choices otherwise.
 * @param {ConfigRow} row
 * @param {(tag: string) => HTMLElement} createElement
 */
function buildField(row, createElement) {
  const label = /** @type {HTMLLabelElement} */ (createElement("label"));
  label.className = "settings-field";
  let input;
  if (row.choices) {
    input = /** @type {HTMLSelectElement} */ (createElement("select"));
    for (const choice of row.choices) {
      const option = /** @type {HTMLOptionElement} */ (createElement("option"));
      option.value = choice.name;
      option.textContent = choice.label;
      input.append(option);
    }
    label.append(row.label, input);
  } else {
    label.classList.add("settings-check");
    input = /** @type {HTMLInputElement} */ (createElement("input"));
    input.type = "checkbox";
    label.append(input, row.label);
  }
  input.dataset.field = row.field;
  return { label, input };
}

/**
 * Fill the dialog with one control per table row; returns the controls by field.
 * @param {SettingsModal} modal
 * @param {ConfigTable} table
 * @param {(tag: string) => HTMLElement} createElement
 * @returns {Record<string, HTMLInputElement | HTMLSelectElement>}
 */
export function buildSettingsFields(modal, table, createElement) {
  modal.fieldsEl.replaceChildren();
  /** @type {Record<string, HTMLInputElement | HTMLSelectElement>} */
  const controls = {};
  for (const row of table.rows) {
    const { label, input } = buildField(row, createElement);
    modal.fieldsEl.append(label);
    controls[row.field] = input;
  }
  return controls;
}

/**
 * Show each field's value from the Config core reports.
 * @param {Record<string, HTMLInputElement | HTMLSelectElement>} controls
 * @param {Config} config
 */
export function syncSettingsFields(controls, config) {
  for (const [field, input] of Object.entries(controls)) {
    if (input.tagName === "SELECT") input.value = String(config[field]);
    else /** @type {HTMLInputElement} */ (input).checked = config[field] === true;
  }
}

/**
 * The value a control holds: a checkbox's state, or the picked choice's name.
 * @param {HTMLInputElement | HTMLSelectElement} input
 */
function controlValue(input) {
  return input.tagName === "SELECT" ? input.value : /** @type {HTMLInputElement} */ (input).checked;
}

/**
 * File → Settings dialog: one control per config table row; each change runs `set_config` through core,
 * then the dialog re-syncs from the Config core shows, or from the session's when core refused it.
 * @param {HTMLElement | null} settingsBtn
 * @param {import("../types").GameApi} game
 * @param {import("../types").WebSession} session
 * @param {SettingsModal} modal
 * @param {{ steps: FlowHandlers, onDismiss?: () => void, closeMenus?: () => void, createElement?: (tag: string) => HTMLElement }} options
 */
export function wireSettingsMenu(
  settingsBtn,
  game,
  session,
  modal,
  { steps, onDismiss, closeMenus, createElement = (tag) => document.createElement(tag) },
) {
  if (!settingsBtn || !modal?.el) return;
  const controls = buildSettingsFields(modal, session.configTable, createElement);

  settingsBtn.addEventListener("click", () => {
    closeMenus?.();
    syncSettingsFields(controls, session.config);
    modal.el.hidden = false;
  });

  for (const [field, input] of Object.entries(controls)) {
    input.addEventListener("change", async () => {
      await stepRunner.runCommand(game, setConfigAction(field, controlValue(input)), steps, (step) =>
        syncSettingsFields(controls, step.config));
      syncSettingsFields(controls, session.config);
    });
  }

  modal.dismissEl?.addEventListener("click", () => {
    modal.el.hidden = true;
    onDismiss?.();
  });
}
