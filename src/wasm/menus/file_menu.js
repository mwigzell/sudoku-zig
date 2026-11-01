// file_menu.js — File menu: wires each item to core flows and the browser or Android file APIs.

import * as commandFlowMod from "../flows/command_flow.js";
import * as errorModalMod from "../dialogs/error_modal.js";
import * as hostApi from "../host_api.js";
import * as sessionMod from "../flows/session.js";
import * as settings from "./settings.js";
import * as statusBar from "../status_bar.js";
import * as board from "../board.js";
import * as menuBarMod from "./menu_bar.js";
import * as stepRunner from "../flows/step_runner.js";

/** @typedef {import("../types").GameApi} GameApi */
/** @typedef {import("../types").FileMenuControls} FileMenuControls */
/** @typedef {import("../types").FileMenuWiring} FileMenuWiring */
/** @typedef {import("../types").MenuBar} MenuBar */
/** @typedef {import("../types").BoardSelection} BoardSelection */
/** @typedef {import("../types").WebSession} WebSession */
/** @typedef {import("../types").ErrorModal} ErrorModal */
/** @typedef {import("../types").FlowHandlers} FlowHandlers */
/** @typedef {import("../types").AndroidFileBridge} AndroidFileBridge */
/** @typedef {import("../types").AndroidBridgeResult} AndroidBridgeResult */
/** @typedef {import("../types").WriteResult} WriteResult */

/** First-time picker location when no game file is bound yet. */
export const FILE_PICKER_START_IN = "documents";
const TOGGLE_AUTO_SAVE = "toggle_auto_save";
const NEW_COMMAND = "new";
const OPEN_COMMAND = "open";
const IMPORT_COMMAND = "import";
const SAVE_COMMAND = "save";
const SAVE_AS_COMMAND = "save_as";
const EXPORT_COMMAND = "export";
/** `pick_open` kinds: a saved game becomes the save target; puzzle text does not. */
const PICK_KIND_GAME = "game";
const PICK_KIND_PUZZLE = "puzzle";
const BRIDGE_CANCELLED = "cancelled";
/** Android bridge reason: the default visible file belongs to an earlier install. */
const BRIDGE_DEFAULT_TAKEN = "default_taken";
const BINDING_KIND_FILE_HANDLE = "file_handle";
const BINDING_KIND_ANDROID_BRIDGE = "android_bridge";
/** Android bridge capability check for Save/Save As path selection. */
/** @param {AndroidFileBridge | undefined} bridge */
function bridgeSupportsSave(bridge) {
  return bridge != null && typeof bridge.saveSudokuFile === "function";
}

/** Android bridge capability check for Open/Import picker path selection. */
/** @param {AndroidFileBridge | undefined} bridge */
function bridgeSupportsOpen(bridge) {
  return bridge != null && typeof bridge.openSudokuFile === "function";
}

/** Android bridge transport helper: binary SUD0 bytes -> base64 text payload. */
function bytesToBase64(bytes) {
  const chars = [];
  for (const b of bytes) chars.push(String.fromCharCode(b));
  return btoa(chars.join(""));
}

/** Android bridge transport helper: base64 text payload -> binary SUD0 bytes. */
function base64ToBytes(base64) {
  const text = atob(base64);
  const out = new Uint8Array(text.length);
  for (let i = 0; i < text.length; i += 1) out[i] = text.charCodeAt(i);
  return out;
}

/** Picker start location follows the bound file handle when available. */
export function filePickerStartIn(session) {
  return session?.fileHandle ?? FILE_PICKER_START_IN;
}

export const sudFilePickerTypes = [
  {
    description: "Sudoku puzzle",
    accept: { "application/octet-stream": [".sud"] },
  },
];

export const puzzleTextPickerTypes = [
  {
    description: "One-line puzzle",
    accept: { "text/plain": [".txt"] },
  },
];
export const PUZZLE_TEXT_ACCEPT = ".txt,text/plain";

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

/** Browser fallback download when no native picker/bridge save path is available. */
export function downloadBytes(bytes, filename, doc = document) {
  const url = doc.defaultView.URL.createObjectURL(
    new Blob([bytes], { type: "application/octet-stream" }),
  );
  const link = doc.createElement("a");
  link.href = url;
  link.download = filename;
  link.click();
  doc.defaultView.URL.revokeObjectURL(url);
  return { ok: true, filename };
}

/** Shared file-handle writer used by both SUD0 save and text export picker paths. */
async function writeHandle(handle, bytes) {
  const writable = await handle.createWritable();
  await writable.write(bytes);
  await writable.close();
}

function bindingForFileHandle(handle) {
  return { kind: BINDING_KIND_FILE_HANDLE, handle };
}

function bindingForAndroidBridge() {
  return { kind: BINDING_KIND_ANDROID_BRIDGE };
}

function clearBoundSnapshotWriter(session) {
  session.boundSnapshotWriter = null;
  session.boundSnapshotWriterKind = null;
  session.boundTargetExists = null;
  session.boundPickExisting = null;
  session.boundPickNew = null;
}

/**
 * @param {AndroidBridgeResult} out
 * @returns {WriteResult}
 */
function androidSaveOutcome(out) {
  if (!out || out.ok !== true) {
    if (out?.cancelled === true || out?.reason === BRIDGE_CANCELLED) return { ok: false, cancelled: true };
    return { ok: false, error: out?.error };
  }
  return typeof out.name === "string" && out.name.length > 0 ? { ok: true, name: out.name } : { ok: true };
}

/**
 * Write the bound Android file; reports `taken` when the default file belongs to an earlier install.
 * @param {AndroidFileBridge | undefined} bridge
 * @param {Uint8Array} bytes
 * @param {string} suggestedName
 * @returns {Promise<WriteResult>}
 */
async function saveToAndroidBoundTarget(bridge, bytes, suggestedName) {
  if (!bridge) return { ok: false, error: "no Android bridge" };
  const saveCurrent = bridge.saveCurrentSudokuFile;
  if (typeof saveCurrent === "function") {
    const base64 = bytesToBase64(bytes);
    const out = await saveCurrent(base64, suggestedName);
    if (out?.reason === BRIDGE_DEFAULT_TAKEN) return { ok: false, taken: { name: out.name ?? suggestedName, dir: out.dir } };
    return androidSaveOutcome(out);
  }
  const saveLegacy = bridge.saveSudokuFile;
  if (typeof saveLegacy !== "function") return { ok: false, error: "save bridge unavailable" };
  const out = await saveLegacy(bytesToBase64(bytes), suggestedName, false);
  const outcome = androidSaveOutcome(out);
  return outcome.ok ? { ok: true } : outcome;
}

function bindSnapshotWriter(session, binding, win = globalThis) {
  if (!binding) return;
  if (binding.kind === BINDING_KIND_FILE_HANDLE && binding.handle) {
    session.fileHandle = binding.handle;
    session.boundPickExisting = null;
    session.boundPickNew = null;
    session.boundSnapshotWriterKind = BINDING_KIND_FILE_HANDLE;
    session.boundTargetExists = () => true;
    session.boundSnapshotWriter = async (bytes) => {
      try {
        await writeHandle(binding.handle, bytes);
        return { ok: true };
      } catch (err) {
        session.fileHandle = null;
        clearBoundSnapshotWriter(session);
        return { ok: false, error: err?.message ?? String(err) };
      }
    };
    return;
  }
  if (binding.kind === BINDING_KIND_ANDROID_BRIDGE) {
    const bridge = win?.AndroidFileBridge;
    session.boundSnapshotWriterKind = BINDING_KIND_ANDROID_BRIDGE;
    // With no current file the bridge writes its default visible file and settles name clashes itself.
    session.boundTargetExists = () => androidCurrentTargetName(win) != null;
    session.boundSnapshotWriter = async (bytes, suggestedName) => {
      try {
        return await saveToAndroidBoundTarget(bridge, bytes, suggestedName);
      } catch (err) {
        return { ok: false, error: err?.message ?? String(err) };
      }
    };
    // Pickers for when the default file belongs to an earlier install; core decides which one runs.
    session.boundPickExisting = async (bytes) =>
      androidSaveOutcome(await bridge.saveSudokuFileToExisting(bytesToBase64(bytes)));
    session.boundPickNew = async (bytes, name) =>
      androidSaveOutcome(await bridge.saveSudokuFile(bytesToBase64(bytes), name, true));
  }
}

function androidCurrentTargetName(win = globalThis) {
  const bridge = win?.AndroidFileBridge;
  if (typeof bridge?.currentSudokuFileName !== "function") return null;
  const name = bridge.currentSudokuFileName();
  if (typeof name !== "string" || name.length === 0) return null;
  return name;
}

function primeAndroidBoundTarget(session, win = globalThis) {
  const bridge = win?.AndroidFileBridge;
  if (!bridge || typeof bridge.saveCurrentSudokuFile !== "function") return;
  bindSnapshotWriter(session, bindingForAndroidBridge(), win);
  if (typeof session.boundFilename === "string" && session.boundFilename.length > 0) return;
  const name = androidCurrentTargetName(win);
  if (name) session.boundFilename = name;
}

/**
 * After a load: a picked saved game becomes the save target; any other load drops it. Without a
 * bound file Android primes its default one.
 * @param {WebSession} session
 * @param {import("../types").PickResult | null} pickedGame
 */
export function bindLoadedGame(session, pickedGame, win = globalThis) {
  session.fileHandle = pickedGame?.handle ?? null;
  if (pickedGame?.binding) bindSnapshotWriter(session, pickedGame.binding, win);
  else clearBoundSnapshotWriter(session);
  if (typeof session.boundSnapshotWriter !== "function" && androidCurrentTargetName(win) == null) {
    primeAndroidBoundTarget(session, win);
  }
}

/** Persist SUD0 bytes through current handle, Android bridge, picker, or download fallback. */
export async function persistBytes(
  bytes,
  session,
  suggestedName,
  { saveAs = false, win = globalThis, download = downloadBytes, bridge = win.AndroidFileBridge } = {},
) {
  if (!saveAs && session.fileHandle) {
    try {
      await writeHandle(session.fileHandle, bytes);
      return { ok: true, filename: session.fileHandle.name, binding: bindingForFileHandle(session.fileHandle) };
    } catch {
      session.fileHandle = null;
    }
  }

  if (bridgeSupportsSave(bridge)) {
    try {
      const out = await bridge.saveSudokuFile(bytesToBase64(bytes), suggestedName, saveAs === true);
      if (!out || out.ok !== true) {
        if (out?.cancelled === true || out?.reason === BRIDGE_CANCELLED) return { ok: false, cancelled: true };
        return { ok: false, error: out?.error };
      }
      return { ok: true, filename: out.name ?? suggestedName, binding: bindingForAndroidBridge() };
    } catch (err) {
      return { ok: false, error: err?.message ?? String(err) };
    }
  }

  if (win.showSaveFilePicker) {
    try {
      const handle = await win.showSaveFilePicker({
        suggestedName,
        types: sudFilePickerTypes,
        startIn: filePickerStartIn(session),
      });
      await writeHandle(handle, bytes);
      session.fileHandle = handle;
      return { ok: true, filename: handle.name, binding: bindingForFileHandle(handle) };
    } catch (err) {
      if (err?.name === "AbortError") return { ok: false, cancelled: true };
      throw err;
    }
  }

  download(bytes, suggestedName);
  return { ok: true, filename: suggestedName };
}

/** Write a one-line puzzle export; does not bind the SUD0 save file handle. */
export async function persistPuzzleText(
  bytes,
  session,
  suggestedName,
  { win = globalThis, download = downloadBytes } = {},
) {
  if (win.showSaveFilePicker) {
    try {
      const handle = await win.showSaveFilePicker({
        suggestedName,
        types: puzzleTextPickerTypes,
        startIn: filePickerStartIn(session),
      });
      await writeHandle(handle, bytes);
      return { ok: true, filename: handle.name };
    } catch (err) {
      if (err?.name === "AbortError") return { ok: false, cancelled: true };
      return { ok: false, error: err?.message ?? String(err) };
    }
  }

  download(bytes, suggestedName);
  return { ok: true, filename: suggestedName };
}

export async function pickBytes(doc = document, session = {}, { types = sudFilePickerTypes, accept = null } = {}) {
  const win = doc.defaultView;
  const bridge = win?.AndroidFileBridge;
  if (bridgeSupportsOpen(bridge)) {
    try {
      const out = await bridge.openSudokuFile();
      if (!out || out.ok !== true) {
        if (out?.cancelled === true || out?.reason === BRIDGE_CANCELLED) return { ok: false, cancelled: true };
        return { ok: false, error: out?.error };
      }
      if (typeof out.base64 !== "string" || typeof out.name !== "string") {
        return { ok: false, error: "invalid Android file payload" };
      }
      return { ok: true, bytes: base64ToBytes(out.base64), name: out.name, binding: bindingForAndroidBridge() };
    } catch (err) {
      return { ok: false, error: err?.message ?? String(err) };
    }
  }

  if (win?.showOpenFilePicker) {
    try {
      const [handle] = await win.showOpenFilePicker({
        types,
        startIn: filePickerStartIn(session),
        multiple: false,
      });
      const file = await handle.getFile();
      return {
        ok: true,
        bytes: new Uint8Array(await file.arrayBuffer()),
        name: file.name,
        handle,
        binding: bindingForFileHandle(handle),
      };
    } catch (err) {
      if (err?.name === "AbortError") return { ok: false, cancelled: true };
      throw err;
    }
  }

  return new Promise((resolve) => {
    const input = doc.createElement("input");
    input.type = "file";
    input.accept = accept ?? ".sud,application/octet-stream";
    input.addEventListener("change", async () => {
      const file = input.files?.[0];
      if (!file) {
        resolve({ ok: false, cancelled: true });
        return;
      }
      resolve({ ok: true, bytes: new Uint8Array(await file.arrayBuffer()), name: file.name });
    });
    input.click();
  });
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

/** Show a failed result's error in the error dialog. */
/** @param {FileMenuWiring} wiring */
function showFailure(wiring, result) {
  if (result.error) errorModalMod.showErrorModal(wiring.errorModal, result.error);
}

/**
 * Platform work for the core Save / Save As flow. The user's file is written by the bound
 * handle, the Android bridge, a picker or a download; the host keeps the restore copy.
 * Without a bound file the picker asks its own overwrite question, so the target is new to core.
 * @param {FileMenuWiring} wiring
 */
function saveHandlers(wiring, saveAsMode) {
  const { game, session, statusEl, download } = wiring;
  return {
    checkTarget: () =>
      !saveAsMode && (session.fileHandle != null || androidCurrentTargetName(globalThis) != null),
    ask: (step) => stepRunner.askWithDialog(step, globalThis),
    write: async (name) => {
      const result = game.serialize();
      if (!result.ok) return result;
      const saved = await persistBytes(result.bytes, session, name, { saveAs: saveAsMode, download });
      if (!saved.ok) return saved;
      session.boundFilename = saved.filename;
      bindSnapshotWriter(session, saved.binding, globalThis);
      const hosted = await hostApi.persistCurrentFileBytes(result.bytes, globalThis.fetch, saved.filename, { restoreCopy: true });
      if (!hosted.ok) return hosted;
      return { ok: true, name: saved.filename };
    },
    showStatus: (text) => {
      sessionMod.syncCurrentFileLabels(session);
      statusBar.applyEventStatus(statusEl, { ok: true, msg: text });
    },
    showError: (text) => showFailure(wiring, { ok: false, error: text }),
  };
}

/** Save / Save As: core names the target (working file, else the host default) and asks before replacing. */
/** @param {FileMenuWiring} wiring */
function runSave(wiring, saveAsMode) {
  const action = { action: saveAsMode ? SAVE_AS_COMMAND : SAVE_COMMAND };
  return stepRunner.runCommand(wiring.game, action, { ...wiring.commandFlow, ...saveHandlers(wiring, saveAsMode) });
}

/**
 * New, Open and Import: core asks for the generated puzzle or the picked file, loads it and
 * runs autosave; the view follows the game core shows.
 * @param {FileMenuWiring} wiring
 */
function runLoad(wiring, action) {
  const { game, session, boardEl, selection, menuBar, createElement, onViewRefresh, pick } = wiring;
  let pickedGame = null;
  const handlers = {
    ...wiring.commandFlow,
    pickOpen: async (step) => {
      const options = step.kind === PICK_KIND_PUZZLE ? { types: puzzleTextPickerTypes, accept: PUZZLE_TEXT_ACCEPT } : undefined;
      const picked = await pick(session, options);
      if (step.kind === PICK_KIND_GAME && picked.ok) pickedGame = picked;
      return picked;
    },
  };
  return commandFlowMod.runSessionCommand(game, action, handlers, (step) => {
    if (step.loaded) bindLoadedGame(session, pickedGame);
    refreshSessionView(boardEl, selection, menuBar, session.state, createElement, onViewRefresh);
  });
}

/** New opens the difficulty chooser; generation starts only after a pick. */
/** @param {FileMenuWiring} wiring */
function wireNew(button, wiring, difficultyDialog) {
  const { session, menuBar, statusEl } = wiring;
  const startNewGame = (difficulty) =>
    runLoad(wiring, { action: NEW_COMMAND, difficulty: settings.difficultyName({ difficulty }) });
  const newDialog = wireDifficultyDialog(difficultyDialog, startNewGame);
  button?.addEventListener("click", () => {
    if (!session.legend.new) return;
    menuBar.closeAll?.();
    statusBar.clearEventStatus(statusEl);
    newDialog.open();
  });
}

/** Open and Import pick a file and hand it to core. */
/** @param {FileMenuWiring} wiring */
function wireLoad(button, wiring, legendKey, command) {
  button?.addEventListener("click", async () => {
    if (!wiring.session.legend[legendKey]) return;
    statusBar.clearEventStatus(wiring.statusEl);
    await runLoad(wiring, { action: command });
  });
}

/** Save writes the working file; Save As chooses a fresh target. */
/** @param {FileMenuWiring} wiring */
function wireSave(button, wiring, legendKey, saveAsMode) {
  button?.addEventListener("click", async () => {
    if (!wiring.session.legend[legendKey]) return;
    await runSave(wiring, saveAsMode);
  });
}

/** Auto Save toggles through core, then the menu re-syncs its check mark. */
/** @param {FileMenuWiring} wiring */
function wireAutoSave(button, wiring) {
  button?.addEventListener("click", async () => {
    await commandFlowMod.runSessionCommand(wiring.game, { action: TOGGLE_AUTO_SAVE }, wiring.commandFlow, () => {
      wiring.menuBar.sync();
      wiring.onViewRefresh?.();
    });
  });
}

/** Export runs through core, which names the file; the one-line text leaves the save binding untouched. */
/** @param {FileMenuWiring} wiring */
function wireExport(button, wiring) {
  const { game, session, statusEl, download, exportText } = wiring;
  button?.addEventListener("click", async () => {
    if (!session.legend[menuBarMod.LEGEND_WIRE_EXPORT]) return;
    await stepRunner.runCommand(game, { action: EXPORT_COMMAND }, {
      ...wiring.commandFlow,
      write: async (name) => {
        const result = game.exportPuzzle();
        if (!result.ok) return result;
        const saved = await exportText(result.bytes, session, name, { download });
        return saved.ok ? { ok: true, name: saved.filename } : saved;
      },
      showStatus: (text) => statusBar.applyEventStatus(statusEl, { ok: true, msg: text }),
      showError: (text) => showFailure(wiring, { ok: false, error: text }),
    });
  });
}

/**
 * Wire every File item present in `controls`.
 * @param {FileMenuControls} controls
 * @param {GameApi} game
 * @param {HTMLElement} boardEl
 * @param {BoardSelection} selection
 * @param {HTMLElement} statusEl
 * @param {ErrorModal} errorModal
 * @param {WebSession} session
 * @param {MenuBar} menuBar
 */
export function wireFileMenu(
  controls,
  game,
  boardEl,
  selection,
  statusEl,
  errorModal,
  session,
  menuBar,
  {
    difficultyDialog,
    download = downloadBytes,
    pick = (session, opts) => pickBytes(document, session, opts),
    exportText = persistPuzzleText,
    createElement,
    onViewRefresh,
    commandFlow,
  } = {},
) {
  /** @type {FileMenuWiring} */
  const wiring = {
    game, boardEl, selection, statusEl, errorModal, session, menuBar,
    download, pick, exportText, createElement, onViewRefresh, commandFlow,
  };
  if (typeof session.boundSnapshotWriter !== "function") primeAndroidBoundTarget(session, globalThis);

  wireNew(controls.new, wiring, difficultyDialog);
  wireLoad(controls.open, wiring, "open", OPEN_COMMAND);
  wireLoad(controls.import, wiring, "import", IMPORT_COMMAND);
  wireSave(controls.save, wiring, "save", false);
  wireSave(controls.saveAs, wiring, "save_as", true);
  wireAutoSave(controls.autoSave, wiring);
  wireExport(controls.export, wiring);

  sessionMod.syncCurrentFileLabels(session);
}
