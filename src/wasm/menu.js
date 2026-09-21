// menu.js — Edit menu: undo/redo/solve/deselect (web only; native has no cell selection).

import { applyEventStatus, applyExecResult } from "./shell.js";
import { applySuccessfulExec } from "./board.js";

import { syncMenuBar } from "./menu_bar.js";

/** Mirror legend flags and deselect enablement (active only when a cell is selected). */
export function syncEditMenu(legend, controls, selection) {
  syncMenuBar(legend, controls);
  if (controls.deselect) {
    controls.deselect.disabled = selection?.getSelection?.() == null;
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

export function handleDeselect(selection) {
  if (!selection.getSelection()) return { handled: false };
  selection.deselect();
  return { handled: true };
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

  const result = game.exec({ action });
  if (!result.ok) {
    applyExecResult(statusEl, errorModal, result);
    return { handled: true };
  }

  applySuccessfulExec(boardEl, selection, statusEl, result, createElement);
  session.state = result.state;
  session.legend = game.getLegend();
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
  { syncLegend } = {},
) {
  const controls = { undo: undoBtn, redo: redoBtn, deselect: deselectBtn };

  const syncEdit = () => {
    if (syncLegend) syncLegend();
    syncEditMenu(session.legend, controls, selection);
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
  if (typeof root.querySelector === "function") {
    const solveBtn = root.querySelector("#edit-solve");
    if (solveBtn) solveBtn.addEventListener("click", () => run("solve"));
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
