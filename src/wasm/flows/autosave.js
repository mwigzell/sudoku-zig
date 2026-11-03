// autosave.js — the final flush when the app closes: core's autosave flow issues `flush`.

import * as clientLog from "../client_log.js";
import * as stepRunner from "./step_runner.js";

/** @typedef {import("../types").GameApi} GameApi */
/** @typedef {import("../types").FlowHandlers} FlowHandlers */

/** Page hook the Android entry calls from its lifecycle, since its WebView fires no page hide when the app closes. */
export const FLUSH_ON_CLOSE_HOOK = "__sudokuFlushOnClose";
const TRIGGER_PAGE_HIDE = "pagehide";
const TRIGGER_APP_CLOSE = "app_close";

/**
 * Install the best-effort final flush: once on page hide, and each time the Android entry reports the app closing.
 * @param {GameApi} game
 * @param {FlowHandlers} steps the platform's step handlers
 */
export function wireFlushOnClose(game, steps, { win = globalThis } = {}) {
  if (!win || typeof win.addEventListener !== "function") return () => {};
  const flush = (trigger) =>
    stepRunner
      .runFlow(game, { flow: stepRunner.FLOW_AUTOSAVE_FLUSH }, steps)
      .then((outcome) => clientLog.clientLog("autosave", "info", "flush_on_close_result", { trigger, kind: outcome.kind }));
  let fired = false;
  const onPageHide = () => {
    if (fired) return;
    fired = true;
    void flush(TRIGGER_PAGE_HIDE);
  };
  win.addEventListener(TRIGGER_PAGE_HIDE, onPageHide);
  win[FLUSH_ON_CLOSE_HOOK] = () => void flush(TRIGGER_APP_CLOSE);
  return () => {
    win.removeEventListener?.(TRIGGER_PAGE_HIDE, onPageHide);
    delete win[FLUSH_ON_CLOSE_HOOK];
  };
}
