// file_menu.js — File menu: each item runs its command through core with the platform's step handlers.

import * as statusBar from "../status_bar.js";
import * as sessionMod from "../flows/session.js";
import * as settings from "./settings.js";
import * as board from "../board.js";
import * as menuBarMod from "./menu_bar.js";
import * as stepRunner from "../flows/step_runner.js";

/** @typedef {import("../types").GameApi} GameApi */
/** @typedef {import("../types").FileMenuControls} FileMenuControls */
/** @typedef {import("../types").FileMenuWiring} FileMenuWiring */
/** @typedef {import("../types").MenuBar} MenuBar */
/** @typedef {import("../types").BoardSelection} BoardSelection */
/** @typedef {import("../types").WebSession} WebSession */
/** @typedef {import("../types").FlowHandlers} FlowHandlers */

const TOGGLE_AUTO_SAVE = "toggle_auto_save";
const NEW_COMMAND = "new";
const OPEN_COMMAND = "open";
const IMPORT_COMMAND = "import";
const SAVE_COMMAND = "save";
const SAVE_AS_COMMAND = "save_as";
const EXPORT_COMMAND = "export";

/** View-only refresh used after session has already been updated through shell helpers. */
export function refreshSessionView(
  boardEl,
  selection,
  menuBar,
  state,
  createElement,
  onViewRefresh,
) {
  board.renderBoard(boardEl, state, createElement);
  selection.deselect();
  menuBar.sync();
  onViewRefresh?.();
}

/** Difficulty choices for the New sub-dialog — labels + the difficulty value the game init accepts. */
export const DIFFICULTIES = [
  { label: "Easy", difficulty: 1 },
  { label: "Medium", difficulty: 2 },
  { label: "Hard", difficulty: 3 },
];

/** Difficulty sub-dialog for New — picking a level closes the dialog and drives generation. */
export function wireDifficultyDialog(dialog, onChoose) {
  for (const button of dialog.buttons) {
    button.el.addEventListener("click", () => {
      dialog.el.hidden = true;
      return (async () => {
        await statusBar.waitForStatusPaint();
        try {
          await onChoose(button.difficulty);
        } catch (err) {
          console.error("New game failed:", err);
        }
      })();
    });
  }
  dialog.cancelBtn?.addEventListener("click", () => {
    dialog.el.hidden = true;
  });
  return {
    open() {
      dialog.el.hidden = false;
    },
    close() {
      dialog.el.hidden = true;
    },
  };
}

/**
 * Run a File command through core; the view follows the game core shows.
 * @param {FileMenuWiring} wiring
 */
function runFileCommand(wiring, action) {
  const { game, session, boardEl, selection, menuBar, createElement, onViewRefresh, steps } = wiring;
  return stepRunner.runCommand(game, action, steps, () =>
    refreshSessionView(boardEl, selection, menuBar, session.state, createElement, onViewRefresh));
}

/** New opens the difficulty chooser; generation starts only after a pick. */
/** @param {FileMenuWiring} wiring */
function wireNew(button, wiring, difficultyDialog) {
  const { session, menuBar, statusEl } = wiring;
  const startNewGame = (difficulty) =>
    runFileCommand(wiring, { action: NEW_COMMAND, difficulty: settings.difficultyName({ difficulty }) });
  const newDialog = wireDifficultyDialog(difficultyDialog, startNewGame);
  button?.addEventListener("click", () => {
    if (!session.legend.new) return;
    menuBar.closeAll?.();
    statusBar.clearEventStatus(statusEl);
    newDialog.open();
  });
}

/** Open and Import: core asks the platform for the file and loads it. */
/** @param {FileMenuWiring} wiring */
function wireLoad(button, wiring, legendKey, command) {
  button?.addEventListener("click", async () => {
    if (!wiring.session.legend[legendKey]) return;
    statusBar.clearEventStatus(wiring.statusEl);
    await runFileCommand(wiring, { action: command });
  });
}

/** Save writes the working file; Save As chooses a fresh target. */
/** @param {FileMenuWiring} wiring */
function wireSave(button, wiring, legendKey, command) {
  button?.addEventListener("click", async () => {
    if (!wiring.session.legend[legendKey]) return;
    await runFileCommand(wiring, { action: command });
  });
}

/** Auto Save toggles through core, then the menu re-syncs its check mark. */
/** @param {FileMenuWiring} wiring */
function wireAutoSave(button, wiring) {
  button?.addEventListener("click", async () => {
    await stepRunner.runCommand(wiring.game, { action: TOGGLE_AUTO_SAVE }, wiring.steps, () => {
      wiring.menuBar.sync();
      wiring.onViewRefresh?.();
    });
  });
}

/** Export runs through core, which names the file. */
/** @param {FileMenuWiring} wiring */
function wireExport(button, wiring) {
  button?.addEventListener("click", async () => {
    if (!wiring.session.legend[menuBarMod.LEGEND_WIRE_EXPORT]) return;
    await stepRunner.runCommand(wiring.game, { action: EXPORT_COMMAND }, wiring.steps);
  });
}

/**
 * Wire every File item present in `controls`.
 * @param {FileMenuControls} controls
 * @param {GameApi} game
 * @param {HTMLElement} boardEl
 * @param {BoardSelection} selection
 * @param {HTMLElement} statusEl
 * @param {WebSession} session
 * @param {MenuBar} menuBar
 * @param {{ steps: FlowHandlers, difficultyDialog?: unknown, createElement?: (tag: string) => HTMLElement, onViewRefresh?: () => void }} options
 */
export function wireFileMenu(
  controls,
  game,
  boardEl,
  selection,
  statusEl,
  session,
  menuBar,
  { steps, difficultyDialog, createElement, onViewRefresh },
) {
  /** @type {FileMenuWiring} */
  const wiring = { game, boardEl, selection, statusEl, session, menuBar, createElement, onViewRefresh, steps };

  wireNew(controls.new, wiring, difficultyDialog);
  wireLoad(controls.open, wiring, menuBarMod.LEGEND_WIRE_OPEN, OPEN_COMMAND);
  wireLoad(controls.import, wiring, menuBarMod.LEGEND_WIRE_IMPORT, IMPORT_COMMAND);
  wireSave(controls.save, wiring, menuBarMod.LEGEND_WIRE_SAVE, SAVE_COMMAND);
  wireSave(controls.saveAs, wiring, menuBarMod.LEGEND_WIRE_SAVE_AS, SAVE_AS_COMMAND);
  wireAutoSave(controls.autoSave, wiring);
  wireExport(controls.export, wiring);

  sessionMod.syncCurrentFileLabels(session);
}
