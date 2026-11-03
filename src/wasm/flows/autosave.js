// autosave.js — the final flush when the page hides: core's autosave flow issues `flush`.

import * as clientLog from "../client_log.js";
import * as stepRunner from "./step_runner.js";

/** @typedef {import("../types").GameApi} GameApi */
/** @typedef {import("../types").FlowHandlers} FlowHandlers */

/**
 * Install one best-effort final flush for tab hide/close in autosave mode.
 * @param {GameApi} game
 * @param {FlowHandlers} steps the platform's step handlers
 */
export function wireFinalSnapshotOnPageHide(game, steps, { win = globalThis } = {}) {
  if (!win || typeof win.addEventListener !== "function") return () => {};
  let fired = false;
  const onPageHide = () => {
    if (fired) return;
    fired = true;
    void stepRunner
      .runFlow(game, { flow: stepRunner.FLOW_AUTOSAVE_FLUSH }, steps)
      .then((outcome) => clientLog.clientLog("autosave", "info", "pagehide_flush_result", { kind: outcome.kind }));
  };
  win.addEventListener("pagehide", onPageHide);
  return () => win.removeEventListener?.("pagehide", onPageHide);
}
