// marks.js — pencil marks: View → Show Pencil Marks and the pad's Pencil mode, both run through core.

import * as board from "../board.js";

/** @typedef {import("../types").GameApi} GameApi */
/** @typedef {import("../types").FlowHandlers} FlowHandlers */
/** @typedef {import("../types").BoardSelection} BoardSelection */
/** @typedef {import("../types").WebSession} WebSession */

const TOGGLE_SHOW_MARKS = "toggle_show_marks";
const TOGGLE_PENCIL_MODE = "toggle_pencil_mode";

/**
 * Check View → Show Pencil Marks from core's `show_marks` setting.
 * @param {{ viewMarks?: HTMLElement | null }} controls
 * @param {{ show_marks?: boolean }} config
 */
export function syncMarksMenu(controls, config) {
  if (!controls.viewMarks) return;
  const enabled = config?.show_marks === true;
  controls.viewMarks.setAttribute("aria-checked", enabled ? "true" : "false");
  controls.viewMarks.classList.toggle("selected", enabled);
}

/**
 * Wire View → Show Pencil Marks. Both toggles redraw the board, because either can change
 * core's `marks_visible`.
 * @param {{ viewMarks?: HTMLElement | null }} controls
 * @param {GameApi} game
 * @param {WebSession} session
 * @param {HTMLElement} boardEl
 * @param {BoardSelection} selection
 * @param {{ onChange?: () => void, steps: FlowHandlers, createElement?: (tag: string) => HTMLElement }} options
 */
export function wireMarks(controls, game, session, boardEl, selection, { onChange, steps, createElement }) {
  const sync = () => syncMarksMenu(controls, session.config);
  /** @param {string} action */
  const run = (action) =>
    board.runBoardCommand(game, { action }, {
      boardEl,
      selection,
      createElement,
      steps,
      onShown: () => {
        sync();
        onChange?.();
      },
    });

  controls.viewMarks?.addEventListener("click", () => {
    void run(TOGGLE_SHOW_MARKS);
  });
  sync();

  return {
    sync,
    togglePencilMode: () => run(TOGGLE_PENCIL_MODE),
  };
}
