// app_wire.js — DOM wiring for the web shell once startup/session are ready.

import {
  applySessionOutcomeStatus,
  persistHostSettings,
  showErrorModal,
  wireErrorModal,
} from "./shell.js";
import { getPlayGrid, setStatus, wireSelection, wirePlayLoop } from "./board.js";
import { wireEditMenu } from "./menu.js";
import { collectMenuBarControls, wireMenuBar } from "./menu_bar.js";
import { wireThemeMenu } from "./theme.js";
import { wireFileMenu } from "./file_menu.js";
import { wireRegionMenu } from "./region.js";
import { wireHelpAbout, wireAboutModal } from "./help.js";
import { wireSettingsMenu } from "./settings.js";

function isTouchPlayPadPlatform(win = globalThis) {
  if (!win || !win.navigator) return false;
  return (
    !!win.__SudokuAndroidBridge ||
    !!win.AndroidFileBridge ||
    /\bwv\b/.test(win.navigator.userAgent) ||
    /Android/i.test(win.navigator.userAgent)
  );
}

function installReplaceConfirm(root = document, win = globalThis) {
  const replaceConfirmModal = {
    el: root.getElementById("replace-confirm-modal"),
    msgEl: root.getElementById("replace-confirm-msg"),
    cancelBtn: root.getElementById("replace-confirm-cancel"),
    okBtn: root.getElementById("replace-confirm-ok"),
  };
  win.__sudokuConfirmReplace = (message) =>
    new Promise((resolve) => {
      replaceConfirmModal.msgEl.textContent = message;
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

export function wireSudokuApp({
  game,
  session,
  ready,
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

  if ((ready.kind === "new" || ready.kind === "empty") && ready.msg) {
    applySessionOutcomeStatus(session, statusBar, { msg: ready.msg });
  } else {
    setStatus(statusBar, "");
  }

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

  const persistViewSettings = async (cfg) => {
    try {
      await persistHostSettings(cfg);
    } catch (err) {
      showErrorModal(errorModal, err?.message ?? String(err));
    }
  };

  const themeMenu = wireThemeMenu(menuControls, game, session, {
    root,
    statusEl: statusBar,
    onChange: () => menuBar.sync(),
    onPersist: persistViewSettings,
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
    { onChange: () => menuBar.sync(), onPersist: persistViewSettings, statusEl: statusBar },
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
    onPersist: persistViewSettings,
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
    },
  );

  wirePlayLoop(boardEl, game, selection, statusBar, errorModal, session, {
    onLegendChange: () => menuBar.sync(),
    playPadEl,
  });
  wireHelpAbout(menuControls.about, game, aboutModal);
  wireSettingsMenu(menuControls.settings, game, session, settingsModal, {
    closeMenus: () => menuBar.closeAll?.(),
    onPersist: persistViewSettings,
  });

  if (win.matchMedia?.("(pointer: fine)")?.matches === true) {
    getPlayGrid(boardEl).focus();
  }
}

export function createErrorModal(root = document) {
  return wireErrorModal(
    root.getElementById("error-modal"),
    root.getElementById("error-modal-msg"),
    root.getElementById("error-modal-dismiss"),
  );
}
