// wasm/shell.js — web app shell: session UX + Event presentation.
// Event.ok.msg → status bar; Event.error_msg → acknowledgement modal (ADR-0010).

import { runWithGeneratingDialog } from "./generating.js";
import { canUseGenWorker, startGenInWorker } from "./gen_client.js";
import { createGenProgressModalSink } from "./gen_progress_rows.js";
import { applyWebStartupAction } from "./startup_contract.js";
import { askWithDialog, FLOW_AUTOSAVE, FLOW_AUTOSAVE_FLUSH, runFlow, SAVE_FAILED_MSG, STEP_DONE } from "./step_runner.js";

/** @typedef {import("./types").GameApi} GameApi */

/** Apply `.ok.msg` to the status bar. */
export function applyOkStatus(statusEl, result) {
  if (!result.ok) return;
  const msg = result.msg;
  if (typeof msg === "string" && msg.length > 0) {
    statusEl.textContent = msg;
    statusEl.className = "";
    return;
  }
  statusEl.textContent = "";
  statusEl.className = "";
}

/** Update the status bar from a successful exec result only. */
export function applyEventStatus(statusEl, result) {
  applyOkStatus(statusEl, result);
}

/** Clear the status bar (same as a successful exec with no message). */
export function clearEventStatus(statusEl) {
  applyEventStatus(statusEl, { ok: true, msg: null });
}

export const CURRENT_FILE_DESKTOP_ID = "current-file-desktop";
export const CURRENT_FILE_UNSAVED_LABEL = "unsaved";
export const WRITE_CONTEXT_EVENT_OPEN_SUCCESS = "open_success";
export const WRITE_CONTEXT_EVENT_NEW_GAME_SUCCESS = "new_game_success";
export const WRITE_CONTEXT_EVENT_IMPORT_SUCCESS = "import_success";
export const WRITE_CONTEXT_EVENT_PASTE_SUCCESS = "paste_success";

export const REQUIRED_STARTUP_READY_KEYS = ["default_save_filename"];

const CURRENT_FILE_PATH = "./current-file";
const CURRENT_FILE_EXISTS_PATH = "./current-file-exists";
const FILENAME_HEADER = "X-Sudoku-Filename";
const RESTORE_COPY_HEADER = "X-Sudoku-Restore-Copy";
const CLIENT_LOG_PATH = "./client-log";
const DEFAULT_CLIENT_LOG_LEVEL = "info";
const CLIENT_LOG_LEVEL_STATE = "__SUDOKU_CLIENT_LOG_LEVEL";
const LOG_LEVEL_DEBUG = "debug";
const LOG_LEVEL_INFO = "info";
const LOG_LEVEL_WARN = "warn";
const LOG_LEVEL_ERR = "err";
const LOG_LEVEL_FATAL = "fatal";

const LOG_LEVEL_RANK = {
  [LOG_LEVEL_DEBUG]: 0,
  [LOG_LEVEL_INFO]: 1,
  [LOG_LEVEL_WARN]: 2,
  [LOG_LEVEL_ERR]: 3,
  [LOG_LEVEL_FATAL]: 4,
};

function clientLogConsoleEnabled() {
  return globalThis.__SUDOKU_LOG === true;
}

function clientLogPostEnabled() {
  return globalThis.__SUDOKU_LOG_POST === true;
}

function consoleWriterForLevel(level) {
  if (level === LOG_LEVEL_WARN) return console.warn;
  if (level === LOG_LEVEL_ERR || level === LOG_LEVEL_FATAL) return console.error;
  if (level === LOG_LEVEL_DEBUG) return console.debug ?? console.info;
  return console.info;
}

function normalizedClientLogLevel(level) {
  if (
    level === LOG_LEVEL_DEBUG ||
    level === LOG_LEVEL_INFO ||
    level === LOG_LEVEL_WARN ||
    level === LOG_LEVEL_ERR ||
    level === LOG_LEVEL_FATAL
  ) {
    return level;
  }
  return DEFAULT_CLIENT_LOG_LEVEL;
}

function formatClientLogLine(scopeName, eventName, details) {
  let detailsText = "";
  try {
    detailsText = JSON.stringify(details);
  } catch {
    detailsText = "{}";
  }
  return `[${scopeName}] ${eventName} ${detailsText}`;
}

function normalizedClientLogLevelFromWire(level) {
  if (typeof level === "number" && Number.isFinite(level)) {
    const names = [LOG_LEVEL_DEBUG, LOG_LEVEL_INFO, LOG_LEVEL_WARN, LOG_LEVEL_ERR, LOG_LEVEL_FATAL];
    return names[level] ?? DEFAULT_CLIENT_LOG_LEVEL;
  }
  return normalizedClientLogLevel(level);
}

function effectiveClientLogLevel() {
  return normalizedClientLogLevelFromWire(globalThis[CLIENT_LOG_LEVEL_STATE]);
}

function shouldEmitClientLog(level) {
  const resolvedLevel = normalizedClientLogLevel(level);
  return LOG_LEVEL_RANK[resolvedLevel] >= LOG_LEVEL_RANK[effectiveClientLogLevel()];
}

/** Set threshold used by JS console/client-log transport. */
export function setClientLogLevel(level) {
  globalThis[CLIENT_LOG_LEVEL_STATE] = normalizedClientLogLevelFromWire(level);
}

/**
 * Structured client-side diagnostics transport.
 * Console output and host posting are independently toggled via globals:
 * - __SUDOKU_LOG (console)
 * - __SUDOKU_LOG_POST (/client-log)
 * @param {string} scope
 * @param {"debug"|"info"|"warn"|"err"|string} level
 * @param {string} event
 * @param {Record<string, unknown>} [details]
 * @returns {void}
 */
export function clientLog(scope, level, event, details = {}) {
  const scopeName = typeof scope === "string" && scope.length > 0 ? scope : "client";
  const eventName = typeof event === "string" && event.length > 0 ? event : "event";
  const resolvedLevel = normalizedClientLogLevel(level);
  if (!shouldEmitClientLog(resolvedLevel)) return;
  if (clientLogConsoleEnabled()) {
    const writer = consoleWriterForLevel(resolvedLevel);
    writer(formatClientLogLine(scopeName, eventName, details));
  }
  if (!clientLogPostEnabled()) return;
  const fetchFn = globalThis.fetch;
  if (typeof fetchFn !== "function") return;
  // Keep lane/stage aliases for compatibility with historical diagnostics.
  const payload = {
    level: resolvedLevel,
    scope: scopeName,
    event: eventName,
    lane: scopeName,
    stage: eventName,
    details,
  };
  void fetchFn(CLIENT_LOG_PATH, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(payload),
    keepalive: true,
  }).catch(() => {});
}

function autosaveLevelForStage(stage, details = {}) {
  if (stage === "persist_failed") return "warn";
  if (stage === "pagehide_flush_result" && details.kind === "show_error") return "warn";
  if (stage === "persist_ok" || stage === "pagehide_flush_result") return "info";
  return "debug";
}

function logAutosave(stage, details = {}) {
  const level = autosaveLevelForStage(stage, details);
  clientLog("autosave", level, stage, details);
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
  if (statusEl) applyEventStatus(statusEl, { ok: true, msg: msg ?? null });
  syncCurrentFileLabels(session);
}

/** Canonical config/status update path for successful settings-style outcomes. */
export function applyConfigOutcomeStatus(
  session,
  game,
  statusEl,
  result,
) {
  if (!result?.ok) return false;
  applySessionOutcomeStatus(session, statusEl, {
    config: game.getConfig(),
    msg: result.msg ?? null,
  });
  return true;
}

/** Canonical state/legend command outcome path for successful play/edit commands. */
export function applyCommandOutcomeStatus(
  session,
  statusEl,
  result,
  { legend } = {},
) {
  if (!result?.ok) return false;
  applySessionOutcome(session, {
    state: result.state,
    legend,
  });
  applyEventStatus(statusEl, result);
  return true;
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

/** Hint exec → status bar only; `.ok.msg` hint semantics never use the error modal. */
export function applyHintExecStatus(statusEl, errorModal, result) {
  if (!result.ok) {
    applyExecResult(statusEl, errorModal, result);
    return;
  }
  if (typeof result.msg === "string" && result.msg.length > 0) {
    applyEventStatus(statusEl, result);
  }
}

/** Save current game — returns opaque SUD0 bytes or `{ ok: false, error }`. */
/** @param {GameApi} game */
export function save(game) {
  return game.serialize();
}

/** Save-as is the same bytes path until a picker supplies a target name. */
/** @param {GameApi} game */
export function saveAs(game) {
  return game.serialize();
}

/** Restore game state from opaque SUD0 bytes. */
/** @param {GameApi} game */
export function open(game, bytes, { name } = {}) {
  const result = name ? game.deserialize(bytes, { name }) : game.deserialize(bytes);
  if (!result.ok) return result;
  return { ok: true, state: result.state, msg: result.msg ?? null };
}

export { formatGenProgress } from "./gen_progress_format.js";
import { formatGenProgress } from "./gen_progress_format.js";

/** Merge raw wire progress sink + formatted UI sink for generator updates. */
function mergeGenProgressHandlers(onProgressWire, onGenProgress) {
  if (!onProgressWire && !onGenProgress) return undefined;
  return (phase, a, b) => {
    onProgressWire?.(phase, a, b);
    onGenProgress?.(formatGenProgress(phase, a, b));
  };
}

/** Yield so the status bar can paint before a blocking wasm `init`. */
export function waitForStatusPaint() {
  if (typeof requestAnimationFrame !== "function") return Promise.resolve();
  return new Promise((resolve) => {
    requestAnimationFrame(() => requestAnimationFrame(resolve));
  });
}

/** Start a fresh game at the given difficulty (PlayerDifficulty wire values). */
/** @param {GameApi} game */
export function newGame(game, { difficulty = 1, logLevel = 1, onGenProgress } = {}) {
  game.setGenProgressListener?.(
    onGenProgress ? (phase, a, b) => onGenProgress(formatGenProgress(phase, a, b)) : null,
  );
  try {
    const result = game.init({ difficulty, logLevel });
    if (!result.ok) return result;
    return {
      ok: true,
      state: game.getState(),
      legend: game.getLegend(),
      config: game.getConfig(),
      msg: result.msg ?? null,
    };
  } finally {
    game.setGenProgressListener?.(null);
  }
}

/** Load a one-line puzzle via `importPuzzle` (paste, file import, export round-trip). */
/** @param {GameApi} game */
export function applyImportedLine(game, line) {
  const result = game.importPuzzle(line);
  if (!result.ok) return result;
  return {
    ok: true,
    state: game.getState(),
    legend: game.getLegend(),
    config: game.getConfig(),
    msg: result.msg ?? null,
  };
}

/** Worker/sync gen handoff: same codec as import; status reflects New, not Import. */
/** @param {GameApi} game */
export function applyGeneratedLineAsNewGame(game, line, { difficulty } = {}) {
  const result =
    difficulty != null && typeof game.importPuzzleNewGame === "function"
      ? (() => {
          const importResult = game.importPuzzleNewGame(line, difficulty);
          if (!importResult.ok) return importResult;
          return {
            ok: true,
            state: game.getState(),
            legend: game.getLegend(),
            config: game.getConfig(),
            msg: importResult.msg ?? null,
          };
        })()
      : applyImportedLine(game, line);
  if (!result.ok) return result;
  return { ...result, msg: result.msg ?? null };
}

/** Keys the web shell requires on `boot.config` after `initializeWebSession`. */
export const REQUIRED_WEB_BOOT_CONFIG_KEYS = [
  "difficulty",
  "log_level",
  "theme",
  "show_region",
  "warn_solvability",
  "auto_restore",
  "auto_new",
  "auto_save",
];

export function assertWebBootConfig(config, label = "boot.config") {
  if (!config || typeof config !== "object") {
    throw new Error(`${label}: missing config object`);
  }
  for (const key of REQUIRED_WEB_BOOT_CONFIG_KEYS) {
    if (config[key] === undefined) {
      throw new Error(`${label}: missing ${key}`);
    }
  }
}

/** Required keys from `/host-config.json` before engine bootstrap. */
export function assertHostStartupConfig(config, label = "host-config") {
  assertWebBootConfig(config, label);
  if (config.default_save_filename === undefined) {
    throw new Error(`${label}: missing default_save_filename`);
  }
  if (typeof config.startup_context_event !== "string" || config.startup_context_event.length === 0) {
    throw new Error(`${label}: missing startup_context_event`);
  }
  if (config.startup_status === undefined) {
    throw new Error(`${label}: missing startup_status`);
  }
}

export async function fetchHostStartupConfig(fetchFn = globalThis.fetch) {
  const res = await fetchFn("./host-config.json");
  if (!res.ok) throw new Error(`host-config fetch failed: ${res.status}`);
  return res.json();
}

/** Startup restore fetch adapter: host path -> bytes or normalized restore error. */
async function fetchStartupSaveBytes(path, fetchFn = globalThis.fetch) {
  const res = await fetchFn(path);
  if (!res.ok) return { ok: false, error: `startup restore fetch failed: ${res.status}` };
  return { ok: true, bytes: new Uint8Array(await res.arrayBuffer()) };
}

/** Bridge host config JSON to wasm bootstrap wire names and booleans. */
/** @param {GameApi} game */
export function bootstrapEngineFromHostConfig(game, hostCfg) {
  return game.bootstrapHostConfig({
    difficulty: hostCfg.difficulty,
    logLevel: hostCfg.log_level,
    theme: hostCfg.theme,
    show_region: hostCfg.show_region,
    warn_solvability: hostCfg.warn_solvability === true,
    auto_restore: hostCfg.auto_restore === true,
    auto_new: hostCfg.auto_new === true,
    auto_save: hostCfg.auto_save === true,
  });
}

const DIFFICULTY_WIRE = { 1: "easy", 2: "medium", 3: "hard" };
const LOG_WIRE = ["debug", "info", "warn", "err", "fatal"];

/** Normalize config difficulty enum/wire value to persisted settings string. */
export function difficultyName(config) {
  if (typeof config.difficulty === "string") return config.difficulty;
  return DIFFICULTY_WIRE[config.difficulty] ?? "easy";
}

/** Normalize config log level enum/wire value to persisted settings string. */
export function logLevelName(config) {
  if (typeof config.log_level === "string") return config.log_level;
  return LOG_WIRE[config.log_level] ?? "info";
}

/** User-editable settings.json fields (excludes renderer choice). */
export function hostSettingsForPersist(config) {
  const theme = config.theme === "light" || config.theme === "system" ? config.theme : "dark";
  return {
    difficulty: difficultyName(config),
    log_level: logLevelName(config),
    theme,
    show_region: config.show_region === true,
    warn_solvability: config.warn_solvability === true,
    auto_restore: config.auto_restore === true,
    auto_new: config.auto_new === true,
    auto_save: config.auto_save === true,
  };
}

/** @deprecated use hostSettingsForPersist */
export function hostViewPrefsForPersist(config) {
  return hostSettingsForPersist(config);
}

/** Persist player prefs to host settings.json (web serve POST). */
export async function persistHostSettings(config, fetchFn = globalThis.fetch) {
  const res = await fetchFn("./settings.json", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(hostSettingsForPersist(config)),
  });
  if (!res.ok) throw new Error(`settings persist failed: ${res.status}`);
}

/** Write SUD0 bytes as the host copy (`/current-file`); `restoreCopy` keeps it out of the visible folder. */
export async function persistCurrentFileBytes(
  bytes,
  fetchFn = globalThis.fetch,
  saveName = null,
  { restoreCopy = false } = {},
) {
  const headers = { "Content-Type": "application/octet-stream" };
  if (typeof saveName === "string" && saveName.length > 0) headers[FILENAME_HEADER] = saveName;
  if (restoreCopy === true) headers[RESTORE_COPY_HEADER] = "true";
  const res = await fetchFn(CURRENT_FILE_PATH, {
    method: "POST",
    headers,
    body: bytes,
  });
  if (!res.ok) return { ok: false, error: `current-file persist failed: ${res.status}` };
  return { ok: true };
}

/** Whether the host's write of `saveName` would land on an existing file the user can see. */
export async function hostCurrentFileExists(saveName, fetchFn = globalThis.fetch) {
  const headers = {};
  if (typeof saveName === "string" && saveName.length > 0) headers[FILENAME_HEADER] = saveName;
  const res = await fetchFn(CURRENT_FILE_EXISTS_PATH, { headers });
  if (!res.ok) throw new Error(`current-file check failed: ${res.status}`);
  const payload = await res.json();
  return payload?.exists === true;
}

/** Record a lifecycle event (open/new/import/paste/startup) in the core FileSession. */
/** @param {GameApi} game */
export function recordFileSessionEvent(game, eventName, name = null) {
  return game.fileSessionEvent(eventName, name);
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
  return {
    resolveDefaultTarget: () => session.default_save_filename,
    checkTarget: (name) => {
      if (bound()) return session.boundTargetExists?.() === true;
      return hostCurrentFileExists(name, fetchFn);
    },
    ask: (step) => askWithDialog(step, win),
    write: async (name) => {
      const serialized = game.serialize();
      if (!serialized.ok) return serialized;
      let written = name;
      if (bound() && !hostOnly) {
        const boundSaved = await session.boundSnapshotWriter(serialized.bytes, name);
        if (!boundSaved?.ok) return boundSaved ?? { ok: false, error: SAVE_FAILED_MSG };
        if (typeof boundSaved.name === "string" && boundSaved.name.length > 0) written = boundSaved.name;
      }
      const hosted = await persistCurrentFileBytes(serialized.bytes, fetchFn, written, { restoreCopy: bound() });
      if (!hosted.ok) return hosted;
      session.boundFilename = written;
      syncCurrentFileLabels(session);
      return { ok: true, name: written };
    },
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
    void runFlow(
      game,
      { flow: FLOW_AUTOSAVE_FLUSH },
      autosaveHandlers(game, session, { fetchFn: keepaliveFetch, win, hostOnly: true }),
    ).then((outcome) => logAutosave("pagehide_flush_result", { kind: outcome.kind }));
  };
  win.addEventListener("pagehide", onPageHide);
  return () => win.removeEventListener?.("pagehide", onPageHide);
}

/** Normalize boot outcome into the canonical web session shape. */
export function createWebSessionFromStartup(ready) {
  for (const key of REQUIRED_STARTUP_READY_KEYS) {
    if (ready?.[key] === undefined) {
      throw new Error(`startup ready payload: missing ${key}`);
    }
  }
  return {
    state: ready.state,
    legend: ready.legend,
    config: ready.config,
    default_save_filename: ready.default_save_filename,
    boundFilename: ready.kind === "restore" ? ready.default_save_filename : null,
    boundSnapshotWriter: null,
    boundTargetExists: null,
  };
}

/** Record the startup write-context event; a restored game continues its file. */
/** @param {GameApi} game */
export function recordStartupFileSession(game, ready) {
  const name = ready.kind === "restore" ? ready.default_save_filename : null;
  return recordFileSessionEvent(game, ready.startup_context_event, name);
}

/** Canonical load/import/paste outcome path: bind session, record the event in core, apply outcome+status. */
/** @param {GameApi} game */
export function applyLoadedSessionOutcome(
  game,
  session,
  statusEl,
  result,
  {
    writeContextEventName,
    fileHandle = null,
    boundFilename = null,
    workingFile = null,
    legend = result?.legend,
    config = result?.config,
    msg = result?.msg ?? null,
  } = {},
) {
  session.fileHandle = fileHandle;
  session.boundFilename = boundFilename;
  const recorded = recordFileSessionEvent(game, writeContextEventName, workingFile);
  if (!recorded.ok) return recorded;
  applySessionOutcomeStatus(session, statusEl, {
    state: result?.state,
    legend,
    config,
    msg,
  });
  return { ok: true };
}

/** Run the core autosave flow after `commandName`; core decides whether anything is written. */
/** @param {GameApi} game */
export function startAutoSavePolicy(
  game,
  session,
  commandName,
  {
    fetchFn = globalThis.fetch,
    win = globalThis,
    onError,
    commandMeta = null,
  } = {},
) {
  const commandText =
    typeof commandMeta?.command_text === "string" && commandMeta.command_text.length > 0
      ? commandMeta.command_text
      : commandName;
  const handlers = autosaveHandlers(game, session, {
    fetchFn,
    win,
    onError: (failed) => {
      logAutosave("persist_failed", { command: commandName, command_text: commandText, error: failed?.error ?? null });
      onError?.(failed);
    },
  });
  return runFlow(game, { flow: FLOW_AUTOSAVE, command: commandName }, handlers).then((outcome) => {
    if (outcome.kind === STEP_DONE) logAutosave("persist_ok", { command: commandName, command_text: commandText });
    return outcome;
  });
}

/**
 * Host config bootstrap + startup policy payload from /host-config.json.
 */
/** @param {GameApi} game */
export async function initializeWebSession(game, { fetchFn } = {}) {
  // Phase 1: fetch host startup contract payload and validate required keys.
  const hostCfg = await fetchHostStartupConfig(fetchFn);
  assertHostStartupConfig(hostCfg);
  setClientLogLevel(hostCfg.log_level);
  // Phase 2: bootstrap engine config from host contract (difficulty/theme/flags).
  const boot = bootstrapEngineFromHostConfig(game, hostCfg);
  if (!boot.ok) return boot;

  // Phase 3: return canonical boot/session shape for page entry wiring.
  return {
    ok: true,
    kind: "empty",
    state: game.getState(),
    legend: game.getLegend(),
    config: game.getConfig(),
    msg: boot.msg ?? null,
    default_save_filename: hostCfg.default_save_filename,
    startup_action: hostCfg.startup_action ?? "idle",
    startup_context_event: hostCfg.startup_context_event,
    on_restore_solved: hostCfg.on_restore_solved ?? "prompt",
    startup_status: hostCfg.startup_status ?? null,
    startup_save_path: hostCfg.startup_save_path ?? null,
  };
}

/** Applies host startup policy: restore/new/idle on the host-resolved startup contract. */
/** @param {GameApi} game */
export async function offerInitialNewGame(
  game,
  boot,
  generatingModal,
  { genWorker, fetchFn } = {},
) {
  // Phase 4: apply startup action contract (`restore`/`new`/`idle`) and return normalized outcome.
  return applyWebStartupAction(game, boot, {
    fetchStartupSaveBytes: (restorePath) => fetchStartupSaveBytes(restorePath, fetchFn),
    openFromSaveBytes: (bytes, _restorePath) =>
      typeof game.restore === "function" ? game.restore(bytes) : open(game, bytes),
    startNewGame: async (cfg, startupOptions = {}) => {
      const { difficulty, log_level: logLevel } = cfg;
      if (difficulty == null || logLevel == null) {
        return { ok: false, error: "missing engine config after host bootstrap", kind: "empty" };
      }
      return newGameWithGeneratingModal(game, generatingModal, {
        difficulty,
        logLevel,
        genWorker,
        ...(startupOptions ?? {}),
      });
    },
  });
}

/** Resolve effective difficulty/log level for generation from call options or live engine config. */
function genWireFromEngine(game, options) {
  const cfg = game.getConfig();
  return {
    difficulty: options.difficulty ?? cfg.difficulty,
    logLevel: options.logLevel ?? cfg.log_level,
  };
}

/** Worker gen → import on main; modal + optional Cancel. */
/** @param {GameApi} game */
export async function newGameWithWorkerGen(
  game,
  modal,
  { difficulty, logLevel, genWorker, onGenProgress, onProgressWire, autoContinue = false } = {},
) {
  const wire = genWireFromEngine(game, { difficulty, logLevel });
  const onProgress = mergeGenProgressHandlers(onProgressWire, onGenProgress);
  return runWithGeneratingDialog(modal, async (cancelRef) => {
    const { promise, cancel } = startGenInWorker({
      workerUrl: genWorker.workerUrl,
      wasmBytes: genWorker.wasmBytes,
      difficulty: wire.difficulty,
      logLevel: wire.logLevel,
      onProgress,
      WorkerCtor: genWorker.WorkerCtor,
      fetchFn: genWorker.fetchFn,
    });
    cancelRef.fn = cancel;
    const gen = await promise;
    if (gen.cancelled || !gen.ok) return gen;
    return applyGeneratedLineAsNewGame(game, gen.line, { difficulty: wire.difficulty });
  }, { autoContinue });
}

/** Main-thread `generatePuzzle` + import (modal spinner; blocks main thread). */
/** @param {GameApi} game */
export async function newGameWithSyncGenerate(
  game,
  modal,
  { difficulty, logLevel, onGenProgress, onProgressWire, autoContinue = false } = {},
) {
  const wire = genWireFromEngine(game, { difficulty, logLevel });
  const onProgress = mergeGenProgressHandlers(onProgressWire, onGenProgress);
  return runWithGeneratingDialog(modal, async (cancelRef) => {
    cancelRef.fn = () => game.requestGenAbort?.();
    game.setGenProgressListener?.(onProgress ?? null);
    try {
      if (typeof game.generatePuzzle !== "function") {
        return newGame(game, { difficulty: wire.difficulty, logLevel: wire.logLevel });
      }
      const gen = game.generatePuzzle({ difficulty: wire.difficulty, logLevel: wire.logLevel });
      if (!gen.ok) {
        if (gen.error === "cancelled") return { ok: false, cancelled: true };
        return gen;
      }
      return applyGeneratedLineAsNewGame(game, gen.line, { difficulty: wire.difficulty });
    } finally {
      game.setGenProgressListener?.(null);
    }
  }, { autoContinue });
}

function shouldFallbackFromWorker(result) {
  if (result.ok || result.cancelled) return false;
  const err = result.error ?? "";
  // Only when Workers are missing — sync gen blocks the main thread (Cancel cannot run).
  return err === "workers unavailable";
}

/** First load / New: prefer worker gen; fall back to main-thread generate or legacy `init`. */
/** @param {GameApi} game */
export async function newGameWithGeneratingModal(game, modal, options = {}) {
  const { genWorker, onGenProgress, autoContinue = false } = options;
  const wire = genWireFromEngine(game, options);
  const rowSink =
    typeof modal?.renderProgressRows === "function" ? createGenProgressModalSink(modal) : null;
  const onProgressWire = rowSink ? (phase, a, b) => rowSink.push(phase, a, b) : undefined;
  const genProgress = { onGenProgress, onProgressWire };
  if (genWorker && canUseGenWorker()) {
    const workerResult = await newGameWithWorkerGen(game, modal, {
      difficulty: wire.difficulty,
      logLevel: wire.logLevel,
      genWorker,
      autoContinue,
      ...genProgress,
    });
    if (!shouldFallbackFromWorker(workerResult)) return workerResult;
    return newGameWithSyncGenerate(game, modal, {
      difficulty: wire.difficulty,
      logLevel: wire.logLevel,
      autoContinue,
      ...genProgress,
    });
  }
  if (typeof game.generatePuzzle === "function") {
    return newGameWithSyncGenerate(game, modal, {
      difficulty: wire.difficulty,
      logLevel: wire.logLevel,
      autoContinue,
      ...genProgress,
    });
  }
  return runWithGeneratingDialog(
    modal,
    () => Promise.resolve(newGame(game, { difficulty: wire.difficulty, logLevel: wire.logLevel })),
    { autoContinue },
  );
}

export { canUseGenWorker };

/** Export the current grid as an 81-byte one-line puzzle string. */
/** @param {GameApi} game */
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
/** @param {GameApi} game */
export function puzzleLineForCopy(game) {
  const exported = exportPuzzle(game);
  if (!exported.ok) return exported;
  return { ok: true, text: new TextDecoder().decode(exported.bytes) };
}

/**
 * Copy current grid via `exportPuzzle`. Prefer `startCopyPuzzleOnClick` in UI handlers
 * so `writeText` runs in the same turn as the user click (activation).
 */
/** @param {GameApi} game */
export async function copyPuzzleToClipboard(game, options = {}) {
  const line = puzzleLineForCopy(game);
  if (!line.ok) return line;
  return writeClipboardText(line.text, options);
}

/** Start clipboard write in the click turn; returns a Promise for tests. */
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

/** Import a one-line puzzle from page-read file text; engine owns the codec. */
/** @param {GameApi} game */
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
