// menu.js — Edit menu: undo/redo via wasm exec, legend-driven enablement (#40).

import { applyEventStatus, applyExecResult } from "./shell.js";
import { applySuccessfulExec } from "./board.js";

/** Mirror legend.undo / legend.redo onto menu controls. */
export function syncEditMenu(legend, undoBtn, redoBtn) {
  undoBtn.disabled = !legend.undo;
  redoBtn.disabled = !legend.redo;
}

export function parseEditShortcut(event) {
  if (!event.ctrlKey || event.altKey) return null;
  if (event.key === "z" && !event.shiftKey) return "undo";
  if (event.key === "z" && event.shiftKey) return "redo";
  if (event.key === "Z" && event.shiftKey) return "redo";
  return null;
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
  game,
  boardEl,
  selection,
  statusEl,
  errorModal,
  session,
  createElement,
  root = document,
) {
  const sync = () => syncEditMenu(session.legend, undoBtn, redoBtn);
  sync();

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
    if (outcome.handled) sync();
    return outcome;
  };

  undoBtn.addEventListener("click", () => run("undo"));
  redoBtn.addEventListener("click", () => run("redo"));

  root.addEventListener("keydown", (event) => {
    const action = parseEditShortcut(event);
    if (!action) return;
    if (action === "undo" && !session.legend.undo) return;
    if (action === "redo" && !session.legend.redo) return;
    const outcome = run(action);
    if (!outcome.handled) return;
    event.preventDefault();
  });

  return { sync, run };
}
