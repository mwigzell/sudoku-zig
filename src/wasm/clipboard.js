// clipboard.js — browser clipboard for Copy and Paste puzzle, with the execCommand fallback.

import * as clientLog from "./client_log.js";

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
  } catch (err) {
    return { ok: false, error: `${CLIPBOARD_READ_DENIED_MSG}: ${err?.message ?? String(err)}` };
  }
}

async function writeClipboardText(text, { clipboard = globalThis.navigator?.clipboard, doc } = {}) {
  const document = doc ?? globalThis.document;
  if (!document) return { ok: false, error: CLIPBOARD_WRITE_DENIED_MSG };
  let writeTextFailure = "no writeText";
  if (clipboard?.writeText) {
    try {
      await clipboard.writeText(text);
      return { ok: true };
    } catch (err) {
      writeTextFailure = err?.message ?? String(err);
      clientLog.clientLog("clipboard", "info", "expected: writeText refused, trying execCommand", { error: writeTextFailure });
    }
  }
  if (copyTextWithExecCommand(text, document)) return { ok: true };
  return { ok: false, error: `${CLIPBOARD_WRITE_DENIED_MSG}: ${writeTextFailure}; execCommand refused` };
}

/** One-line puzzle string from wasm, or an error result. */
/** @param {GameApi} game */
function puzzleLineForCopy(game) {
  const exported = game.toPuzzle();
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
      .catch((err) => {
        clientLog.clientLog("clipboard", "info", "expected: writeText refused, trying execCommand", {
          error: err?.message ?? String(err),
        });
        return writeClipboardText(line.text, { clipboard: null, doc: document });
      });
  }
  return writeClipboardText(line.text, { clipboard: null, doc: document });
}
