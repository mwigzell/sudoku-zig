// client_log.js — one output path for core and JS log lines: the console and `/client-log` (the host log).
// Core decides which lines run; JS lines wait for core while the wasm loads.

const CLIENT_LOG_PATH = "./client-log";
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
  } catch {
    detailsText = "{}";
  }
  return `[${scopeName}] ${eventName} ${detailsText}`;
}

/** @param {LogLine} line */
function writeLine({ scope, level, event, details }) {
  consoleWriterForLevel(level)(formatClientLogLine(scope, event, details));
  const fetchFn = globalThis.fetch;
  if (typeof fetchFn !== "function") return;
  // Keep lane/stage aliases for compatibility with historical diagnostics.
  const payload = { level, scope, event, lane: scope, stage: event, details };
  void fetchFn(CLIENT_LOG_PATH, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(payload),
    keepalive: true,
  }).catch(() => {});
}

/**
 * Core filters JS lines from now on; lines logged while the wasm loaded are written if core lets them run.
 * @param {LogFilter} core the loaded game (`glue.loadArtifact`)
 */
export function useCore(core) {
  filter = core;
  const waiting = pending;
  pending = [];
  for (const line of waiting) {
    if (core.logEnabled(line.level)) writeLine(line);
  }
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
    if (pending.length < PENDING_LINES_CAP) pending.push(line);
    return;
  }
  if (filter.logEnabled(line.level)) writeLine(line);
}
