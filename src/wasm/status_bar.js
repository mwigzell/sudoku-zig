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

/** Scroll positions within this many pixels of the end count as the end: browsers round fractional sizes. */
const SCROLL_END_SLACK_PX = 1;

/**
 * True while part of the bar's text is hidden below its one-line height.
 * @param {{ scrollTop: number, clientHeight: number, scrollHeight: number }} statusEl
 */
export function hasTextBelow(statusEl) {
  return statusEl.scrollTop + statusEl.clientHeight < statusEl.scrollHeight - SCROLL_END_SLACK_PX;
}

/**
 * Keep `data-more` on the bar while text is hidden below (the page fades its bottom edge),
 * and show each new message from its first line. Observes the bar, so every writer is covered.
 * @param {HTMLElement} statusEl
 * @param {Window & typeof globalThis} [win]
 */
export function wireStatusOverflow(statusEl, win = globalThis) {
  const sync = () => {
    statusEl.dataset.more = hasTextBelow(statusEl) ? "true" : "false";
  };
  statusEl.addEventListener("scroll", sync);
  win.addEventListener?.("resize", sync);
  if (typeof win.MutationObserver === "function") {
    new win.MutationObserver(() => {
      statusEl.scrollTop = 0;
      sync();
    }).observe(statusEl, { childList: true, characterData: true, subtree: true });
  }
  sync();
}

/** Yield so the status bar can paint before a blocking wasm `init`. */
export function waitForStatusPaint() {
  if (typeof requestAnimationFrame !== "function") return Promise.resolve();
  return new Promise((resolve) => {
    requestAnimationFrame(() => requestAnimationFrame(resolve));
  });
}
