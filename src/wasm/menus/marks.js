// marks.js — pencil marks: View → Show Pencil Marks and the pad's Pencil mode, both run through core.

import * as board from "../board.js";
import * as settings from "./settings.js";

/** @typedef {import("../types").GameApi} GameApi */
/** @typedef {import("../types").FlowHandlers} FlowHandlers */
/** @typedef {import("../types").WebSession} WebSession */

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
 * @param {{ onChange?: () => void, steps: FlowHandlers, createElement?: (tag: string) => HTMLElement }} options
 */
export function wireMarks(controls, game, session, boardEl, { onChange, steps, createElement }) {
  const sync = () => syncMarksMenu(controls, session.config);
  /** @param {import("../types").ExecAction} action */
  const run = (action) =>
    board.runBoardCommand(game, action, {
      boardEl,
      createElement,
      steps,
      onShown: () => {
        sync();
        onChange?.();
      },
    });

  controls.viewMarks?.addEventListener("click", () => {
    void run(settings.toggleConfigAction(session.config, settings.SHOW_MARKS_FIELD));
  });
  sync();

  return {
    sync,
    togglePencilMode: () => run({ action: TOGGLE_PENCIL_MODE }),
  };
}
