// client_log.test.mjs — client log level filtering.

import assert from "node:assert/strict";
import * as clientLog from "./client_log.js";

{
  const originalDebug = console.debug;
  const originalInfo = console.info;
  const originalWarn = console.warn;
  const originalError = console.error;
  const originalFetch = globalThis.fetch;

  const calls = [];
  console.debug = (...args) => calls.push({ level: "debug", args });
  console.info = (...args) => calls.push({ level: "info", args });
  console.warn = (...args) => calls.push({ level: "warn", args });
  console.error = (...args) => calls.push({ level: "err", args });
  globalThis.fetch = async () => ({ ok: true, status: 204 });
  globalThis.__SUDOKU_LOG = true;
  globalThis.__SUDOKU_LOG_POST = false;

  try {
    clientLog.setClientLogLevel(2);
    clientLog.clientLog("startup", "debug", "suppressed_debug");
    clientLog.clientLog("startup", "info", "suppressed_info");
    clientLog.clientLog("startup", "warn", "allowed_warn");
    clientLog.clientLog("startup", "err", "allowed_err");

    const hasText = (needle) => calls.some((c) => String(c.args[0] ?? "").includes(needle));
    assert.equal(hasText("suppressed_debug"), false);
    assert.equal(hasText("suppressed_info"), false);
    assert.equal(hasText("allowed_warn"), true);
    assert.equal(hasText("allowed_err"), true);
  } finally {
    clientLog.setClientLogLevel("info");
    delete globalThis.__SUDOKU_LOG;
    delete globalThis.__SUDOKU_LOG_POST;
    console.debug = originalDebug;
    console.info = originalInfo;
    console.warn = originalWarn;
    console.error = originalError;
    globalThis.fetch = originalFetch;
  }
}
