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
