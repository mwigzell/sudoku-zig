// app_wire.js — DOM wiring for the web shell once startup/session are ready.

import * as androidSteps from "./flows/android_steps.js";
import * as errorModalMod from "./dialogs/error_modal.js";
import * as webSteps from "./flows/web_steps.js";
import * as sessionMod from "./flows/session.js";
import * as statusBarMod from "./status_bar.js";
import * as board from "./board.js";
import * as menu from "./menus/menu.js";
import * as menuBarMod from "./menus/menu_bar.js";
import * as theme from "./menus/theme.js";
import * as fileMenu from "./menus/file_menu.js";
import * as region from "./menus/region.js";
import * as help from "./menus/help.js";
import * as settings from "./menus/settings.js";

/**
 * @typedef {import("./types").GameApi} GameApi
 * @typedef {import("./types").WebSession} WebSession
 * @typedef {import("./types").GeneratingModal} GeneratingModal
 * @typedef {import("./types").GenWorker} GenWorker
 * @typedef {import("./types").ErrorModal} ErrorModal
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

function isTouchPlayPadPlatform(win = globalThis) {
  if (!win || !win.navigator) return false;
  return (
    !!win.__SudokuAndroidBridge ||
    !!win.AndroidFileBridge ||
    /\bwv\b/.test(win.navigator.userAgent) ||
    /Android/i.test(win.navigator.userAgent)
  );
}

/** One two-button web dialog for every yes/no question, so all prompts share one look. */
function installReplaceConfirm(root = document, win = globalThis) {
  const replaceConfirmModal = {
    el: root.getElementById("replace-confirm-modal"),
    titleEl: root.getElementById("replace-confirm-title"),
    msgEl: root.getElementById("replace-confirm-msg"),
    cancelBtn: root.getElementById("replace-confirm-cancel"),
    okBtn: root.getElementById("replace-confirm-ok"),
  };
  win.__sudokuChoose = (message, { title, okLabel, cancelLabel }) =>
    new Promise((resolve) => {
      replaceConfirmModal.titleEl.textContent = title;
      replaceConfirmModal.msgEl.textContent = message;
      replaceConfirmModal.okBtn.textContent = okLabel;
      replaceConfirmModal.cancelBtn.textContent = cancelLabel;
      replaceConfirmModal.el.hidden = false;
      const cleanup = () => {
        replaceConfirmModal.okBtn.removeEventListener("click", onOk);
        replaceConfirmModal.cancelBtn.removeEventListener("click", onCancel);
      };
      const onOk = () => {
        cleanup();
        replaceConfirmModal.el.hidden = true;
        resolve(true);
      };
      const onCancel = () => {
        cleanup();
        replaceConfirmModal.el.hidden = true;
        resolve(false);
      };
      replaceConfirmModal.okBtn.addEventListener("click", onOk);
      replaceConfirmModal.cancelBtn.addEventListener("click", onCancel);
    });
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
 * @property {ErrorModal} errorModal
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
  errorModal,
  root = document,
  win = globalThis,
}) {
  const statusBar = root.getElementById("status-bar");
  const boardEl = root.getElementById("board");
  const playPadEl = root.getElementById("play-pad");
  const useTouchPlayPad = isTouchPlayPadPlatform(win);
  const menuControls = menuBarMod.collectMenuBarControls(root);

  installReplaceConfirm(root, win);

  const aboutModal = {
    el: root.getElementById("about-modal"),
    titleEl: root.getElementById("about-modal-title"),
    summaryEl: root.getElementById("about-summary"),
    copyrightEl: root.getElementById("about-copyright"),
  };
  help.wireAboutModal(aboutModal.el, root.getElementById("about-modal-dismiss"));
  const settingsModal = settingsModalFromDom(root);

  board.setStatus(statusBar, "");

  const menuBar = menuBarMod.wireMenuBar(menuControls, session, root);
  const syncPlayPadVisibility = (sel) => {
    if (!playPadEl) return;
    if (!useTouchPlayPad) {
      playPadEl.hidden = true;
      return;
    }
    playPadEl.hidden = sel == null;
  };
  syncPlayPadVisibility(null);

  const steps = platformSteps(game, session, { win, statusEl: statusBar, errorModal, generatingModal, genWorker });

  const themeMenu = theme.wireThemeMenu(menuControls, game, session, {
    root,
    onChange: () => menuBar.sync(),
    steps,
  });

  let editMenu;
  const selection = board.wireSelection(boardEl, {
    regionEnabled: () => session.config.show_region === true,
    onSelect: (sel) => {
      syncPlayPadVisibility(sel);
      editMenu?.sync();
    },
  });
  syncPlayPadVisibility(selection.getSelection());

  const regionMenu = region.wireRegionMenu(
    menuControls,
    game,
    session,
    boardEl,
    () => selection.getSelection(),
    { onChange: () => menuBar.sync(), steps },
  );
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
      syncLegend: () => menuBar.sync(),
      copyBtn: menuControls.copy,
      pasteBtn: menuControls.paste,
      closeMenus: () => menuBar.closeAll?.(),
      steps,
    },
  );

  board.wirePlayLoop(boardEl, game, selection, session, {
    onLegendChange: () => menuBar.sync(),
    playPadEl,
    steps,
  });
  help.wireHelpAbout(menuControls.about, game, aboutModal);
  settings.wireSettingsMenu(menuControls.settings, game, session, settingsModal, {
    closeMenus: () => menuBar.closeAll?.(),
    steps,
  });

  if (win.matchMedia?.("(pointer: fine)")?.matches === true) {
    board.getPlayGrid(boardEl).focus();
  }

  return {
    steps,
    showGame: (step) => {
      board.renderBoard(boardEl, session.state);
      selection.deselect();
      menuBar.sync();
      editMenu.sync();
      themeMenu.sync();
      regionMenu.sync();
      statusBarMod.showStatusText(statusBar, step.text);
      sessionMod.syncCurrentFileLabels(session, root);
    },
  };
}

/**
 * Resolve and wire the shared blocking error modal controls from DOM.
 * @param {Document} root
 * @returns {ErrorModal}
 */
export function createErrorModal(root = document) {
  return errorModalMod.wireErrorModal(
    root.getElementById("error-modal"),
    root.getElementById("error-modal-msg"),
    root.getElementById("error-modal-dismiss"),
  );
}
