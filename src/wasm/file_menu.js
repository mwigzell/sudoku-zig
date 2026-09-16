// file_menu.js — File menu session actions via shell.js (#42).

import { newGame, open, save, saveAs, applyEventStatus, showErrorModal } from "./shell.js";
import { renderBoard } from "./board.js";

export const DEFAULT_SAVE_FILENAME = "sudoku.sud";
export const SAVE_AS_FILENAME = "sudoku-save.sud";
/** First-time picker location when no game file is bound yet. */
export const FILE_PICKER_START_IN = "documents";

export function filePickerStartIn(session) {
  return session?.fileHandle ?? FILE_PICKER_START_IN;
}

export const sudFilePickerTypes = [
  {
    description: "Sudoku puzzle",
    accept: { "application/octet-stream": [".sud"] },
  },
];

export function refreshSession(
  boardEl,
  selection,
  statusEl,
  session,
  menuBar,
  state,
  legend,
  createElement,
) {
  renderBoard(boardEl, state, createElement);
  session.state = state;
  session.legend = legend;
  selection.select(0, 0);
  applyEventStatus(statusEl, { ok: true, msg: null });
  menuBar.sync();
}

export function downloadBytes(bytes, filename = DEFAULT_SAVE_FILENAME, doc = document) {
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
  { saveAs = false, win = globalThis, download = downloadBytes } = {},
) {
  if (!saveAs && session.fileHandle) {
    try {
      await writeHandle(session.fileHandle, bytes);
      return { ok: true, filename: session.fileHandle.name };
    } catch {
      session.fileHandle = null;
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

export async function pickBytes(doc = document, session = {}) {
  const win = doc.defaultView;
  if (win?.showOpenFilePicker) {
    try {
      const [handle] = await win.showOpenFilePicker({
        types: sudFilePickerTypes,
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
    input.accept = ".sud,application/octet-stream";
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

export function wireFileMenu(
  controls,
  game,
  boardEl,
  selection,
  statusEl,
  errorModal,
  session,
  menuBar,
  { difficulty = 1, download = downloadBytes, pick = (session) => pickBytes(document, session), createElement } = {},
) {
  const fail = (result) => {
    if (result.error) showErrorModal(errorModal, result.error);
  };

  controls.new?.addEventListener("click", () => {
    if (!session.legend.new) return;
    const result = newGame(game, { difficulty });
    if (!result.ok) {
      fail(result);
      return;
    }
    session.fileHandle = null;
    refreshSession(boardEl, selection, statusEl, session, menuBar, result.state, result.legend, createElement);
  });

  controls.save?.addEventListener("click", async () => {
    if (!session.legend.save) return;
    const result = save(game);
    if (!result.ok) {
      fail(result);
      return;
    }
    const saved = await persistBytes(result.bytes, session, DEFAULT_SAVE_FILENAME, { download });
    if (!saved.ok && !saved.cancelled) fail(saved);
  });

  controls.saveAs?.addEventListener("click", async () => {
    if (!session.legend.save_as) return;
    const result = saveAs(game);
    if (!result.ok) {
      fail(result);
      return;
    }
    const saved = await persistBytes(result.bytes, session, SAVE_AS_FILENAME, { saveAs: true, download });
    if (!saved.ok && !saved.cancelled) fail(saved);
  });

  controls.open?.addEventListener("click", async () => {
    if (!session.legend.open) return;
    const picked = await pick(session);
    if (!picked.ok || picked.cancelled) return;
    const result = open(game, picked.bytes);
    if (!result.ok) {
      fail(result);
      return;
    }
    session.fileHandle = picked.handle ?? null;
    refreshSession(boardEl, selection, statusEl, session, menuBar, result.state, game.getLegend(), createElement);
  });
}
