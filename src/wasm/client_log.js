// client_log.js — client diagnostics: console output and `/client-log` posts, filtered by the host's log level.

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
