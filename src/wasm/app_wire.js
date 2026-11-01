// app_wire.js — DOM wiring for the web shell once startup/session are ready.

import {
  applyEventStatus,
  commandHandlers,
  showErrorModal,
  syncCurrentFileLabels,
  wireErrorModal,
} from "./shell.js";
import { getPlayGrid, renderBoard, setStatus, wireSelection, wirePlayLoop } from "./board.js";
import { wireEditMenu } from "./menu.js";
import { collectMenuBarControls, wireMenuBar } from "./menu_bar.js";
import { wireThemeMenu } from "./theme.js";
import { wireFileMenu } from "./file_menu.js";
import { wireRegionMenu } from "./region.js";
import { wireHelpAbout, wireAboutModal } from "./help.js";
import { wireSettingsMenu } from "./settings.js";

/**
 * @typedef {import("./types").GameApi} GameApi
 * @typedef {import("./types").WebSession} WebSession
 * @typedef {import("./types").GeneratingModal} GeneratingModal
 * @typedef {import("./types").GenWorker} GenWorker
 * @typedef {import("./types").ErrorModal} ErrorModal
 */

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
  const menuControls = collectMenuBarControls(root);

  installReplaceConfirm(root, win);

  const aboutModal = {
    el: root.getElementById("about-modal"),
    titleEl: root.getElementById("about-modal-title"),
    summaryEl: root.getElementById("about-summary"),
    copyrightEl: root.getElementById("about-copyright"),
  };
  wireAboutModal(aboutModal.el, root.getElementById("about-modal-dismiss"));
  const settingsModal = settingsModalFromDom(root);

  setStatus(statusBar, "");

  const menuBar = wireMenuBar(menuControls, session, root);
  const syncPlayPadVisibility = (sel) => {
    if (!playPadEl) return;
    if (!useTouchPlayPad) {
      playPadEl.hidden = true;
      return;
    }
    playPadEl.hidden = sel == null;
  };
  syncPlayPadVisibility(null);

  const commandFlow = commandHandlers(game, session, {
    win,
    statusEl: statusBar,
    onError: (failed) => showErrorModal(errorModal, failed.error),
  });

  const themeMenu = wireThemeMenu(menuControls, game, session, {
    root,
    onChange: () => menuBar.sync(),
    commandFlow,
  });

  let editMenu;
  const selection = wireSelection(boardEl, {
    regionEnabled: () => session.config.show_region === true,
    onSelect: (sel) => {
      syncPlayPadVisibility(sel);
      editMenu?.sync();
    },
  });
  syncPlayPadVisibility(selection.getSelection());

  const regionMenu = wireRegionMenu(
    menuControls,
    game,
    session,
    boardEl,
    () => selection.getSelection(),
    { onChange: () => menuBar.sync(), commandFlow },
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

  wireFileMenu(menuControls, game, boardEl, selection, statusBar, errorModal, session, menuBar, {
    difficultyDialog,
    generatingModal,
    genWorker,
    onViewRefresh: () => {
      themeMenu.sync();
      regionMenu.sync();
    },
    commandFlow,
  });

  editMenu = wireEditMenu(
    menuControls.undo,
    menuControls.redo,
    menuControls.deselect,
    game,
    boardEl,
    selection,
    statusBar,
    errorModal,
    session,
    undefined,
    root,
    {
      syncLegend: () => menuBar.sync(),
      copyBtn: menuControls.copy,
      pasteBtn: menuControls.paste,
      closeMenus: () => menuBar.closeAll?.(),
      commandFlow,
    },
  );

  wirePlayLoop(boardEl, game, selection, statusBar, errorModal, session, {
    onLegendChange: () => menuBar.sync(),
    playPadEl,
    commandFlow,
  });
  wireHelpAbout(menuControls.about, game, aboutModal);
  wireSettingsMenu(menuControls.settings, game, session, settingsModal, {
    closeMenus: () => menuBar.closeAll?.(),
    commandFlow,
  });

  if (win.matchMedia?.("(pointer: fine)")?.matches === true) {
    getPlayGrid(boardEl).focus();
  }

  return {
    showGame: (step) => {
      renderBoard(boardEl, session.state);
      selection.deselect();
      menuBar.sync();
      editMenu.sync();
      themeMenu.sync();
      regionMenu.sync();
      applyEventStatus(statusBar, { ok: true, msg: step.text ?? null });
      syncCurrentFileLabels(session, root);
    },
  };
}

/**
 * Resolve and wire the shared blocking error modal controls from DOM.
 * @param {Document} root
 * @returns {ErrorModal}
 */
export function createErrorModal(root = document) {
  return wireErrorModal(
    root.getElementById("error-modal"),
    root.getElementById("error-modal-msg"),
    root.getElementById("error-modal-dismiss"),
  );
}
