// menu.js — Edit menu: undo/redo/solve/deselect (web only; native has no cell selection).

import {
  applyEventStatus,
  showErrorModal,
  runSessionCommand,
  startCopyPuzzleOnClick,
  readClipboardText,
} from "./shell.js";
import { LEGEND_WIRE_COPY, LEGEND_WIRE_PASTE } from "./menu_bar.js";
import { boardCommandFlow, readSelection, renderBoard, runBoardCommand } from "./board.js";

import { syncMenuBar } from "./menu_bar.js";
import { runCommand, STEP_SHOW_STATUS } from "./step_runner.js";
import { bindLoadedGame } from "./file_menu.js";

/** @typedef {import("./types").GameApi} GameApi */

const PASTE_COMMAND = "paste";
const COPY_COMMAND = "copy";

/** Mirror legend flags and deselect enablement (active only when a cell is selected). */
export function syncEditMenu(legend, controls, selection, boardEl) {
  syncMenuBar(legend, controls);
  if (controls.deselect) {
    const sel =
      boardEl != null ? readSelection(boardEl, selection) : selection?.getSelection?.();
    controls.deselect.disabled = sel == null;
  }
}

export function parseEditShortcut(event) {
  if (!event.ctrlKey || event.altKey) return null;
  if (event.key === "z" && !event.shiftKey) return "undo";
  if (event.key === "z" && event.shiftKey) return "redo";
  if (event.key === "Z" && event.shiftKey) return "redo";
  return null;
}

/** Used by Escape handling to avoid deselect while a menubar popup is active. */
export function anyMenuOpen(root) {
  if (typeof root.querySelectorAll !== "function") return false;
  return [...root.querySelectorAll("#menu-bar .menu")].some((menu) => menu.dataset.open === "true");
}

/** Edit → Copy: core has the puzzle line put on the clipboard; denied leaves the board intact. */
/** @param {GameApi} game */
export async function handleCopyPuzzle(
  game,
  session,
  statusEl,
  errorModal,
  { clipboard, doc } = {},
) {
  if (!session.legend[LEGEND_WIRE_COPY]) return { handled: false };
  const outcome = await runCommand(game, { action: COPY_COMMAND }, {
    copyLine: () => startCopyPuzzleOnClick(game, { clipboard, doc: doc ?? globalThis.document }),
    showStatus: (text) => applyEventStatus(statusEl, { ok: true, msg: text }),
    showError: (text) => showErrorModal(errorModal, text),
  });
  return { handled: true, ok: outcome.kind === STEP_SHOW_STATUS };
}

/**
 * Edit → Paste: core asks for the clipboard text and loads it; a read or load failure keeps the board.
 * @param {GameApi} game
 * @param {{ clipboard?: any, commandFlow?: import("./types").FlowHandlers, onShown?: (step: import("./types").FlowStep) => void }} [options]
 */
export function handlePastePuzzle(
  game,
  session,
  statusEl,
  errorModal,
  { clipboard, commandFlow = boardCommandFlow(game, session, statusEl, errorModal), onShown } = {},
) {
  if (!session.legend[LEGEND_WIRE_PASTE]) return { handled: false };
  const handlers = { ...commandFlow, readClipboard: () => readClipboardText({ clipboard }) };
  const shown = (step) => {
    if (step.loaded) bindLoadedGame(session, null);
    onShown?.(step);
  };
  return { handled: true, done: runSessionCommand(game, { action: PASTE_COMMAND }, handlers, shown) };
}

export function handleDeselect(selection) {
  if (!selection.getSelection()) return { handled: false };
  selection.deselect();
  return { handled: true };
}

/** Hint optionally includes selected cell; all other edit actions are command-only payloads. */
function execPayloadForEditAction(action, boardEl, selection) {
  if (action !== "hint") return { action };
  const sel = readSelection(boardEl, selection);
  if (!sel) return { action: "hint" };
  return { action: "hint", row: sel.row, col: sel.col };
}

/**
 * Edit dispatcher: actions the legend disables are not handled; the rest run through core.
 * @param {GameApi} game
 * @param {{ commandFlow?: import("./types").FlowHandlers, onShown?: (step: import("./types").FlowStep) => void }} [options]
 */
export function handleEditAction(
  action,
  game,
  boardEl,
  selection,
  statusEl,
  errorModal,
  session,
  createElement,
  { commandFlow = boardCommandFlow(game, session, statusEl, errorModal), onShown } = {},
) {
  if (action in session.legend && !session.legend[action]) return { handled: false };
  const payload = execPayloadForEditAction(action, boardEl, selection);
  const done = runBoardCommand(game, payload, { boardEl, selection, createElement, commandFlow, onShown });
  return { handled: true, done };
}

/** Wires edit controls + keyboard shortcuts onto one shared edit action dispatcher. */
/** @param {GameApi} game */
export function wireEditMenu(
  undoBtn,
  redoBtn,
  deselectBtn,
  game,
  boardEl,
  selection,
  statusEl,
  errorModal,
  session,
  createElement,
  root = document,
  {
    syncLegend,
    copyBtn,
    pasteBtn,
    closeMenus,
    clipboard = globalThis.navigator?.clipboard,
    commandFlow,
  } = {},
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
    syncEditMenu(session.legend, controls, selection, boardEl);
  };
  syncEdit();

  const run = (action) =>
    handleEditAction(action, game, boardEl, selection, statusEl, errorModal, session, createElement, {
      commandFlow,
      onShown: syncEdit,
    });

  const runDeselect = () => {
    const outcome = handleDeselect(selection);
    if (outcome.handled) syncEdit();
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
    void handleCopyPuzzle(game, session, statusEl, errorModal, {
      clipboard,
      doc: root.ownerDocument ?? globalThis.document,
    });
  });
  pasteBtn?.addEventListener("click", (event) => {
    closeMenus?.();
    event?.stopPropagation?.();
    handlePastePuzzle(game, session, statusEl, errorModal, {
      clipboard,
      commandFlow,
      onShown: (step) => {
        renderBoard(boardEl, step.state, createElement);
        selection.deselect();
        syncEdit();
      },
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
      return;
    }
    const action = parseEditShortcut(event);
    if (!action) return;
    const outcome = run(action);
    if (!outcome.handled) return;
    event.preventDefault();
  });

  return { sync: syncEdit, run, runDeselect };
}
