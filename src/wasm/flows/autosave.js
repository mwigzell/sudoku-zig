// autosave.js — platform work for core's autosave flow: the bound file or host copy, and the final flush when the page hides.

import * as clientLog from "../client_log.js";
import * as hostApi from "../host_api.js";
import * as sessionMod from "./session.js";
import * as stepRunner from "./step_runner.js";

/** @typedef {import("../types").GameApi} GameApi */
/** @typedef {import("../types").WriteResult} WriteResult */

function autosaveLevelForStage(stage, details = {}) {
  if (stage === "persist_failed") return "warn";
  if (stage === "pagehide_flush_result" && details.kind === "show_error") return "warn";
  if (stage === "persist_ok" || stage === "pagehide_flush_result") return "info";
  return "debug";
}

function logAutosave(stage, details = {}) {
  const level = autosaveLevelForStage(stage, details);
  clientLog.clientLog("autosave", level, stage, details);
}

/**
 * Platform work for the core autosave flow: a bound file (handle or Android bridge) is the
 * user's file and the host keeps a restore copy; otherwise the host copy is the user's file.
 * @param {GameApi} game
 */
export function autosaveHandlers(
  game,
  session,
  { fetchFn = globalThis.fetch, win = globalThis, onError, hostOnly = false } = {},
) {
  const bound = () => typeof session.boundSnapshotWriter === "function";
  /**
   * Serialize, let `writeUserFile` (when given) write the user's file, then keep the host copy.
   * @param {((bytes: Uint8Array) => Promise<WriteResult>) | null} writeUserFile
   * @param {string} name
   * @returns {Promise<WriteResult>}
   */
  const writeGame = async (writeUserFile, name) => {
    const serialized = game.serialize();
    if (!serialized.ok) return serialized;
    let written = name;
    if (writeUserFile) {
      const saved = await writeUserFile(serialized.bytes);
      if (!saved?.ok) return saved ?? { ok: false };
      if (typeof saved.name === "string" && saved.name.length > 0) written = saved.name;
    }
    const hosted = await hostApi.persistCurrentFileBytes(serialized.bytes, fetchFn, written, { restoreCopy: bound() });
    if (!hosted.ok) return hosted;
    session.boundFilename = written;
    sessionMod.syncCurrentFileLabels(session);
    return { ok: true, name: written };
  };
  return {
    resolveDefaultTarget: () => session.default_save_filename,
    checkTarget: (target) => {
      if (bound()) return session.boundTargetExists?.() === true;
      return hostApi.hostCurrentFileExists(target.name, fetchFn);
    },
    ask: (step) => stepRunner.askWithDialog(step, win),
    write: (target) =>
      writeGame(bound() && !hostOnly ? (bytes) => session.boundSnapshotWriter(bytes, target.name) : null, target.name),
    pickExisting: () => writeGame((bytes) => session.boundPickExisting(bytes), session.default_save_filename),
    pickNew: (name) => writeGame((bytes) => session.boundPickNew(bytes, name), name),
    showError: (text) => onError?.({ ok: false, error: text }),
  };
}

/** Install one best-effort final snapshot flush for tab hide/close in autosave mode. */
/** @param {GameApi} game */
export function wireFinalSnapshotOnPageHide(
  game,
  session,
  { win = globalThis, fetchFn = globalThis.fetch } = {},
) {
  if (!win || typeof win.addEventListener !== "function") return () => {};
  let fired = false;
  const onPageHide = () => {
    if (fired) return;
    fired = true;
    const keepaliveFetch = (url, init = {}) => fetchFn(url, { ...init, keepalive: true });
    void stepRunner.runFlow(
      game,
      { flow: stepRunner.FLOW_AUTOSAVE_FLUSH },
      autosaveHandlers(game, session, { fetchFn: keepaliveFetch, win, hostOnly: true }),
    ).then((outcome) => logAutosave("pagehide_flush_result", { kind: outcome.kind }));
  };
  win.addEventListener("pagehide", onPageHide);
  return () => win.removeEventListener?.("pagehide", onPageHide);
}
