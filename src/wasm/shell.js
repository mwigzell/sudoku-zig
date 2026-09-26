// wasm/shell.js — web app shell: session UX + Event presentation.
// Event.ok.msg → status bar; Event.error_msg → acknowledgement modal (ADR-0010).

/** Update the status bar from a successful exec result only. */
export function applyEventStatus(statusEl, result) {
  if (!result.ok) return;
  statusEl.textContent = result.msg ?? "";
  statusEl.className = "";
}

/** Show an Event.error_msg in the blocking error modal. */
export function showErrorModal(modal, message) {
  modal.msgEl.textContent = message;
  modal.el.hidden = false;
}

/** Wire dismiss on the error modal (click-to-dismiss, native showError analogue). */
export function wireErrorModal(el, msgEl, dismissEl) {
  const close = () => {
    el.hidden = true;
  };
  dismissEl.addEventListener("click", close);
  return { el, msgEl, close };
}

/** Route one exec result to status bar or error modal; never invent copy. */
export function applyExecResult(statusEl, errorModal, result) {
  if (!result.ok) {
    if (result.error) showErrorModal(errorModal, result.error);
    return;
  }
  applyEventStatus(statusEl, result);
}

/** Save current game — returns opaque SUD0 bytes or `{ ok: false, error }`. */
export function save(game) {
  return game.serialize();
}

/** Save-as is the same bytes path until a picker supplies a target name. */
export function saveAs(game) {
  return game.serialize();
}

/** Restore game state from opaque SUD0 bytes. */
export function open(game, bytes, { name } = {}) {
  const result = name ? game.deserialize(bytes, { name }) : game.deserialize(bytes);
  if (!result.ok) return result;
  return { ok: true, state: result.state, msg: result.msg ?? null };
}

/** Start a fresh game at the given difficulty (PlayerDifficulty wire values). */
export function newGame(game, { difficulty = 1, logLevel = 1 } = {}) {
  const result = game.init({ difficulty, logLevel });
  if (!result.ok) return result;
  return { ok: true, state: game.getState(), legend: game.getLegend(), config: game.getConfig() };
}

/** Export the current grid as an 81-byte one-line puzzle string. */
export function exportPuzzle(game) {
  return game.exportPuzzle();
}

/** Fallback when Async Clipboard API is missing or denied (needs user-gesture select). */
export function copyTextWithExecCommand(text, doc) {
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

export const CLIPBOARD_READ_DENIED_MSG = "paste: clipboard read denied";

export async function readClipboardText({ clipboard = globalThis.navigator?.clipboard } = {}) {
  if (!clipboard?.readText) return { ok: false, error: CLIPBOARD_READ_DENIED_MSG };
  try {
    const text = await clipboard.readText();
    return { ok: true, text };
  } catch {
    return { ok: false, error: CLIPBOARD_READ_DENIED_MSG };
  }
}

export async function writeClipboardText(text, { clipboard = globalThis.navigator?.clipboard, doc } = {}) {
  const document = doc ?? globalThis.document;
  if (!document) return { ok: false, error: "copy: clipboard write denied" };
  if (clipboard?.writeText) {
    try {
      await clipboard.writeText(text);
      return { ok: true };
    } catch {
      // fall through to execCommand
    }
  }
  if (copyTextWithExecCommand(text, document)) return { ok: true };
  return { ok: false, error: "copy: clipboard write denied" };
}

/** One-line puzzle string from wasm, or an error result. */
export function puzzleLineForCopy(game) {
  const exported = exportPuzzle(game);
  if (!exported.ok) return exported;
  return { ok: true, text: new TextDecoder().decode(exported.bytes) };
}

/**
 * Copy current grid via `exportPuzzle`. Prefer `startCopyPuzzleOnClick` in UI handlers
 * so `writeText` runs in the same turn as the user click (activation).
 */
export async function copyPuzzleToClipboard(game, options = {}) {
  const line = puzzleLineForCopy(game);
  if (!line.ok) return line;
  return writeClipboardText(line.text, options);
}

/** Start clipboard write in the click turn; returns a Promise for tests. */
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

/** Import a one-line puzzle from page-read file text; engine owns the codec. */
export function importPuzzle(game, text) {
  const result = game.importPuzzle(text);
  if (!result.ok) return result;
  return {
    ok: true,
    state: game.getState(),
    legend: game.getLegend(),
    config: game.getConfig(),
    msg: result.msg ?? null,
  };
}
