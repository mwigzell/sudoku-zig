// clipboard.js — browser clipboard for Copy and Paste puzzle, with the execCommand fallback.

/** @typedef {import("./types").GameApi} GameApi */

const CLIPBOARD_READ_DENIED_MSG = "paste: clipboard read denied";
const CLIPBOARD_WRITE_DENIED_MSG = "copy: clipboard write denied";

/** Fallback when Async Clipboard API is missing or denied (needs user-gesture select). */
function copyTextWithExecCommand(text, doc) {
  if (!doc) return false;
  const ta = doc.createElement("textarea");
  ta.value = text;
  ta.setAttribute("readonly", "");
  ta.style.position = "fixed";
  ta.style.left = "-9999px";
  doc.body.appendChild(ta);
  ta.select();
  try {
    return doc.execCommand("copy");
  } finally {
    doc.body.removeChild(ta);
  }
}

/** Clipboard text for Paste, or an error result when the browser denies the read. */
export async function readClipboardText({ clipboard = globalThis.navigator?.clipboard } = {}) {
  if (!clipboard?.readText) return { ok: false, error: CLIPBOARD_READ_DENIED_MSG };
  try {
    const text = await clipboard.readText();
    return { ok: true, text };
  } catch {
    return { ok: false, error: CLIPBOARD_READ_DENIED_MSG };
  }
}

async function writeClipboardText(text, { clipboard = globalThis.navigator?.clipboard, doc } = {}) {
  const document = doc ?? globalThis.document;
  if (!document) return { ok: false, error: CLIPBOARD_WRITE_DENIED_MSG };
  if (clipboard?.writeText) {
    try {
      await clipboard.writeText(text);
      return { ok: true };
    } catch {
      // fall through to execCommand
    }
  }
  if (copyTextWithExecCommand(text, document)) return { ok: true };
  return { ok: false, error: CLIPBOARD_WRITE_DENIED_MSG };
}

/** One-line puzzle string from wasm, or an error result. */
/** @param {GameApi} game */
function puzzleLineForCopy(game) {
  const exported = game.exportPuzzle();
  if (!exported.ok) return exported;
  return { ok: true, text: new TextDecoder().decode(exported.bytes) };
}

/** Start clipboard write in the click turn so `writeText` keeps the user's activation; returns a Promise for tests. */
/** @param {GameApi} game */
export function startCopyPuzzleOnClick(game, { clipboard = globalThis.navigator?.clipboard, doc } = {}) {
  const document = doc ?? globalThis.document;
  const line = puzzleLineForCopy(game);
  if (!line.ok) return Promise.resolve(line);
  const pending = clipboard?.writeText?.(line.text);
  if (pending) {
    return pending
      .then(() => ({ ok: true }))
      .catch(() => writeClipboardText(line.text, { clipboard: null, doc: document }));
  }
  return writeClipboardText(line.text, { clipboard: null, doc: document });
}
