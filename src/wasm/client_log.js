// client_log.js — one output path for core and JS log lines: the console and `/client-log` (the host log).
// Core decides which lines run; debug to warn JS lines wait for core while the wasm loads. Err and fatal
// lines never wait: the host writes them through core's logger, which applies the level rule.

const CLIENT_LOG_PATH = "./client-log";
/** Console prefix for a line the host log never got; Android forwards only these `client_log.js` lines to logcat (MainActivity `CLIENT_LOG_UNSENT_PREFIX`). */
export const CLIENT_LOG_UNSENT_PREFIX = "client-log unsent";
const DEFAULT_CLIENT_LOG_LEVEL = "info";
const LOG_LEVEL_DEBUG = "debug";
const LOG_LEVEL_INFO = "info";
const LOG_LEVEL_WARN = "warn";
const LOG_LEVEL_ERR = "err";
const LOG_LEVEL_FATAL = "fatal";
const PENDING_LINES_CAP = 64;

/** @typedef {import("./types").LogLevel} LogLevel */
/** @typedef {{ logEnabled(level: LogLevel): boolean }} LogFilter */
/** @typedef {{ scope: string, level: LogLevel, event: string, details: Record<string, unknown> }} LogLine */

/** @type {LogFilter | null} */
let filter = null;
/** @type {LogLine[]} */
let pending = [];
let droppedWhileLoading = 0;

function consoleWriterForLevel(level) {
  if (level === LOG_LEVEL_WARN) return console.warn;
  if (level === LOG_LEVEL_ERR || level === LOG_LEVEL_FATAL) return console.error;
  if (level === LOG_LEVEL_DEBUG) return console.debug ?? console.info;
  return console.info;
}

/** @returns {LogLevel} */
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
  } catch (err) {
    detailsText = `{"unserializable_details": ${JSON.stringify(err?.message ?? String(err))}}`;
  }
  return `[${scopeName}] ${eventName} ${detailsText}`;
}

/**
 * The host log never got `text`: say so on the console with the reason, so the line is still somewhere.
 * @param {string} text
 * @param {string} reason
 */
function writeUnsent(text, reason) {
  console.error(`${CLIENT_LOG_UNSENT_PREFIX} (${reason}): ${text}`);
}

/** @param {LogLine} line */
function writeLine({ scope, level, event, details }) {
  const text = formatClientLogLine(scope, event, details);
  consoleWriterForLevel(level)(text);
  const fetchFn = globalThis.fetch;
  if (typeof fetchFn !== "function") return writeUnsent(text, "no fetch");
  // Keep lane/stage aliases for compatibility with historical diagnostics.
  const payload = { level, scope, event, lane: scope, stage: event, details };
  void Promise.resolve()
    .then(() =>
      fetchFn(CLIENT_LOG_PATH, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(payload),
        keepalive: true,
      }),
    )
    .then(
      (res) => {
        if (res && res.ok === false) writeUnsent(text, `HTTP ${res.status}`);
      },
      (err) => writeUnsent(text, err?.message ?? String(err)),
    );
}

/**
 * Core filters JS lines from now on; lines logged while the wasm loaded are written if core lets them run.
 * @param {LogFilter} core the loaded game (`glue.loadArtifact`)
 */
export function useCore(core) {
  filter = core;
  const waiting = pending;
  const dropped = droppedWhileLoading;
  pending = [];
  droppedWhileLoading = 0;
  for (const line of waiting) {
    if (core.logEnabled(line.level)) writeLine(line);
  }
  if (dropped > 0) {
    clientLog("client", LOG_LEVEL_WARN, "lines_dropped_while_loading", { dropped, cap: PENDING_LINES_CAP });
  }
}

/**
 * Boot failed before core loaded: write the waiting lines unfiltered (the host log still applies core's level rule).
 * @returns {void}
 */
export function writeWaitingWithoutCore() {
  useCore({ logEnabled: () => true });
}

/**
 * A line core already filtered (`glue.js` `setLogListener`): write it, never filter again.
 * @param {LogLevel} level
 * @param {string} scope
 * @param {string} text
 */
export function coreLine(level, scope, text) {
  writeLine({ scope, level: normalizedClientLogLevel(level), event: text, details: {} });
}

/**
 * Structured client-side diagnostics; core decides whether the level runs.
 * @param {string} scope
 * @param {LogLevel | string} level
 * @param {string} event
 * @param {Record<string, unknown>} [details]
 * @returns {void}
 */
export function clientLog(scope, level, event, details = {}) {
  /** @type {LogLine} */
  const line = {
    scope: typeof scope === "string" && scope.length > 0 ? scope : "client",
    level: normalizedClientLogLevel(level),
    event: typeof event === "string" && event.length > 0 ? event : "event",
    details,
  };
  if (filter === null) {
    if (line.level === LOG_LEVEL_ERR || line.level === LOG_LEVEL_FATAL) return writeLine(line);
    if (pending.length < PENDING_LINES_CAP) pending.push(line);
    else droppedWhileLoading += 1;
    return;
  }
  if (filter.logEnabled(line.level)) writeLine(line);
}

/**
 * The page's first line: written at once, before core loads, so a boot that then fails still shows it started.
 * @param {string} scope
 * @param {string} event
 * @param {Record<string, unknown>} [details]
 * @returns {void}
 */
export function startLine(scope, event, details = {}) {
  writeLine({ scope, level: LOG_LEVEL_INFO, event, details });
}

const UNCAUGHT_LOGGED = Symbol("uncaughtLogged");

/** Where an uncaught `error` event was thrown, as `file:line:column`; empty for a rejection. */
function errorSource(ev) {
  return ev?.filename ? `${ev.filename}:${ev.lineno ?? 0}:${ev.colno ?? 0}` : "";
}

/**
 * After boot is ready or has failed an uncaught error is a bug, not a failed start: log it, show nothing.
 * Before that `page.html` logs it, so each error is logged once whatever the startup state.
 * @param {Window & typeof globalThis} win
 */
export function logUncaughtErrors(win) {
  if (win[UNCAUGHT_LOGGED]) return;
  win[UNCAUGHT_LOGGED] = true;
  const log = (reason, source) =>
    clientLog("page", "err", "uncaught", { error: reason?.message ?? String(reason), source });
  win.addEventListener("error", (ev) => log(ev.error ?? ev.message, errorSource(ev)));
  win.addEventListener("unhandledrejection", (ev) => log(ev.reason, "promise"));
}
