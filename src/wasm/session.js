// session.js — the web session: the game core last showed, its bound file, and the file label in the menu bar.

import * as statusBar from "./status_bar.js";

export const CURRENT_FILE_DESKTOP_ID = "current-file-desktop";
export const CURRENT_FILE_UNSAVED_LABEL = "unsaved";

export const REQUIRED_STARTUP_READY_KEYS = ["default_save_filename"];

/** The web session before startup has shown a game: the engine's idle board, no bound file. */
export function createWebSessionFromStartup(boot) {
  for (const key of REQUIRED_STARTUP_READY_KEYS) {
    if (boot?.[key] === undefined) {
      throw new Error(`startup boot payload: missing ${key}`);
    }
  }
  return {
    state: boot.state,
    legend: boot.legend,
    config: boot.config,
    default_save_filename: boot.default_save_filename,
    boundFilename: null,
    boundSnapshotWriter: null,
    boundTargetExists: null,
    boundPickExisting: null,
    boundPickNew: null,
  };
}

/** Bound save target label shown in the menu-bar filename slot. */
export function currentFileLabel(session) {
  const name = session?.boundFilename;
  if (typeof name === "string" && name.length > 0) return name;
  return CURRENT_FILE_UNSAVED_LABEL;
}

/** Keeps desktop/mobile filename chrome in sync with session binding state. */
export function syncCurrentFileLabels(session, root = globalThis.document) {
  if (!root || typeof root.getElementById !== "function") return;
  const label = currentFileLabel(session);
  const desktop = root.getElementById(CURRENT_FILE_DESKTOP_ID);
  if (desktop) desktop.textContent = label;
}

/** Apply a result snapshot to session state without inventing local adapter policy. */
export function applySessionOutcome(
  session,
  { state, legend, config } = {},
) {
  if (state !== undefined) session.state = state;
  if (legend !== undefined) session.legend = legend;
  if (config !== undefined) session.config = config;
}

/** Canonical session+status update path for successful command outcomes. */
export function applySessionOutcomeStatus(
  session,
  statusEl,
  { state, legend, config, msg } = {},
) {
  applySessionOutcome(session, { state, legend, config });
  if (statusEl) statusBar.applyEventStatus(statusEl, { ok: true, msg: msg ?? null });
  syncCurrentFileLabels(session);
}
