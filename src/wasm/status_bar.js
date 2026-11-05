// status_bar.js — status bar: shows core's Event text (`Event.ok.msg`).

/** Update the status bar from a successful exec result only. */
export function applyEventStatus(statusEl, result) {
  if (!result.ok) return;
  const msg = result.msg;
  statusEl.textContent = typeof msg === "string" && msg.length > 0 ? msg : "";
  statusEl.className = "";
}

/**
 * Show core's status text; null or empty clears the bar.
 * @param {HTMLElement} statusEl
 * @param {string | null | undefined} text
 */
export function showStatusText(statusEl, text) {
  applyEventStatus(statusEl, { ok: true, msg: text ?? null });
}

/** Yield so the status bar can paint before a blocking wasm `init`. */
export function waitForStatusPaint() {
  if (typeof requestAnimationFrame !== "function") return Promise.resolve();
  return new Promise((resolve) => {
    requestAnimationFrame(() => requestAnimationFrame(resolve));
  });
}
