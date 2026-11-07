// menu.js — Edit menu: undo/redo/solve/deselect (web only; native has no cell selection).

import * as menuBar from "./menu_bar.js";
import * as board from "../board.js";

import * as menuBarMod from "./menu_bar.js";
import * as stepRunner from "../flows/step_runner.js";

/** @typedef {import("../types").GameApi} GameApi */
/** @typedef {import("../types").FlowHandlers} FlowHandlers */
/** @typedef {import("../types").FlowStep} FlowStep */

const PASTE_COMMAND = "paste";
const COPY_COMMAND = "copy";

/** Mirror legend flags and deselect enablement (active only when core has a cell selected). */
export function syncEditMenu(legend, controls, selection) {
  menuBarMod.syncMenuBar(legend, controls);
  if (controls.deselect) controls.deselect.disabled = selection?.getSelection?.() == null;
}

/** Used by Escape handling to avoid deselect while a menubar popup is active. */
export function anyMenuOpen(root) {
  if (typeof root.querySelectorAll !== "function") return false;
  return [...root.querySelectorAll("#menu-bar .menu")].some((menu) => menu.dataset.open === "true");
}

/**
 * Edit → Copy: core has the puzzle put on the clipboard; denied leaves the board intact.
 * @param {GameApi} game
 * @param {FlowHandlers} steps
 */
export async function handleCopyPuzzle(game, session, steps) {
  if (!session.legend[menuBar.LEGEND_WIRE_COPY]) return { handled: false };
  const outcome = await stepRunner.runCommand(game, { action: COPY_COMMAND }, steps);
  return { handled: true, ok: outcome.kind === stepRunner.STEP_SHOW_STATUS };
}

/**
 * Edit → Paste: core asks for the clipboard puzzle and loads it; a read or load failure keeps the board.
 * @param {GameApi} game
 * @param {FlowHandlers} steps
 * @param {(step: FlowStep) => void} [onShown]
 */
export function handlePastePuzzle(game, session, steps, onShown) {
  if (!session.legend[menuBar.LEGEND_WIRE_PASTE]) return { handled: false };
  return { handled: true, done: stepRunner.runCommand(game, { action: PASTE_COMMAND }, steps, onShown) };
}

/** Deselect in core when a cell is selected; `done` settles once the board is redrawn. */
export function handleDeselect(selection) {
  if (!selection.getSelection()) return { handled: false };
  return { handled: true, done: selection.deselect() };
}

/** Hint carries core's selected cell as its target (board-wide when none); other edit actions carry nothing. */
function execPayloadForEditAction(action, selection) {
  if (action !== "hint") return { action };
  const sel = selection.getSelection();
  if (!sel) return { action: "hint" };
  return { action: "hint", row: sel.row, col: sel.col };
}

/**
 * Edit dispatcher: actions the legend disables are not handled; the rest run through core.
 * @param {GameApi} game
 * @param {{ steps: FlowHandlers, onShown?: (step: FlowStep) => void }} options
 */
export function handleEditAction(
  action,
  game,
  boardEl,
  selection,
  session,
  createElement,
  { steps, onShown },
) {
  if (action in session.legend && !session.legend[action]) return { handled: false };
  const payload = execPayloadForEditAction(action, selection);
  const done = board.runBoardCommand(game, payload, { boardEl, createElement, steps, onShown });
  return { handled: true, done };
}

/**
 * Wires edit controls and Escape (deselect) onto one shared edit action dispatcher.
 * @param {GameApi} game
 * @param {{ steps: FlowHandlers, syncLegend?: () => void, copyBtn?: HTMLElement, pasteBtn?: HTMLElement, closeMenus?: () => void }} options
 */
export function wireEditMenu(
  undoBtn,
  redoBtn,
  deselectBtn,
  game,
  boardEl,
  selection,
  session,
  createElement,
  root = document,
  { steps, syncLegend, copyBtn, pasteBtn, closeMenus },
) {
  const controls = {
    undo: undoBtn,
    redo: redoBtn,
    deselect: deselectBtn,
    copy: copyBtn,
    paste: pasteBtn,
  };

  const syncEdit = () => {
    if (syncLegend) syncLegend();
    syncEditMenu(session.legend, controls, selection);
  };
  syncEdit();

  const run = (action) =>
    handleEditAction(action, game, boardEl, selection, session, createElement, { steps, onShown: syncEdit });

  const runDeselect = () => {
    const outcome = handleDeselect(selection);
    if (outcome.handled) void outcome.done.then(syncEdit);
    return outcome;
  };

  undoBtn.addEventListener("click", () => {
    closeMenus?.();
    run("undo");
  });
  redoBtn.addEventListener("click", () => {
    closeMenus?.();
    run("redo");
  });
  deselectBtn?.addEventListener("click", () => {
    closeMenus?.();
    runDeselect();
  });
  copyBtn?.addEventListener("click", (event) => {
    closeMenus?.();
    event?.stopPropagation?.();
    void handleCopyPuzzle(game, session, steps);
  });
  pasteBtn?.addEventListener("click", (event) => {
    closeMenus?.();
    event?.stopPropagation?.();
    handlePastePuzzle(game, session, steps, (step) => {
      board.renderBoard(boardEl, step.state, createElement);
      syncEdit();
    });
  });
  if (typeof root.querySelector === "function") {
    const solveBtn = root.querySelector("#edit-solve");
    if (solveBtn) solveBtn.addEventListener("click", () => {
      closeMenus?.();
      run("solve");
    });
    const hintBtn = root.querySelector("#edit-hint");
    if (hintBtn) hintBtn.addEventListener("click", () => {
      closeMenus?.();
      run("hint");
    });
  }

  root.addEventListener("keydown", (event) => {
    if (event.key === "Escape") {
      if (anyMenuOpen(root)) return;
      const outcome = runDeselect();
      if (!outcome.handled) return;
      event.preventDefault();
    }
  });

  return { sync: syncEdit, run, runDeselect };
}
