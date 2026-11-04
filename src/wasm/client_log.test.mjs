// client_log.test.mjs — core filters JS lines and its own lines reach the same output (console + `/client-log`).

import assert from "node:assert/strict";
import * as clientLog from "./client_log.js";
import { loadGame, openAs, startNewGame } from "./test_support.mjs";

const WARN_RANK = 2;
const CLIENT_LOG_PATH = "./client-log";

/** Capture console writes and `/client-log` posts while `body` runs. */
async function captured(body) {
  const original = { debug: console.debug, info: console.info, warn: console.warn, error: console.error, fetch: globalThis.fetch };
  const lines = [];
  const posts = [];
  console.debug = (line) => lines.push({ level: "debug", line });
  console.info = (line) => lines.push({ level: "info", line });
  console.warn = (line) => lines.push({ level: "warn", line });
  console.error = (line) => lines.push({ level: "err", line });
  globalThis.fetch = async (url, init) => {
    assert.equal(url, CLIENT_LOG_PATH);
    posts.push(JSON.parse(init.body));
    return { ok: true, status: 204 };
  };
  try {
    await body();
  } finally {
    Object.assign(console, { debug: original.debug, info: original.info, warn: original.warn, error: original.error });
    globalThis.fetch = original.fetch;
  }
  return { lines, posts };
}

const game = await loadGame({ logLevel: WARN_RANK });

// Core's filter: with min_level warn, debug and info don't run, warn and err do.
assert.deepEqual(
  ["debug", "info", "warn", "err", "fatal"].map((level) => game.logEnabled(level)),
  [false, false, true, true, true],
);

// Debug lines run only for a debug host build, and then only when min_level allows.
{
  const debugGame = await loadGame({ logLevel: 0 });
  debugGame.setHostBuildInfo({ debug_build: false });
  assert.equal(debugGame.logEnabled("debug"), false, "a release host build never runs debug lines");
  assert.equal(debugGame.logEnabled("info"), true, "a release host build runs info and above");
  debugGame.setHostBuildInfo({ debug_build: true });
  assert.equal(debugGame.logEnabled("debug"), true, "a debug host build runs debug lines when min_level allows");
  assert.equal(game.logEnabled("debug"), false);
}

// JS lines logged before core loads wait, then core filters them; after that core filters each line.
{
  const out = await captured(() => {
    clientLog.clientLog("parity", "debug", "early_debug");
    clientLog.clientLog("parity", "warn", "early_warn");
    clientLog.useCore(game);
    clientLog.clientLog("parity", "debug", "js_debug");
    clientLog.clientLog("parity", "info", "js_info");
    clientLog.clientLog("parity", "warn", "js_warn");
    clientLog.clientLog("parity", "err", "js_err");
  });
  const events = ["early_warn", "js_warn", "js_err"];
  assert.deepEqual(
    out.posts.map((p) => p.event),
    events,
    "only lines core lets run are posted to the host log",
  );
  assert.deepEqual(
    out.lines.map((l) => l.level),
    ["warn", "warn", "err"],
    "the console gets the same lines, by level",
  );
}

// A core line from a flow reaches the console and the host log once, unfiltered by JS.
{
  game.setLogListener(clientLog.coreLine);
  startNewGame(game);
  openAs(game, "parity.sud");
  const out = await captured(() => {
    const step = game.commandStart({ action: "save" });
    assert.equal(step.step, "save", `save reaches its write step, got ${JSON.stringify(step)}`);
    game.flowNext({ input: "wrote", ok: false, error: "disk full" });
  });
  game.setLogListener(null);
  const coreLines = out.posts.filter((p) => p.scope === "flow");
  assert.equal(coreLines.length, 1, `one core line, got ${JSON.stringify(out.posts)}`);
  assert.equal(coreLines[0].level, "err");
  assert.match(coreLines[0].event, /^write of parity\.sud failed: disk full$/);
  assert.ok(out.lines.some((l) => l.level === "err" && l.line.includes("write of parity.sud failed: disk full")));
}
