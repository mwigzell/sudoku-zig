// uncaught_errors.test.mjs — an uncaught page error is logged exactly once whatever the startup state,
// on Android too: the real page boot script, Android head script and client log, on a fake window.

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";

const html = readFileSync(new URL("./artifacts/page.html", import.meta.url), "utf8");
const pageScript = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)]
  .map((m) => m[1])
  .find((body) => body.includes("failBootWith"));
assert.ok(pageScript, "page.html has its boot script");
const bridgeScript = readFileSync(new URL("./android_bridge.js", import.meta.url), "utf8");

/** Java bridge calls that are not log output. */
const NOT_LOGGING = new Set(["notifyWebBootReady", "bootFailedText"]);

let freshCount = 0;

/**
 * An Android page in its first state: head script and boot script run, app_boot not yet.
 * `logged()` counts every line that reaches logcat or the host log: the page's console errors
 * (forwarded to logcat), the client log's POSTs (the host writes them) and Java bridge log calls.
 */
async function androidPage() {
  freshCount += 1;
  const clientLog = await import(`./client_log.js?uncaught=${freshCount}`);
  const listeners = {};
  const out = { page: [], posts: [], native: [] };
  const win = {
    addEventListener: (type, fn) => (listeners[type] ??= []).push(fn),
    __SudokuAndroidBridge: new Proxy(
      {},
      {
        get: (_, name) => (...args) => {
          if (!NOT_LOGGING.has(name)) out.native.push([name, ...args]);
          return "";
        },
      },
    ),
  };
  const context = {
    globalThis: win,
    window: win,
    String,
    Number,
    JSON,
    Date,
    Math,
    Promise,
    console: { error: (...args) => out.page.push(args.map(String).join(" ")), log() {}, info() {}, warn() {} },
    document: { getElementById: () => null },
    navigator: { userAgent: "Mozilla/5.0 (Linux; Android 11; wv)" },
    performance: { now: () => 0 },
    setTimeout: () => 0,
  };
  vm.runInNewContext(bridgeScript, context);
  vm.runInNewContext(pageScript, context);
  const fire = async (type, ev) => {
    for (const fn of listeners[type] ?? []) fn(ev);
    await new Promise((resolve) => setTimeout(resolve, 0));
  };
  return { win, out, fire, clientLog, logged: () => out.page.length + out.posts.length + out.native.length };
}

/** Run `body` with the client log's fetch and console captured into `out`. */
async function capturing(out, body) {
  const original = { fetch: globalThis.fetch, error: console.error };
  globalThis.fetch = async (_url, init) => {
    out.posts.push(JSON.parse(init.body));
    return { ok: true };
  };
  console.error = () => {};
  try {
    await body();
  } finally {
    globalThis.fetch = original.fetch;
    console.error = original.error;
  }
}

const thrown = () => ({ error: new Error("boom"), message: "boom", filename: "app.js", lineno: 3, colno: 7 });
const rejected = () => ({ reason: new Error("nope") });

/** What app_boot does once boot is ready, or once it has failed. */
function bootSettled(page) {
  page.win.__sudokuSignalAndroidBootReady();
  page.clientLog.logUncaughtErrors(page.win);
}

for (const [state, settle] of [
  ["before boot is ready", () => {}],
  ["after boot is ready", bootSettled],
  ["after boot has failed", bootSettled],
]) {
  for (const [kind, type, ev] of [
    ["error", "error", thrown],
    ["rejection", "unhandledrejection", rejected],
  ]) {
    const page = await androidPage();
    await capturing(page.out, async () => {
      settle(page);
      await page.fire(type, ev());
    });
    assert.equal(page.logged(), 1, `${state}, ${kind}: one line, got ${JSON.stringify(page.out)}`);
    assert.deepEqual(page.out.native, [], `${state}, ${kind}: the Java bridge logs nothing itself`);
    const line = page.out.page[0] ?? JSON.stringify(page.out.posts[0]);
    assert.ok(line.includes(kind === "error" ? "boom" : "nope"), `${state}, ${kind}: the message is logged: ${line}`);
    if (kind === "error") assert.ok(line.includes("app.js:3:7"), `${state}: where it was thrown is logged: ${line}`);
  }
}

console.log("uncaught_errors.test.mjs OK");
