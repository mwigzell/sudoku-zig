// play_pad.js — the always-shown play pad: digits and Clear for the selected cell, plus Undo, Redo, Hint and Region.

/** `data-pad-command` values on the pad's command row. */
export const PAD_UNDO = "undo";
export const PAD_REDO = "redo";
export const PAD_HINT = "hint";
export const PAD_REGION = "region";

/**
 * @typedef {Object} PlayPadControls
 * @property {HTMLElement[]} cellKeys Digits and Clear: they act on the selected cell.
 * @property {HTMLElement | null} undo
 * @property {HTMLElement | null} redo
 * @property {HTMLElement | null} hint
 * @property {HTMLElement | null} region Toggle; `aria-pressed` mirrors `config.show_region`.
 */

/**
 * Resolve the pad's buttons.
 * @param {HTMLElement | null} padEl
 * @returns {PlayPadControls}
 */
export function collectPlayPadControls(padEl) {
  const command = (name) => padEl?.querySelector?.(`[data-pad-command="${name}"]`) ?? null;
  return {
    cellKeys: padEl?.querySelectorAll ? [...padEl.querySelectorAll("[data-play-key]")] : [],
    undo: command(PAD_UNDO),
    redo: command(PAD_REDO),
    hint: command(PAD_HINT),
    region: command(PAD_REGION),
  };
}

/**
 * Show core's state on the pad: Undo, Redo and Hint from the legend, Region from config; cell keys need a selection.
 * @param {PlayPadControls} controls
 * @param {Record<string, boolean>} legend
 * @param {{ show_region?: boolean }} config
 * @param {boolean} hasSelection
 */
export function syncPlayPad(controls, legend, config, hasSelection) {
  for (const key of controls.cellKeys) key.disabled = !hasSelection;
  if (controls.undo) controls.undo.disabled = !legend[PAD_UNDO];
  if (controls.redo) controls.redo.disabled = !legend[PAD_REDO];
  if (controls.hint) controls.hint.disabled = !legend[PAD_HINT];
  controls.region?.setAttribute("aria-pressed", config?.show_region === true ? "true" : "false");
}

/**
 * Wire the command row to the same actions the Edit and View menus run. Digit and Clear clicks are the play loop's.
 * @param {PlayPadControls} controls
 * @param {{ runEdit: (action: string) => unknown, toggleRegion: () => unknown }} actions
 */
export function wirePlayPad(controls, { runEdit, toggleRegion }) {
  for (const action of [PAD_UNDO, PAD_REDO, PAD_HINT]) {
    controls[action]?.addEventListener("click", () => runEdit(action));
  }
  controls.region?.addEventListener("click", () => toggleRegion());
}
