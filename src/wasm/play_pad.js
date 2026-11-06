// play_pad.js — the always-shown play pad: digits and Clear for the selected cell, plus Undo, Redo, Hint and Region.

/** `data-pad-command` values on the pad's command row. */
export const PAD_UNDO = "undo";
export const PAD_REDO = "redo";
export const PAD_HINT = "hint";
export const PAD_REGION = "region";

/** `data-play-key` of the Clear button; the other cell keys are digits. */
const CLEAR_KEY = "0";

/**
 * @typedef {Object} PlayPadControls
 * @property {HTMLElement[]} digits Digit keys: they fill the selected cell.
 * @property {HTMLElement | null} clear Clears the selected cell.
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
  const cellKeys = padEl?.querySelectorAll ? [...padEl.querySelectorAll("[data-play-key]")] : [];
  return {
    digits: cellKeys.filter((key) => key.dataset.playKey !== CLEAR_KEY),
    clear: cellKeys.find((key) => key.dataset.playKey === CLEAR_KEY) ?? null,
    undo: command(PAD_UNDO),
    redo: command(PAD_REDO),
    hint: command(PAD_HINT),
    region: command(PAD_REGION),
  };
}

/**
 * Show core's state on the pad: Undo, Redo and Hint from the legend, Region from config.
 * Digits need a selected cell core marks `fillable`; Clear needs one core marks `clearable`.
 * @param {PlayPadControls} controls
 * @param {Record<string, boolean>} legend
 * @param {{ show_region?: boolean }} config
 * @param {{ clearable?: boolean, fillable?: boolean } | null} selectedCell The selected cell's snapshot, or null when none is selected.
 */
export function syncPlayPad(controls, legend, config, selectedCell) {
  for (const key of controls.digits) key.disabled = selectedCell?.fillable !== true;
  if (controls.clear) controls.clear.disabled = selectedCell?.clearable !== true;
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
