// app_wire.js — DOM wiring for the web shell once startup/session are ready.

import * as androidSteps from "./flows/android_steps.js";
import * as promptDialogMod from "./dialogs/prompt_dialog.js";
import * as webSteps from "./flows/web_steps.js";
import * as sessionMod from "./flows/session.js";
import * as statusBarMod from "./status_bar.js";
import * as board from "./board.js";
import * as playPad from "./play_pad.js";
import * as menu from "./menus/menu.js";
import * as menuBarMod from "./menus/menu_bar.js";
import * as theme from "./menus/theme.js";
import * as fileMenu from "./menus/file_menu.js";
import * as region from "./menus/region.js";
import * as marks from "./menus/marks.js";
import * as help from "./menus/help.js";
import * as settings from "./menus/settings.js";
import * as shortcuts from "./menus/shortcuts.js";

/**
 * @typedef {import("./types").GameApi} GameApi
 * @typedef {import("./types").WebSession} WebSession
 * @typedef {import("./types").GeneratingModal} GeneratingModal
 * @typedef {import("./types").GenWorker} GenWorker
 * @typedef {import("./types").PromptDialog} PromptDialog
 * @typedef {import("./types").FlowHandlers} FlowHandlers
 * @typedef {import("./types").StepsOptions} StepsOptions
 */

/**
 * The platform's handler for every core step: Android's when the WebView has the file bridge, else the browser's.
 * @param {GameApi} game
 * @param {WebSession} session
 * @param {StepsOptions} options
 * @returns {FlowHandlers}
 */
export function platformSteps(game, session, options) {
  const bridge = (options.win ?? globalThis).AndroidFileBridge;
  return bridge ? androidSteps.androidSteps(game, session, bridge, options) : webSteps.webSteps(game, session, options);
}

function settingsModalFromDom(root = document) {
  return {
    el: root.getElementById("settings-modal"),
    checkbox: root.getElementById("settings-warn-solvability"),
    difficultySelect: root.getElementById("settings-difficulty"),
    logLevelSelect: root.getElementById("settings-log-level"),
    autoRestoreCheckbox: root.getElementById("settings-auto-restore"),
    autoNewCheckbox: root.getElementById("settings-auto-new"),
    autoSaveCheckbox: root.getElementById("settings-auto-save"),
    dismissEl: root.getElementById("settings-modal-dismiss"),
  };
}

/**
 * @typedef {Object} WireSudokuAppOptions
 * @property {GameApi} game
 * @property {WebSession} session
 * @property {GeneratingModal} generatingModal
 * @property {GenWorker} genWorker
 * @property {Document} [root]
 * @property {Window & typeof globalThis} [win]
 */

/**
 * @typedef {Object} WiredSudokuApp
 * @property {(step: { text: string | null }) => void} showGame Redraw board, menus and status from the session.
 * @property {FlowHandlers} steps The platform's step handlers every flow runs with.
 */

/**
 * Wire all DOM-facing web shell modules around one shared session object.
 * @param {WireSudokuAppOptions} options
 * @returns {WiredSudokuApp}
 */
export function wireSudokuApp({
  game,
  session,
  generatingModal,
  genWorker,
  root = document,
  win = globalThis,
}) {
  const statusBar = root.getElementById("status-bar");
  const boardEl = root.getElementById("board");
  const playPadEl = root.getElementById("play-pad");
  const padControls = playPad.collectPlayPadControls(playPadEl);
  const menuControls = menuBarMod.collectMenuBarControls(root);

  const promptDialog = createPromptDialog(root, win);

  const aboutModal = {
    el: root.getElementById("about-modal"),
    titleEl: root.getElementById("about-modal-title"),
    summaryEl: root.getElementById("about-summary"),
    copyrightEl: root.getElementById("about-copyright"),
  };
  help.wireAboutModal(aboutModal.el, root.getElementById("about-modal-dismiss"));
  const settingsModal = settingsModalFromDom(root);

  board.setStatus(statusBar, "");
  statusBarMod.wireStatusOverflow(statusBar, win);

  const menuBar = menuBarMod.wireMenuBar(menuControls, session, root);
  let selection;
  const syncPad = () => {
    const sel = selection?.getSelection();
    const cell = sel ? session.state?.cells?.[board.cellIndex(sel.row, sel.col)] ?? null : null;
    playPad.syncPlayPad(padControls, session.legend, session.config, cell, session.state?.pencil_mode === true);
  };
  /** Menu bar and pad show the same legend and config, so they always redraw together. */
  const syncControls = () => {
    menuBar.sync();
    syncPad();
  };
  syncPad();

  const steps = platformSteps(game, session, { win, statusEl: statusBar, promptDialog, generatingModal, genWorker });

  const themeMenu = theme.wireThemeMenu(menuControls, game, session, {
    root,
    onChange: syncControls,
    steps,
  });

  let editMenu;
  selection = board.wireSelection(boardEl, {
    regionEnabled: () => session.config.show_region === true,
    onSelect: () => {
      syncPad();
      editMenu?.sync();
    },
  });
  syncPad();

  const regionMenu = region.wireRegionMenu(
    menuControls,
    game,
    session,
    boardEl,
    () => selection.getSelection(),
    { onChange: syncControls, steps },
  );
  const marksMenu = marks.wireMarks(menuControls, game, session, boardEl, selection, { onChange: syncControls, steps });
  const difficultyDialog = {
    el: root.getElementById("new-difficulty-modal"),
    buttons: [...root.querySelectorAll(".new-difficulty-btn")].map((btn) => ({
      label: btn.textContent,
      difficulty: Number(btn.dataset.difficulty),
      el: btn,
    })),
    cancelBtn: root.getElementById("new-difficulty-cancel"),
  };

  fileMenu.wireFileMenu(menuControls, game, boardEl, selection, statusBar, session, menuBar, {
    difficultyDialog,
    onViewRefresh: () => {
      themeMenu.sync();
      regionMenu.sync();
      marksMenu.sync();
      syncPad();
    },
    steps,
  });

  editMenu = menu.wireEditMenu(
    menuControls.undo,
    menuControls.redo,
    menuControls.deselect,
    game,
    boardEl,
    selection,
    session,
    undefined,
    root,
    {
      syncLegend: syncControls,
      copyBtn: menuControls.copy,
      pasteBtn: menuControls.paste,
      closeMenus: () => menuBar.closeAll?.(),
      steps,
    },
  );
  playPad.wirePlayPad(padControls, {
    runEdit: editMenu.run,
    toggleRegion: regionMenu.toggle,
    togglePencilMode: marksMenu.togglePencilMode,
  });

  board.wirePlayLoop(boardEl, game, selection, session, {
    onLegendChange: syncControls,
    playPadEl,
    steps,
  });
  help.wireHelpAbout(menuControls.about, game, aboutModal);
  settings.wireSettingsMenu(menuControls.settings, game, session, settingsModal, {
    closeMenus: () => menuBar.closeAll?.(),
    steps,
  });

  shortcuts.wireShortcuts(root, win.navigator);

  if (win.matchMedia?.("(pointer: fine)")?.matches === true) {
    board.getPlayGrid(boardEl).focus();
  }

  return {
    steps,
    showGame: (step) => {
      board.renderBoard(boardEl, session.state);
      selection.deselect();
      syncControls();
      editMenu.sync();
      themeMenu.sync();
      regionMenu.sync();
      marksMenu.sync();
      statusBarMod.showStatusText(statusBar, step.text);
      sessionMod.syncCurrentFileLabels(session, root);
    },
  };
}

/**
 * Wire the shared prompt dialog. On Android, Back dismisses an open prompt: the page tells the
 * bridge when one opens or closes, and the activity calls `__sudokuDismissPrompt` on Back.
 * @param {Document} root
 * @param {Window & typeof globalThis} win
 * @returns {PromptDialog}
 */
function createPromptDialog(root, win) {
  const bridge = win.__SudokuAndroidBridge;
  const dialog = promptDialogMod.wirePromptDialog({
    el: root.getElementById("prompt-dialog"),
    badgeEl: root.getElementById("prompt-dialog-badge"),
    titleEl: root.getElementById("prompt-dialog-title"),
    textEl: root.getElementById("prompt-dialog-text"),
    buttonsEl: root.getElementById("prompt-dialog-buttons"),
    doc: root,
    onOpenChange: bridge ? (open) => bridge.setPromptOpen(open) : undefined,
  });
  win.__sudokuDismissPrompt = dialog.dismiss;
  return dialog;
}
