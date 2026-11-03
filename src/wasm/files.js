// files.js — browser file I/O: save and open pickers, file handles, and the download fallback.

/** @typedef {import("./types").WebSession} WebSession */
/** @typedef {import("./types").PickResult} PickResult */

/** First-time picker location when no game file is bound yet. */
export const FILE_PICKER_START_IN = "documents";
const ABORT_ERROR = "AbortError";

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
const SUD_ACCEPT = ".sud,application/octet-stream";

/** Picker start location follows the bound file handle when available. */
export function filePickerStartIn(session) {
  return session?.fileHandle ?? FILE_PICKER_START_IN;
}

/** Browser fallback download when no save picker is available. */
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

/** Write `bytes` over the file behind `handle`. */
export async function writeHandle(handle, bytes) {
  const writable = await handle.createWritable();
  await writable.write(bytes);
  await writable.close();
}

/**
 * Write `bytes` to a file the player picks (the picker asks its own replace question), else download them.
 * @returns {Promise<{ ok: true, filename: string, handle?: FileSystemFileHandle } | { ok: false, cancelled?: boolean, error?: string }>}
 */
async function saveThroughPicker(bytes, session, suggestedName, types, { win, download }) {
  if (win.showSaveFilePicker) {
    try {
      const handle = await win.showSaveFilePicker({ suggestedName, types, startIn: filePickerStartIn(session) });
      await writeHandle(handle, bytes);
      return { ok: true, filename: handle.name, handle };
    } catch (err) {
      if (err?.name === ABORT_ERROR) return { ok: false, cancelled: true };
      return { ok: false, error: err?.message ?? String(err) };
    }
  }
  download(bytes, suggestedName);
  return { ok: true, filename: suggestedName };
}

/** Write a saved game to a file the player picks; the picked handle comes back for binding. */
export function persistBytes(bytes, session, suggestedName, { win = globalThis, download = downloadBytes } = {}) {
  return saveThroughPicker(bytes, session, suggestedName, sudFilePickerTypes, { win, download });
}

/** Write a one-line puzzle export to a file the player picks. */
export function persistPuzzleText(bytes, session, suggestedName, { win = globalThis, download = downloadBytes } = {}) {
  return saveThroughPicker(bytes, session, suggestedName, puzzleTextPickerTypes, { win, download });
}

/**
 * Let the player choose a file and read it; a picked handle comes back so a saved game can be bound.
 * @returns {Promise<PickResult>}
 */
export async function pickBytes(doc = document, session = {}, { types = sudFilePickerTypes, accept = null } = {}) {
  const win = doc.defaultView;
  if (win?.showOpenFilePicker) {
    try {
      const [handle] = await win.showOpenFilePicker({
        types,
        startIn: filePickerStartIn(session),
        multiple: false,
      });
      const file = await handle.getFile();
      return { ok: true, bytes: new Uint8Array(await file.arrayBuffer()), name: file.name, handle };
    } catch (err) {
      if (err?.name === ABORT_ERROR) return { ok: false, cancelled: true };
      return { ok: false, error: err?.message ?? String(err) };
    }
  }

  return new Promise((resolve) => {
    const input = doc.createElement("input");
    input.type = "file";
    input.accept = accept ?? SUD_ACCEPT;
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
