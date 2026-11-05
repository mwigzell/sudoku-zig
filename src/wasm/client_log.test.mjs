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

/** A client log with no core yet: each call gets its own module instance. */
let freshCount = 0;
async function freshClientLog() {
  freshCount += 1;
  return import(`./client_log.js?fresh=${freshCount}`);
}

/** Let the POST promise chains settle. */
const settle = () => new Promise((resolve) => setTimeout(resolve, 0));

// Before core loads, err and fatal lines are written at once and never again; lower levels wait.
{
  const log = await freshClientLog();
  const before = await captured(async () => {
    log.clientLog("boot", "info", "early_info");
    log.clientLog("boot", "err", "early_err", { error: "wasm compile failed" });
    log.clientLog("boot", "fatal", "early_fatal");
    await settle();
  });
  assert.deepEqual(
    before.posts.map((p) => p.event),
    ["early_err", "early_fatal"],
    "err and fatal reach the host log before core loads",
  );
  const after = await captured(async () => {
    log.useCore({ logEnabled: () => true });
    await settle();
  });
  assert.deepEqual(
    after.posts.map((p) => p.event),
    ["early_info"],
    "the waiting info line is written when core loads; err and fatal are not written twice",
  );
}

// The page's start line is written at once, before core loads.
{
  const log = await freshClientLog();
  const out = await captured(async () => {
    log.startLine("startup", "module_start", { platform: "web" });
    await settle();
  });
  assert.deepEqual(out.posts.map((p) => [p.level, p.event]), [["info", "module_start"]]);
}

// Boot failed before core loaded: the waiting lines are written anyway.
{
  const log = await freshClientLog();
  const out = await captured(async () => {
    log.clientLog("startup", "debug", "after_first_paint");
    log.clientLog("startup", "info", "host_config_loaded");
    log.writeWaitingWithoutCore();
    await settle();
  });
  assert.deepEqual(out.posts.map((p) => p.event), ["after_first_paint", "host_config_loaded"]);
}

// A line the host log never got is written to the console with the unsent prefix and the reason.
for (const [fail, reason] of [
  [() => Promise.reject(new Error("Failed to fetch")), "Failed to fetch"],
  [() => Promise.resolve({ ok: false, status: 500 }), "HTTP 500"],
]) {
  const log = await freshClientLog();
  const out = await captured(async () => {
    globalThis.fetch = fail;
    log.clientLog("startup", "err", "boot_failed", { error: "x" });
    await settle();
  });
  const unsent = out.lines.filter((l) => l.line.startsWith(log.CLIENT_LOG_UNSENT_PREFIX));
  assert.equal(unsent.length, 1, `one unsent line, got ${JSON.stringify(out.lines)}`);
  assert.ok(unsent[0].line.includes(`(${reason})`), unsent[0].line);
  assert.ok(unsent[0].line.includes("[startup] boot_failed"), unsent[0].line);
}

// Lines past the waiting cap are counted and reported when core loads, not dropped silently.
{
  const log = await freshClientLog();
  const cap = 64;
  const out = await captured(async () => {
    for (let i = 0; i < cap + 3; i += 1) log.clientLog("load", "info", `line_${i}`);
    log.useCore({ logEnabled: () => true });
    await settle();
  });
  const dropped = out.posts.find((p) => p.event === "lines_dropped_while_loading");
  assert.ok(dropped, "a dropped-lines line is written");
  assert.equal(dropped.details.dropped, 3);
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
