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
  clearEventStatus,
  postWriteContextEventForSession,
  persistCurrentFileSnapshotWithReplacePrompt,
  startAutoSavePolicy,
  WRITE_CONTEXT_EVENT_NEW_GAME_SUCCESS,
  WRITE_CONTEXT_EVENT_OPEN_SUCCESS,
  WRITE_CONTEXT_EVENT_SAVE_SUCCESS,
  WRITE_CONTEXT_EVENT_SAVE_AS_SUCCESS,
  WRITE_CONTEXT_EVENT_IMPORT_SUCCESS,
  syncCurrentFileLabels,
  showErrorModal,
  waitForStatusPaint,
} from "./shell.js";
import { renderBoard, setStatus } from "./board.js";
import { LEGEND_WIRE_EXPORT } from "./menu_bar.js";

export const DEFAULT_PUZZLE_EXPORT_FILENAME = "puzzle.txt";
/** First-time picker location when no game file is bound yet. */
export const FILE_PICKER_START_IN = "documents";
const BRIDGE_CANCELLED = "cancelled";

function bridgeSupportsSave(bridge) {
  return bridge != null && typeof bridge.saveSudokuFile === "function";
}

function bridgeSupportsOpen(bridge) {
  return bridge != null && typeof bridge.openSudokuFile === "function";
}

async function noOpWriteContextEvent() {
  return { ok: true };
}

function bytesToBase64(bytes) {
  const chars = [];
  for (const b of bytes) chars.push(String.fromCharCode(b));
  return btoa(chars.join(""));
}

function base64ToBytes(base64) {
  const text = atob(base64);
  const out = new Uint8Array(text.length);
  for (let i = 0; i < text.length; i += 1) out[i] = text.charCodeAt(i);
  return out;
}

export function filePickerStartIn(session) {
  return session?.fileHandle ?? FILE_PICKER_START_IN;
}

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
  renderBoard(boardEl, state, createElement);
  session.state = state;
  session.legend = legend;
  session.config = config;
  selection.deselect();
  applyEventStatus(statusEl, { ok: true, msg: eventMsg });
  syncCurrentFileLabels(session);
  menuBar.sync();
  onViewRefresh?.();
}

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

async function writeHandle(handle, bytes) {
  const writable = await handle.createWritable();
  await writable.write(bytes);
  await writable.close();
}

export async function persistBytes(
  bytes,
  session,
  suggestedName,
  { saveAs = false, win = globalThis, download = downloadBytes, bridge = win.AndroidFileBridge } = {},
) {
  if (!saveAs && session.fileHandle) {
    try {
      await writeHandle(session.fileHandle, bytes);
      return { ok: true, filename: session.fileHandle.name };
    } catch {
      session.fileHandle = null;
    }
  }

  if (bridgeSupportsSave(bridge)) {
    try {
      const out = await bridge.saveSudokuFile(bytesToBase64(bytes), suggestedName, saveAs === true);
      if (!out || out.ok !== true) {
        if (out?.cancelled === true || out?.reason === BRIDGE_CANCELLED) return { ok: false, cancelled: true };
        return { ok: false, error: out?.error ?? "save failed" };
      }
      return { ok: true, filename: out.name ?? suggestedName };
    } catch (err) {
      return { ok: false, error: err?.message ?? "save failed" };
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
      return { ok: true, filename: handle.name };
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
      return { ok: true, bytes: base64ToBytes(out.base64), name: out.name };
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
    writeContextEvent = noOpWriteContextEvent,
  } = {},
) {
  if (!session.writeContextEvent) session.writeContextEvent = writeContextEvent;
  const fail = (result) => {
    if (result.error) showErrorModal(errorModal, result.error);
  };

  const applyNewGame = async (result) => {
    session.fileHandle = null;
    const contextUpdated = await postWriteContextEventForSession(
      session,
      WRITE_CONTEXT_EVENT_NEW_GAME_SUCCESS,
      globalThis.fetch,
    ).catch((err) => ({
      ok: false,
      error: err?.message ?? String(err),
    }));
    if (!contextUpdated.ok) fail(contextUpdated);
    refreshSession(
      boardEl,
      selection,
      statusEl,
      session,
      menuBar,
      result.state,
      result.legend,
      result.config,
      createElement,
      onViewRefresh,
      result.msg,
    );
  };

  const runNewGame = async (difficulty) => {
    const result = newGame(game, { difficulty });
    if (!result.ok) return result;
    await applyNewGame(result);
    return result;
  };

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

  controls.new?.addEventListener("click", () => {
    if (!session.legend.new) return;
    menuBar.closeAll?.();
    clearEventStatus(statusEl);
    newDialog.open();
  });

  controls.save?.addEventListener("click", async () => {
    if (!session.legend.save) return;
    // Auto-save mode keeps manual Save inert; explicit state lives in File menu.
    if (session.config?.auto_save === true) return;
    const result = save(game);
    if (!result.ok) {
      fail(result);
      return;
    }
    const suggested = suggestedSaveFilename(session);
    if (!suggested) {
      fail({ ok: false, error: "missing default_save_filename in session" });
      return;
    }
    const saved = await persistBytes(
      result.bytes,
      session,
      suggested,
      { download },
    );
    if (saved.ok) {
      session.boundFilename = saved.filename;
      const mirrored = await persistCurrentFileSnapshotWithReplacePrompt(game, {
        fetchFn: globalThis.fetch,
        saveName: saved.filename,
      });
      if (!mirrored.ok) {
        if (mirrored.cancelled) return;
        fail(mirrored);
        return;
      }
      const contextUpdated = await postWriteContextEventForSession(session, WRITE_CONTEXT_EVENT_SAVE_SUCCESS, globalThis.fetch);
      if (!contextUpdated.ok) fail(contextUpdated);
      syncCurrentFileLabels(session);
      applyEventStatus(statusEl, { ok: true, msg: `saved: ${saved.filename}` });
    } else if (!saved.ok && !saved.cancelled) {
      fail(saved);
    }
  });

  controls.saveAs?.addEventListener("click", async () => {
    if (!session.legend.save_as) return;
    const result = saveAs(game);
    if (!result.ok) {
      fail(result);
      return;
    }
    const suggested = suggestedSaveFilename(session);
    if (!suggested) {
      fail({ ok: false, error: "missing default_save_filename in session" });
      return;
    }
    const saved = await persistBytes(result.bytes, session, suggested, { saveAs: true, download });
    if (saved.ok) {
      session.boundFilename = saved.filename;
      const mirrored = await persistCurrentFileSnapshotWithReplacePrompt(game, {
        fetchFn: globalThis.fetch,
        saveName: saved.filename,
      });
      if (!mirrored.ok) {
        if (mirrored.cancelled) return;
        fail(mirrored);
        return;
      }
      const contextUpdated = await postWriteContextEventForSession(session, WRITE_CONTEXT_EVENT_SAVE_AS_SUCCESS, globalThis.fetch);
      if (!contextUpdated.ok) fail(contextUpdated);
      syncCurrentFileLabels(session);
      applyEventStatus(statusEl, { ok: true, msg: `saved: ${saved.filename}` });
    } else if (!saved.ok && !saved.cancelled) {
      fail(saved);
    }
  });

  controls.autoSave?.addEventListener("click", async () => {
    const enabled = session.config?.auto_save !== true;
    const result = game.exec({ action: "set_auto_save", enabled });
    if (!result.ok) {
      fail(result);
      return;
    }
    session.config = game.getConfig();
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
    session.fileHandle = picked.handle ?? null;
    session.boundFilename = picked.name;
    const contextUpdated = await postWriteContextEventForSession(session, WRITE_CONTEXT_EVENT_OPEN_SUCCESS, globalThis.fetch);
    if (!contextUpdated.ok) fail(contextUpdated);
    refreshSession(
      boardEl,
      selection,
      statusEl,
      session,
      menuBar,
      result.state,
      game.getLegend(),
      game.getConfig(),
      createElement,
      onViewRefresh,
      result.msg,
    );
    startAutoSavePolicy(game, session, "open", { onError: fail });
  });

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
    session.fileHandle = null;
    session.boundFilename = null;
    const contextUpdated = await postWriteContextEventForSession(session, WRITE_CONTEXT_EVENT_IMPORT_SUCCESS, globalThis.fetch);
    if (!contextUpdated.ok) fail(contextUpdated);
    refreshSession(
      boardEl,
      selection,
      statusEl,
      session,
      menuBar,
      result.state,
      result.legend,
      result.config,
      createElement,
      onViewRefresh,
      result.msg,
    );
    startAutoSavePolicy(game, session, "import", { onError: fail });
  });

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
