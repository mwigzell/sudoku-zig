// menu.js — Edit menu: undo/redo/solve/deselect (web only; native has no cell selection).

import {
  applyEventStatus,
  applyHintExecStatus,
  applyExecResult,
  showErrorModal,
  startCopyPuzzleOnClick,
  readClipboardText,
  importPuzzle,
} from "./shell.js";
import { LEGEND_WIRE_COPY, LEGEND_WIRE_PASTE } from "./menu_bar.js";
import { applySuccessfulExec, readSelection, renderBoard } from "./board.js";

import { syncMenuBar } from "./menu_bar.js";

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

export function anyMenuOpen(root) {
  if (typeof root.querySelectorAll !== "function") return false;
  return [...root.querySelectorAll("#menu-bar .menu")].some((menu) => menu.dataset.open === "true");
}

/** Edit → Copy: wasm `exportPuzzle` bytes only; clipboard denied leaves board intact. */
export async function handleCopyPuzzle(
  game,
  session,
  statusEl,
  errorModal,
  { clipboard, doc } = {},
) {
  if (!session.legend[LEGEND_WIRE_COPY]) return { handled: false };
  const result = await startCopyPuzzleOnClick(game, { clipboard, doc: doc ?? globalThis.document });
  if (!result.ok) {
    if (result.error) showErrorModal(errorModal, result.error);
    return { handled: true, ok: false };
  }
  applyEventStatus(statusEl, { ok: true, msg: "copied puzzle to clipboard" });
  return { handled: true, ok: true };
}

/** Edit → Paste: clipboard `readText` → wasm `importPuzzle` only; fail closed on read/import errors. */
export async function handlePastePuzzle(
  game,
  session,
  statusEl,
  errorModal,
  { clipboard } = {},
) {
  if (!session.legend[LEGEND_WIRE_PASTE]) return { handled: false };
  const read = await readClipboardText({ clipboard });
  if (!read.ok) {
    if (read.error) showErrorModal(errorModal, read.error);
    return { handled: true, ok: false };
  }
  const result = importPuzzle(game, read.text);
  if (!result.ok) {
    if (result.error) showErrorModal(errorModal, result.error);
    return { handled: true, ok: false };
  }
  session.fileHandle = null;
  session.boundFilename = null;
  session.state = result.state;
  session.legend = result.legend;
  session.config = result.config;
  applyEventStatus(statusEl, { ok: true, msg: result.msg ?? "pasted puzzle from clipboard" });
  return { handled: true, ok: true };
}

export function handleDeselect(selection) {
  if (!selection.getSelection()) return { handled: false };
  selection.deselect();
  return { handled: true };
}

function execPayloadForEditAction(action, boardEl, selection) {
  if (action !== "hint") return { action };
  const sel = readSelection(boardEl, selection);
  if (!sel) return { action: "hint" };
  return { action: "hint", row: sel.row, col: sel.col };
}

export function handleEditAction(
  action,
  game,
  boardEl,
  selection,
  statusEl,
  errorModal,
  session,
  createElement,
) {
  if (action === "undo" && !session.legend.undo) return { handled: false };
  if (action === "redo" && !session.legend.redo) return { handled: false };
  if (action === "solve" && !session.legend.solve) return { handled: false };

  const result = game.exec(execPayloadForEditAction(action, boardEl, selection));
  if (!result.ok) {
    applyExecResult(statusEl, errorModal, result);
    return { handled: true };
  }

  // Hint is display-only — skip re-render (board unchanged).
  if (action === "hint") {
    applyHintExecStatus(statusEl, errorModal, result);
    session.state = result.state;
    session.legend = game.getLegend();
    return { handled: true, legend: session.legend };
  }

  session.state = result.state;

  session.legend = game.getLegend();
  applySuccessfulExec(boardEl, selection, statusEl, result, createElement);
  return { handled: true, legend: session.legend };
}

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
    clipboard = globalThis.navigator?.clipboard,
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

  const run = (action) => {
    const outcome = handleEditAction(
      action,
      game,
      boardEl,
      selection,
      statusEl,
      errorModal,
      session,
      createElement,
    );
    if (outcome.handled) syncEdit();
    return outcome;
  };

  const runDeselect = () => {
    const outcome = handleDeselect(selection);
    if (outcome.handled) syncEdit();
    return outcome;
  };

  undoBtn.addEventListener("click", () => run("undo"));
  redoBtn.addEventListener("click", () => run("redo"));
  deselectBtn?.addEventListener("click", () => runDeselect());
  copyBtn?.addEventListener("click", (event) => {
    event?.stopPropagation?.();
    void handleCopyPuzzle(game, session, statusEl, errorModal, {
      clipboard,
      doc: root.ownerDocument ?? globalThis.document,
    });
  });
  pasteBtn?.addEventListener("click", (event) => {
    event?.stopPropagation?.();
    void handlePastePuzzle(game, session, statusEl, errorModal, { clipboard }).then((outcome) => {
      if (!outcome.handled || !outcome.ok) return;
      renderBoard(boardEl, session.state, createElement);
      selection.deselect();
      syncEdit();
    });
  });
  if (typeof root.querySelector === "function") {
    const solveBtn = root.querySelector("#edit-solve");
    if (solveBtn) solveBtn.addEventListener("click", () => run("solve"));
    const hintBtn = root.querySelector("#edit-hint");
    if (hintBtn) hintBtn.addEventListener("click", () => run("hint"));
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
    if (action === "undo" && !session.legend.undo) return;
    if (action === "redo" && !session.legend.redo) return;
    const outcome = run(action);
    if (!outcome.handled) return;
    event.preventDefault();
  });

  return { sync: syncEdit, run, runDeselect };
}
