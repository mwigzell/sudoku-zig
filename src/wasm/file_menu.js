// file_menu.js — File menu session actions via shell.js.

import {
  newGame,
  newGameWithGeneratingModal,
  open,
  save,
  saveAs,
  importPuzzle,
  exportPuzzle,
  applyEventStatus,
  applyLoadedSessionOutcome,
  applyConfigOutcomeStatus,
  applySessionOutcomeStatus,
  clearEventStatus,
  persistCurrentFileBytes,
  startAutoSavePolicy,
  WRITE_CONTEXT_EVENT_NEW_GAME_SUCCESS,
  WRITE_CONTEXT_EVENT_OPEN_SUCCESS,
  WRITE_CONTEXT_EVENT_IMPORT_SUCCESS,
  syncCurrentFileLabels,
  showErrorModal,
  waitForStatusPaint,
} from "./shell.js";
import { renderBoard, setStatus } from "./board.js";
import { LEGEND_WIRE_EXPORT } from "./menu_bar.js";
import { askWithDialog, FLOW_SAVE, FLOW_SAVE_AS, runFlow, SAVE_FAILED_MSG } from "./step_runner.js";

/** @typedef {import("./types").GameApi} GameApi */

export const DEFAULT_PUZZLE_EXPORT_FILENAME = "puzzle.txt";
/** First-time picker location when no game file is bound yet. */
export const FILE_PICKER_START_IN = "documents";
const BRIDGE_CANCELLED = "cancelled";
/** Android bridge reason: the default visible file belongs to an earlier install. */
const BRIDGE_DEFAULT_TAKEN = "default_taken";
const ANDROID_TAKEN_TITLE = "Autosave file";
const ANDROID_TAKEN_PICK_LABEL = "Pick it";
const ANDROID_TAKEN_RENAME_LABEL = "New name";
const BINDING_KIND_FILE_HANDLE = "file_handle";
const BINDING_KIND_ANDROID_BRIDGE = "android_bridge";
/** Android bridge capability check for Save/Save As path selection. */
function bridgeSupportsSave(bridge) {
  return bridge != null && typeof bridge.saveSudokuFile === "function";
}

/** Android bridge capability check for Open/Import picker path selection. */
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

/** Save target label priority: bound runtime name first, host default as fallback. */
function suggestedSaveFilename(session) {
  const name = session?.boundFilename ?? session?.default_save_filename;
  if (typeof name === "string" && name.length > 0) return name;
  return null;
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

/** Canonical render+session update path after commands that replace board/config snapshots. */
export function refreshSession(
  boardEl,
  selection,
  statusEl,
  session,
  menuBar,
  state,
  legend,
  config,
  createElement,
  onViewRefresh,
  eventMsg = null,
) {
  refreshSessionView(
    boardEl,
    selection,
    menuBar,
    state,
    createElement,
    onViewRefresh,
  );
  applySessionOutcomeStatus(session, statusEl, {
    state,
    legend,
    config,
    msg: eventMsg,
  });
}

/** View-only refresh used after session has already been updated through shell helpers. */
export function refreshSessionView(
  boardEl,
  selection,
  menuBar,
  state,
  createElement,
  onViewRefresh,
) {
  renderBoard(boardEl, state, createElement);
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
}

function androidSaveOutcome(out) {
  if (!out || out.ok !== true) {
    if (out?.cancelled === true || out?.reason === BRIDGE_CANCELLED) return { ok: false, cancelled: true };
    return { ok: false, error: out?.error ?? SAVE_FAILED_MSG };
  }
  return typeof out.name === "string" && out.name.length > 0 ? { ok: true, name: out.name } : { ok: true };
}

/** Earlier-install default file: ask pick-or-rename in the web dialog until one picker writes a file. */
async function resolveAndroidDefaultTaken(bridge, base64, name, dir, win) {
  const choose = win?.__sudokuChoose;
  if (typeof choose !== "function") return { ok: false, error: "save dialog unavailable" };
  const message =
    `${name} in ${dir} was saved by an earlier install. ` +
    "Pick it to keep autosaving there, or choose a new name.";
  while (true) {
    const pickExisting = await choose(message, {
      title: ANDROID_TAKEN_TITLE,
      okLabel: ANDROID_TAKEN_PICK_LABEL,
      cancelLabel: ANDROID_TAKEN_RENAME_LABEL,
    });
    const out = pickExisting
      ? await bridge.saveSudokuFileToExisting(base64)
      : await bridge.saveSudokuFile(base64, name, true);
    const outcome = androidSaveOutcome(out);
    if (outcome.cancelled) continue;
    return outcome;
  }
}

async function saveToAndroidBoundTarget(bridge, bytes, suggestedName, win = globalThis) {
  if (!bridge) return { ok: false, error: "no Android bridge" };
  const saveCurrent = bridge.saveCurrentSudokuFile;
  if (typeof saveCurrent === "function") {
    const base64 = bytesToBase64(bytes);
    const out = await saveCurrent(base64, suggestedName);
    if (out?.reason === BRIDGE_DEFAULT_TAKEN) {
      return resolveAndroidDefaultTaken(bridge, base64, out.name ?? suggestedName, out.dir, win);
    }
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
    session.boundSnapshotWriterKind = BINDING_KIND_FILE_HANDLE;
    session.boundTargetExists = () => true;
    session.boundSnapshotWriter = async (bytes) => {
      try {
        await writeHandle(binding.handle, bytes);
        return { ok: true };
      } catch (err) {
        session.fileHandle = null;
        clearBoundSnapshotWriter(session);
        return { ok: false, error: err?.message ?? SAVE_FAILED_MSG };
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
        return await saveToAndroidBoundTarget(bridge, bytes, suggestedName, win);
      } catch (err) {
        return { ok: false, error: err?.message ?? SAVE_FAILED_MSG };
      }
    };
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
        return { ok: false, error: out?.error ?? SAVE_FAILED_MSG };
      }
      return { ok: true, filename: out.name ?? suggestedName, binding: bindingForAndroidBridge() };
    } catch (err) {
      return { ok: false, error: err?.message ?? SAVE_FAILED_MSG };
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
  suggestedName = DEFAULT_PUZZLE_EXPORT_FILENAME,
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
      return { ok: false, error: err?.message ?? "export failed" };
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
        return { ok: false, error: out?.error ?? "open failed" };
      }
      if (typeof out.base64 !== "string" || typeof out.name !== "string") {
        return { ok: false, error: "invalid Android file payload" };
      }
      return { ok: true, bytes: base64ToBytes(out.base64), name: out.name, binding: bindingForAndroidBridge() };
    } catch (err) {
      return { ok: false, error: err?.message ?? "open failed" };
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
        await waitForStatusPaint();
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

/** @param {GameApi} game */
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
    generatingModal,
    genWorker,
    download = downloadBytes,
    pick = (session, opts) => pickBytes(document, session, opts),
    exportText = persistPuzzleText,
    createElement,
    onViewRefresh,
    onPersist,
  } = {},
) {
  const fail = (result) => {
    if (result.error) showErrorModal(errorModal, result.error);
  };

  const MISSING_DEFAULT_SAVE_FILENAME = "missing default_save_filename in session";

  /**
   * Platform work for the core Save / Save As flow. The user's file is written by the bound
   * handle, the Android bridge, a picker or a download; the host keeps the restore copy.
   * Without a bound file the picker asks its own overwrite question, so the target is new to core.
   */
  const saveHandlers = (saveAsMode) => ({
    checkTarget: () =>
      !saveAsMode && (session.fileHandle != null || androidCurrentTargetName(globalThis) != null),
    ask: (step) => askWithDialog(step, globalThis),
    write: async (name) => {
      const result = saveAsMode ? saveAs(game) : save(game);
      if (!result.ok) return result;
      const saved = await persistBytes(result.bytes, session, name, { saveAs: saveAsMode, download });
      if (!saved.ok) return saved;
      session.boundFilename = saved.filename;
      bindSnapshotWriter(session, saved.binding, globalThis);
      const hosted = await persistCurrentFileBytes(result.bytes, globalThis.fetch, saved.filename, { restoreCopy: true });
      if (!hosted.ok) return hosted;
      return { ok: true, name: saved.filename };
    },
    showStatus: (text) => {
      syncCurrentFileLabels(session);
      applyEventStatus(statusEl, { ok: true, msg: text });
    },
    showError: (text) => fail({ ok: false, error: text }),
  });

  const runSave = async (saveAsMode) => {
    const suggested = suggestedSaveFilename(session);
    if (!suggested) {
      fail({ ok: false, error: MISSING_DEFAULT_SAVE_FILENAME });
      return;
    }
    await runFlow(game, { flow: saveAsMode ? FLOW_SAVE_AS : FLOW_SAVE, name: suggested }, saveHandlers(saveAsMode));
  };

  if (typeof session.boundSnapshotWriter !== "function") primeAndroidBoundTarget(session, globalThis);

  /** Shared tail for successful board-replacing loads (new/open/import) before autosave kick. */
  const finalizeLoadedSession = async (
    result,
    {
      fileHandle,
      boundFilename,
      binding = null,
      writeContextEventName,
      legend,
      config,
      commandName = null,
    },
  ) => {
    const finalized = applyLoadedSessionOutcome(
      game,
      session,
      statusEl,
      result,
      {
        writeContextEventName,
        fileHandle,
        boundFilename,
        workingFile: writeContextEventName === WRITE_CONTEXT_EVENT_OPEN_SUCCESS ? boundFilename : null,
        legend,
        config,
      },
    );
    if (!finalized.ok) fail(finalized);
    if (binding) {
      bindSnapshotWriter(session, binding, globalThis);
    } else if (fileHandle == null && boundFilename == null) {
      clearBoundSnapshotWriter(session);
      // With no Android file bound there is nothing to detach from; the bridge writes its default visible file.
      if (androidCurrentTargetName(globalThis) == null) primeAndroidBoundTarget(session, globalThis);
    }
    refreshSessionView(
      boardEl,
      selection,
      menuBar,
      session.state,
      createElement,
      onViewRefresh,
    );
    if (commandName) startAutoSavePolicy(game, session, commandName, { onError: fail });
  };

  /** New-game completion follows same loaded-session helper path as other board swaps. */
  const applyNewGame = async (result) => {
    await finalizeLoadedSession(result, {
      fileHandle: null,
      boundFilename: session.boundFilename ?? null,
      writeContextEventName: WRITE_CONTEXT_EVENT_NEW_GAME_SUCCESS,
      legend: result.legend,
      config: result.config,
    });
  };

  /** Legacy non-modal new-game path (kept for environments without generating modal). */
  const runNewGame = async (difficulty) => {
    const result = newGame(game, { difficulty });
    if (!result.ok) return result;
    await applyNewGame(result);
    return result;
  };

  /** File -> New orchestration (status clear, modal/new path, canonical completion). */
  const startNewGame = async (difficulty) => {
    clearEventStatus(statusEl);
    try {
      if (generatingModal) {
        const result = await newGameWithGeneratingModal(game, generatingModal, {
          difficulty,
          genWorker,
        });
        if (result.cancelled) return;
        if (!result.ok) {
          fail(result);
          return;
        }
        await applyNewGame(result);
        return;
      }
      await waitForStatusPaint();
      const result = await runNewGame(difficulty);
      if (!result.ok) fail(result);
    } catch (err) {
      fail({ ok: false, error: err?.message ?? String(err) });
    }
  };
  const newDialog = wireDifficultyDialog(difficultyDialog, startNewGame);

  // Phase B: open New difficulty chooser (generation starts only after a pick).
  const openNewGameDialog = () => {
    if (!session.legend.new) return;
    menuBar.closeAll?.();
    clearEventStatus(statusEl);
    newDialog.open();
  };
  controls.new?.addEventListener("click", openNewGameDialog);

  // Phase C: manual Save runs the core save flow.
  controls.save?.addEventListener("click", async () => {
    if (!session.legend.save) return;
    // Auto-save mode keeps manual Save inert; explicit state lives in File menu.
    if (session.config?.auto_save === true) return;
    await runSave(false);
  });

  // Phase D: Save As runs the same flow with a fresh target choice.
  controls.saveAs?.addEventListener("click", async () => {
    if (!session.legend.save_as) return;
    await runSave(true);
  });

  // Phase E: settings-only path (toggle autosave), no board replacement.
  controls.autoSave?.addEventListener("click", async () => {
    const enabled = session.config?.auto_save !== true;
    const result = game.exec({ action: "set_auto_save", enabled });
    if (!applyConfigOutcomeStatus(session, game, null, result)) {
      fail(result);
      return;
    }
    menuBar.sync();
    onViewRefresh?.();
    if (onPersist) {
      try {
        await onPersist(session.config);
      } catch (err) {
        showErrorModal(errorModal, err?.message ?? String(err));
      }
    }
  });

  // Phase F: Open path (SUD0 bytes) -> canonical loaded-session completion -> autosave kick.
  controls.open?.addEventListener("click", async () => {
    if (!session.legend.open) return;
    clearEventStatus(statusEl);
    const picked = await pick(session);
    if (!picked.ok || picked.cancelled) return;
    const result = open(game, picked.bytes, { name: picked.name });
    if (!result.ok) {
      fail(result);
      return;
    }
    await finalizeLoadedSession(result, {
      fileHandle: picked.handle ?? null,
      boundFilename: picked.name,
      binding: picked.binding ?? null,
      writeContextEventName: WRITE_CONTEXT_EVENT_OPEN_SUCCESS,
      legend: game.getLegend(),
      config: game.getConfig(),
      commandName: "open",
    });
  });

  // Phase G: Import path (one-line text) -> canonical loaded-session completion -> autosave kick.
  controls.import?.addEventListener("click", async () => {
    if (!session.legend.import) return;
    clearEventStatus(statusEl);
    const picked = await pick(session, { types: puzzleTextPickerTypes, accept: PUZZLE_TEXT_ACCEPT });
    if (!picked.ok || picked.cancelled) return;
    const text = new TextDecoder().decode(picked.bytes);
    const result = importPuzzle(game, text);
    if (!result.ok) {
      fail(result);
      return;
    }
    await finalizeLoadedSession(result, {
      fileHandle: null,
      boundFilename: null,
      writeContextEventName: WRITE_CONTEXT_EVENT_IMPORT_SUCCESS,
      legend: result.legend,
      config: result.config,
      commandName: "import",
    });
  });

  // Phase H: Export path writes one-line text only and leaves current save binding untouched.
  controls.export?.addEventListener("click", async () => {
    if (!session.legend[LEGEND_WIRE_EXPORT]) return;
    const result = exportPuzzle(game);
    if (!result.ok) {
      fail(result);
      return;
    }
    const saved = await exportText(result.bytes, session, DEFAULT_PUZZLE_EXPORT_FILENAME, { download });
    if (saved.ok) {
      applyEventStatus(statusEl, { ok: true, msg: `exported: ${saved.filename}` });
    } else if (!saved.ok && !saved.cancelled) {
      fail(saved);
    }
  });

  syncCurrentFileLabels(session);
}
