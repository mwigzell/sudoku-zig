#!/usr/bin/env node
// memory-check.mjs — a long play session on the Android emulator, driven through the WebView's DevTools socket;
// prints process memory, wasm memory, open fds and loopback CLOSE_WAIT sockets every few games.
//
// Usage: node scripts/memory-check.mjs [games] [--no-autosave] [--every=N] [--smaps=DIR]   (debug APK, one emulator)
// --smaps=DIR writes the app's /proc/<pid>/smaps at every checkpoint, to diff mappings between them.
// It clears the app and deletes the default save file first, so it refuses to run on a real device.

import { execFileSync } from "node:child_process";
import { writeFileSync } from "node:fs";

const APP = "com.wigzell.sudoku_zig";
const DEFAULT_SAVE_FILE = "/sdcard/Download/Sudoku/sudoku.sud";
/** WebView runs the page in its own sandboxed process. */
const RENDERER_PROCESS = "webview:sandboxed_process";
const DEVTOOLS_PORT = 9333;
const DEFAULT_GAMES = 20;
const CHECK_EVERY_GAMES = 5;
/** Wrong digits played (and undone) per game, and the undo/redo run after each solve. */
const WRONG_MOVES_PER_GAME = 5;
const UNDO_REDO_RUN = 10;
/** smaps output runs to several MB. */
const ADB_MAX_OUTPUT = 64 * 1024 * 1024;
const STEP_MS = 120;
const POLL_MS = 200;
const LAUNCH_WAIT_MS = 20000;
const GENERATE_WAIT_MS = 90000;
const HINT_WAIT_MS = 5000;
/** The digit in core's placement hint ("G1 takes 4."). */
const PLACEMENT_DIGIT = /takes (\d)\./;
/** /proc/net/tcp state for CLOSE_WAIT, and 127.0.0.1 in its hex address form. */
const TCP_CLOSE_WAIT = "08";
const LOOPBACK_HEX = "0100007F:";

const adb = (...args) => execFileSync("adb", args, { encoding: "utf8", maxBuffer: ADB_MAX_OUTPUT }).trim();
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/** Exactly one device, and it is an emulator. */
function requireOneEmulator() {
  const devices = adb("devices").split("\n").slice(1).filter((l) => l.endsWith("\tdevice"));
  if (devices.length !== 1) throw new Error(`expected exactly one connected device, found ${devices.length}`);
  if (adb("shell", "getprop", "ro.kernel.qemu") !== "1" && !devices[0].startsWith("emulator-")) {
    throw new Error("refusing to run on a real device: the check clears the app and deletes its default save file");
  }
}

/** Launch a cleared app with no default save file, so no startup prompt or picker interrupts the session; returns its pid once the WebView's DevTools socket is up. */
async function launchFreshApp() {
  adb("shell", "am", "force-stop", APP);
  adb("shell", "pm", "clear", APP);
  adb("shell", "rm", "-f", DEFAULT_SAVE_FILE);
  adb("shell", "am", "start", "-W", "-n", `${APP}/.MainActivity`);
  const deadline = Date.now() + LAUNCH_WAIT_MS;
  while (Date.now() < deadline) {
    const pid = adb("shell", "pidof", APP);
    if (pid && adb("shell", "cat", "/proc/net/unix").includes(`webview_devtools_remote_${pid}`)) return pid;
    await sleep(POLL_MS);
  }
  throw new Error("the app's WebView DevTools socket did not appear");
}

/**
 * A DevTools Protocol connection to the app's page.
 * @param {string} pid
 * @returns {Promise<{ send: (method: string, params?: object) => Promise<any>, close: () => void }>}
 */
async function connectPage(pid) {
  adb("forward", `tcp:${DEVTOOLS_PORT}`, `localabstract:webview_devtools_remote_${pid}`);
  const targets = await (await fetch(`http://127.0.0.1:${DEVTOOLS_PORT}/json`)).json();
  const page = targets.find((t) => t.type === "page");
  if (!page) throw new Error("no page target in the WebView");
  const ws = new WebSocket(page.webSocketDebuggerUrl);
  await new Promise((resolve, reject) => {
    ws.onopen = resolve;
    ws.onerror = () => reject(new Error("DevTools WebSocket failed to open"));
  });
  let nextId = 1;
  const pending = new Map();
  ws.onmessage = (event) => {
    const msg = JSON.parse(event.data);
    const waiter = pending.get(msg.id);
    if (!waiter) return;
    pending.delete(msg.id);
    if (msg.error) waiter.reject(new Error(msg.error.message));
    else waiter.resolve(msg.result);
  };
  const send = (method, params = {}) =>
    new Promise((resolve, reject) => {
      const id = nextId++;
      pending.set(id, { resolve, reject });
      ws.send(JSON.stringify({ id, method, params }));
    });
  return { send, close: () => ws.close() };
}

/** Runs `expression` in the page and returns its value. */
async function evaluate(cdp, expression) {
  const r = await cdp.send("Runtime.evaluate", { expression, awaitPromise: true, returnByValue: true });
  if (r.exceptionDetails) throw new Error(r.exceptionDetails.exception?.description ?? r.exceptionDetails.text);
  return r.result.value;
}

/** Polls `expression` until it is truthy, answering any prompt that opens meanwhile. */
async function waitFor(cdp, expression, timeoutMs, what) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    await answerPrompt(cdp);
    if (await evaluate(cdp, expression)) return;
    if (await evaluate(cdp, "document.hidden")) throw new Error(`the app left the screen while waiting for ${what}`);
    await sleep(POLL_MS);
  }
  throw new Error(`timed out waiting for ${what}`);
}

/** Answers an open prompt with its first button, logging what it asked. */
async function answerPrompt(cdp) {
  const text = await evaluate(cdp, "__mc.open('#prompt-dialog-button-1') ? document.querySelector('#prompt-dialog-text').textContent : ''");
  if (!text) return false;
  console.log(`answering prompt: ${text}`);
  await evaluate(cdp, "__mc.click('#prompt-dialog-button-1')");
  await sleep(STEP_MS);
  return true;
}

/** Page-side helpers, installed once per page load. */
const PAGE_HELPERS = `
  window.__mc = {
    open: (sel) => { const el = document.querySelector(sel); return !!el && !el.hidden && !el.closest('[hidden]'); },
    click: (sel) => { const el = document.querySelector(sel); if (!el || el.disabled) return false; el.click(); return true; },
    emptyCells: () => [...document.querySelectorAll('#board [data-row][data-col]')].filter((c) => c.textContent === ''),
    selectEmpty: () => { const c = window.__mc.emptyCells()[0]; if (!c) return false; c.click(); return true; },
    status: () => document.querySelector('#status-bar')?.textContent ?? '',
    pad: (key) => window.__mc.click('#play-pad [data-play-key="' + key + '"]'),
  };
  true`;

/** Sets Auto Save to `on`. */
async function setAutoSave(cdp, on) {
  await evaluate(cdp, `(document.querySelector('#file-auto-save').getAttribute('aria-checked') === 'true') === ${on} || __mc.click('#file-auto-save')`);
  await sleep(STEP_MS);
  await answerPrompt(cdp);
}

/** File → New → Easy, answering any prompt, then Continue once the puzzle is ready. */
async function startEasyGame(cdp) {
  await evaluate(cdp, "__mc.click('#file-new')");
  await waitFor(cdp, "[...document.querySelectorAll('.new-difficulty-btn')].some((b) => b.offsetParent)", GENERATE_WAIT_MS, "the difficulty choice");
  await evaluate(cdp, "[...document.querySelectorAll('.new-difficulty-btn')].find((b) => b.textContent.trim() === 'Easy').click()");
  await finishGenerating(cdp);
}

/** Waits for the generated puzzle and presses Continue. */
async function finishGenerating(cdp) {
  await waitFor(cdp, "!document.querySelector('#generating-modal-continue').disabled", GENERATE_WAIT_MS, "the generated puzzle");
  await evaluate(cdp, "__mc.click('#generating-modal-continue')");
  await waitFor(cdp, "!__mc.open('#generating-modal-continue')", GENERATE_WAIT_MS, "the generating dialog to close");
}

/** One step: select an empty cell, read core's hint for it, and play the hinted digit (or a wrong one, undone at once). */
async function playOneCell(cdp, wrong) {
  if (!(await evaluate(cdp, "__mc.selectEmpty()"))) return false;
  await sleep(STEP_MS);
  await evaluate(cdp, "__mc.click('#edit-hint')");
  const deadline = Date.now() + HINT_WAIT_MS;
  let match = null;
  while (!match && Date.now() < deadline) {
    match = PLACEMENT_DIGIT.exec(await evaluate(cdp, "__mc.status()"));
    if (!match) await sleep(POLL_MS);
  }
  if (!match) throw new Error(`no placement hint; status: ${await evaluate(cdp, "__mc.status()")}`);
  const digit = Number(match[1]);
  if (wrong) {
    await evaluate(cdp, `__mc.pad('${(digit % 9) + 1}')`);
    await sleep(STEP_MS);
    await evaluate(cdp, "__mc.click('#edit-undo')");
    await sleep(STEP_MS);
    await evaluate(cdp, "__mc.selectEmpty()");
    await sleep(STEP_MS);
  }
  await evaluate(cdp, `__mc.pad('${digit}')`);
  await sleep(STEP_MS);
  await answerPrompt(cdp);
  return true;
}

/** Solves the current game cell by cell, then runs a stretch of undos and redos. */
async function solveGame(cdp) {
  let moves = 0;
  while (await playOneCell(cdp, moves < WRONG_MOVES_PER_GAME)) moves++;
  for (let i = 0; i < UNDO_REDO_RUN; i++) await evaluate(cdp, "__mc.click('#edit-undo')");
  for (let i = 0; i < UNDO_REDO_RUN; i++) await evaluate(cdp, "__mc.click('#edit-redo')");
  await evaluate(cdp, "__mc.click('#view-region'); __mc.click('#view-region')");
  await sleep(STEP_MS);
  return moves;
}

/** Bytes of every wasm memory in the page. */
async function wasmBytes(cdp) {
  const proto = await cdp.send("Runtime.evaluate", { expression: "WebAssembly.Memory.prototype" });
  const found = await cdp.send("Runtime.queryObjects", { prototypeObjectId: proto.result.objectId });
  const sizes = await cdp.send("Runtime.callFunctionOn", {
    objectId: found.objects.objectId,
    functionDeclaration: "function () { return this.map((m) => m.buffer.byteLength); }",
    returnByValue: true,
  });
  return sizes.result.value.reduce((a, b) => a + b, 0);
}

/** One `dumpsys meminfo` App Summary value in KB, by its label. */
function meminfoKb(meminfo, label) {
  const m = new RegExp(`${label}:\\s+(\\d+)`).exec(meminfo);
  return m ? Number(m[1]) : NaN;
}

/** Total PSS of the WebView renderer processes (where the page and its wasm run), in KB. */
function rendererPssKb() {
  const pids = adb("shell", "ps", "-A", "-o", "PID,NAME")
    .split("\n")
    .filter((line) => line.includes(RENDERER_PROCESS))
    .map((line) => line.trim().split(/\s+/)[0]);
  return pids.reduce((sum, pid) => sum + meminfoKb(adb("shell", "dumpsys", "meminfo", pid), "TOTAL(?: PSS)?"), 0);
}

/** Loopback sockets in CLOSE_WAIT on the device. */
function loopbackCloseWait() {
  return adb("shell", "cat", "/proc/net/tcp", "/proc/net/tcp6")
    .split("\n")
    .map((line) => line.trim().split(/\s+/))
    .filter((f) => f[3] === TCP_CLOSE_WAIT && (f[1]?.includes(LOOPBACK_HEX) || f[2]?.includes(LOOPBACK_HEX))).length;
}

/** One row of measurements. */
async function measure(cdp, pid, games, moves, smapsDir) {
  if (smapsDir) writeFileSync(`${smapsDir}/smaps-${games}.txt`, adb("shell", "run-as", APP, "cat", `/proc/${pid}/smaps`));
  const meminfo = adb("shell", "dumpsys", "meminfo", APP);
  return {
    games,
    moves,
    "total PSS KB": meminfoKb(meminfo, "TOTAL(?: PSS)?"),
    "Java heap KB": meminfoKb(meminfo, "Java Heap"),
    "native heap KB": meminfoKb(meminfo, "Native Heap"),
    "graphics KB": meminfoKb(meminfo, "Graphics"),
    "other KB": meminfoKb(meminfo, "Private Other"),
    "system KB": meminfoKb(meminfo, "System"),
    "renderer PSS KB": rendererPssKb(),
    "wasm KB": Math.round((await wasmBytes(cdp)) / 1024),
    fds: Number(adb("shell", "run-as", APP, "sh", "-c", `'ls /proc/${pid}/fd | wc -l'`)),
    "CLOSE_WAIT": loopbackCloseWait(),
  };
}

async function main() {
  const args = process.argv.slice(2);
  const autoSave = !args.includes("--no-autosave");
  const games = Number(args.find((a) => !a.startsWith("--")) ?? DEFAULT_GAMES);
  const option = (name) => args.find((a) => a.startsWith(`--${name}=`))?.split("=")[1];
  const every = Number(option("every") ?? CHECK_EVERY_GAMES);
  const smapsDir = option("smaps");
  requireOneEmulator();
  const pid = await launchFreshApp();
  const cdp = await connectPage(pid);
  try {
    await evaluate(cdp, PAGE_HELPERS);
    await waitFor(cdp, "!!document.querySelector('#board [data-row]')", LAUNCH_WAIT_MS, "the board");
    if (await evaluate(cdp, "__mc.open('#generating-modal-continue')")) await finishGenerating(cdp);
    await setAutoSave(cdp, autoSave);
    const rows = [await measure(cdp, pid, 0, 0, smapsDir)];
    let moves = 0;
    for (let g = 1; g <= games; g++) {
      await startEasyGame(cdp);
      moves += await solveGame(cdp);
      if (g % every === 0 || g === games) {
        rows.push(await measure(cdp, pid, g, moves, smapsDir));
        console.table(rows);
      }
    }
  } finally {
    cdp.close();
    adb("forward", "--remove", `tcp:${DEVTOOLS_PORT}`);
  }
}

main().catch((err) => {
  console.error(`memory-check failed: ${err.message}`);
  process.exit(1);
});
