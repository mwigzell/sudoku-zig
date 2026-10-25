// menu.js — Edit menu: undo/redo/solve/deselect (web only; native has no cell selection).

import {
  applyEventStatus,
  applySessionOutcome,
  applyHintExecStatus,
  applyExecResult,
  applyLoadedSessionOutcome,
  showErrorModal,
  startAutoSavePolicy,
  WRITE_CONTEXT_EVENT_PASTE_SUCCESS,
  startCopyPuzzleOnClick,
  readClipboardText,
  importPuzzle,
} from "./shell.js";
import { LEGEND_WIRE_COPY, LEGEND_WIRE_PASTE } from "./menu_bar.js";
import { applySuccessfulExec, readSelection, renderBoard } from "./board.js";

import { syncMenuBar } from "./menu_bar.js";

/** @typedef {import("./types").GameApi} GameApi */

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

/** Edit → Copy: wasm `exportPuzzle` bytes only; clipboard denied leaves board intact. */
/** @param {GameApi} game */
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
/** @param {GameApi} game */
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
  const finalized = await applyLoadedSessionOutcome(session, statusEl, result, {
    writeContextEventName: WRITE_CONTEXT_EVENT_PASTE_SUCCESS,
    fileHandle: null,
    boundFilename: null,
    msg: result.msg ?? "pasted puzzle from clipboard",
  });
  if (!finalized.ok) {
    if (finalized.error) showErrorModal(errorModal, finalized.error);
    return { handled: true, ok: false };
  }
  return { handled: true, ok: true };
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

/** Core edit dispatcher: gate by legend, execute command, update session/render, trigger autosave. */
/** @param {GameApi} game */
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

  // Edit phase 1: execute action payload against engine.
  const result = game.exec(execPayloadForEditAction(action, boardEl, selection));
  if (!result.ok) {
    // Edit phase 2a: failure path uses common exec error routing.
    applyExecResult(statusEl, errorModal, result);
    return { handled: true };
  }

  // Hint is display-only — skip re-render (board unchanged).
  if (action === "hint") {
    // Edit phase 2b: hint success updates status/legend only.
    applyHintExecStatus(statusEl, errorModal, result);
    applySessionOutcome(session, {
      state: result.state,
      legend: game.getLegend(),
    });
    startAutoSavePolicy(game, session, action, {
      onError: (saved) => applyExecResult(statusEl, errorModal, saved),
    });
    return { handled: true, legend: session.legend };
  }

  // Edit phase 3: board-mutating success path (render + session outcome + autosave).
  applySuccessfulExec(boardEl, selection, statusEl, result, createElement, {
    session,
    legend: game.getLegend(),
  });
  startAutoSavePolicy(game, session, action, {
    onError: (saved) => applyExecResult(statusEl, errorModal, saved),
  });
  return { handled: true, legend: session.legend };
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
    void handlePastePuzzle(game, session, statusEl, errorModal, { clipboard }).then((outcome) => {
      if (!outcome.handled || !outcome.ok) return;
      startAutoSavePolicy(game, session, "paste", {
        onError: (saved) => applyExecResult(statusEl, errorModal, saved),
      });
      renderBoard(boardEl, session.state, createElement);
      selection.deselect();
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
