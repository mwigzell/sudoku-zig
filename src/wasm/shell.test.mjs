// shell.test.mjs — worker gen handoff: import on success, no import on cancel.

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { applyWebStartupAction } from "./startup_contract.js";
import {
  CURRENT_FILE_DESKTOP_ID,
  persistCurrentFileBytes,
  hostCurrentFileExists,
  recordStartupFileSession,
  startAutoSavePolicy,
  WRITE_CONTEXT_EVENT_NEW_GAME_SUCCESS,
  WRITE_CONTEXT_EVENT_OPEN_SUCCESS,
  applySessionOutcome,
  applySessionOutcomeStatus,
  hostViewPrefsForPersist,
  initializeWebSession,
  offerInitialNewGame,
  newGameWithGeneratingModal,
  newGameWithWorkerGen,
  importPuzzle,
  currentFileLabel,
  syncCurrentFileLabels,
  createWebSessionFromStartup,
  wireFinalSnapshotOnPageHide,
  assertWebBootConfig,
  assertHostStartupConfig,
  REQUIRED_WEB_BOOT_CONFIG_KEYS,
  REQUIRED_STARTUP_READY_KEYS,
  clientLog,
  setClientLogLevel,
  CURRENT_FILE_UNSAVED_LABEL,
} from "./shell.js";
import { hostFetch, postedCurrentFile, settleFlow, withCoreFlow } from "./test_support.mjs";
import { wireGeneratingModal } from "./generating.js";

const AUTOSAVE_RESTORE_PARITY_FIXTURE = JSON.parse(
  readFileSync(new URL("../test/fixtures/autosave_restore_parity.json", import.meta.url), "utf8"),
);
const HISTORY_BRANCH_PARITY_FIXTURE = JSON.parse(
  readFileSync(new URL("../test/fixtures/history_branch_parity.json", import.meta.url), "utf8"),
);
const PASTE_FLOW_PARITY_FIXTURE = JSON.parse(
  readFileSync(new URL("../test/fixtures/paste_flow_parity.json", import.meta.url), "utf8"),
);

function makeContinueBtn() {
  return {
    disabled: false,
    handlers: {},
    addEventListener(type, fn) {
      this.handlers[type] = fn;
    },
    click() {
      this.handlers.click?.();
    },
  };
}

function makeWorkerGenMock({ line, cooperativeCancel = true }) {
  const instances = [];
  class MockWorker {
    constructor(_url, _opts) {
      this.handlers = {};
      instances.push(this);
    }
    postMessage(data) {
      this.lastPost = data;
      if (data?.type === "run") {
        queueMicrotask(() => {
          this.handlers.message?.({ data: { type: "done", line } });
        });
        return;
      }
      if (data?.type === "cancel" && cooperativeCancel) {
        queueMicrotask(() => {
          this.handlers.message?.({ data: { type: "cancelled" } });
        });
      }
    }
    terminate() {
      this.terminated = true;
    }
    set onmessage(fn) {
      this.handlers.message = fn;
    }
    set onerror(fn) {
      this.handlers.error = fn;
    }
  }
  MockWorker.instances = instances;
  return MockWorker;
}

function makeRowEl() {
  return {
    className: "",
    textContent: "",
    hidden: false,
    classList: {
      _set: new Set(),
      add(...n) {
        n.forEach((x) => this._set.add(x));
      },
    },
  };
}

function makeProgressRowsEl() {
  return {
    style: { display: "none" },
    _children: [],
    appendChild(c) {
      this._children.push(c);
    },
    replaceChildren(...n) {
      this._children = n.length ? n : [];
    },
    querySelectorAll(sel) {
      if (sel === ".gen-progress-row") {
        return this._children.filter((c) => c.classList._set.has("gen-progress-row"));
      }
      return this._children;
    },
    querySelector(sel) {
      if (sel === ".gen-progress-attempt-hint") {
        return this._children.find((c) => c.classList._set.has("gen-progress-attempt-hint"));
      }
      return undefined;
    },
    insertBefore(node, ref) {
      const idx = ref ? this._children.indexOf(ref) : this._children.length;
      this._children.splice(idx >= 0 ? idx : this._children.length, 0, node);
    },
  };
}

function makeModal({ progressRowsEl } = {}) {
  const el = { hidden: true };
  const continueBtn = makeContinueBtn();
  const cancelBtn = makeContinueBtn();
  return wireGeneratingModal({
    el,
    continueBtn,
    cancelBtn,
    spinnerEl: { hidden: true },
    msgEl: { textContent: "" },
    progressRowsEl,
    createElement: progressRowsEl ? () => makeRowEl() : undefined,
  });
}

async function flushDialogPaint() {
  if (typeof requestAnimationFrame === "function") {
    await new Promise((resolve) => {
      requestAnimationFrame(() => requestAnimationFrame(resolve));
    });
    return;
  }
  await new Promise((resolve) => setImmediate(resolve));
}

{
  const line = "1".repeat(81);
  const MockWorker = makeWorkerGenMock({ line });
  const importCalls = [];
  const game = {
    importPuzzle(text) {
      importCalls.push(text);
      return {
        ok: true,
        msg: "import: puzzle loaded",
      };
    },
    getState() {
      return { cells: [] };
    },
    getLegend() {
      return {};
    },
    getConfig() {
      return { difficulty: 1, log_level: 1, theme: "dark", show_region: false };
    },
    importPuzzleNewGame(text, difficulty) {
      importCalls.push(text);
      return { ok: true, msg: "new game started" };
    },
  };
  const modal = makeModal();
  const running = newGameWithWorkerGen(game, modal, {
    genWorker: {
      workerUrl: "/gen_worker.js",
      wasmBytes: new Uint8Array([0]),
      WorkerCtor: MockWorker,
    },
  });
  await new Promise((r) => setTimeout(r, 0));
  modal.continueBtn.click();
  const out = await running;
  assert.equal(out.ok, true);
  assert.equal(out.msg, "new game started");
  assert.equal(importCalls.length, 1);
  assert.equal(importCalls[0], line);
}

{
  const instances = [];
  class HangWorker {
    constructor(_url, _opts) {
      this.handlers = {};
      instances.push(this);
    }
    postMessage(data) {
      if (data?.type === "cancel") {
        queueMicrotask(() => {
          this.handlers.message?.({ data: { type: "cancelled" } });
        });
      }
    }
    terminate() {
      this.terminated = true;
    }
    set onmessage(fn) {
      this.handlers.message = fn;
    }
    set onerror(fn) {
      this.handlers.error = fn;
    }
  }
  const importCalls = [];
  const game = {
    importPuzzle(text) {
      importCalls.push(text);
      return { ok: true };
    },
    getState() {
      return { cells: [{ value: 0, given: false, conflict: false }] };
    },
    getLegend() {
      return {};
    },
    getConfig() {
      return { difficulty: 1, log_level: 1 };
    },
  };
  const modal = makeModal();
  const running = newGameWithWorkerGen(game, modal, {
    genWorker: {
      workerUrl: "/gen_worker.js",
      wasmBytes: new Uint8Array([0]),
      WorkerCtor: HangWorker,
    },
  });
  await new Promise((r) => setTimeout(r, 0));
  modal.cancelBtn.click();
  const out = await running;
  assert.equal(out.cancelled, true);
  assert.equal(importCalls.length, 0, "cancel must not import puzzle on main");
  assert.equal(modal.el.hidden, true);
}

{
  let progressCb = null;
  const line = "3".repeat(81);
  const game = {
    setGenProgressListener(cb) {
      progressCb = cb;
    },
    requestGenAbort() {},
    generatePuzzle() {
      progressCb?.(0, 0, 0);
      progressCb?.(2, 7, 256);
      return { ok: true, line };
    },
    importPuzzleNewGame(text, difficulty) {
      assert.equal(text, line);
      assert.equal(difficulty, 2);
      return { ok: true, msg: "new game started" };
    },
    getState() {
      return { cells: [] };
    },
    getLegend() {
      return {};
    },
    getConfig() {
      return { difficulty: 2, log_level: 1 };
    },
  };
  const progressRowsEl = makeProgressRowsEl();
  const modal = makeModal({ progressRowsEl });
  const running = newGameWithGeneratingModal(game, modal, { difficulty: 2 });
  await flushDialogPaint();
  assert.equal(progressRowsEl._children[0].textContent, "Generating: new attempt…");
  assert.equal(progressRowsEl._children[0].hidden, false);
  const hint = progressRowsEl._children.find((c) => c.classList?._set?.has("gen-progress-attempt-hint"));
  assert.equal(hint?.textContent, "Fast strip");
  const rowII = progressRowsEl._children.filter((c) => c.classList?._set?.has("gen-progress-row"))[1];
  assert.equal(rowII.textContent, "Generating: try 7/256");
  assert.equal(rowII.hidden, false);
  modal.continueBtn.click();
  const out = await running;
  assert.equal(out.ok, true);
  assert.equal(out.msg, "new game started");
}

{
  const calls = [];
  const game = {
    serialize() {
      return { ok: true, bytes: new Uint8Array([1, 2]) };
    },
  };
  const out = await persistCurrentFileBytes(
    game.serialize().bytes,
    async (url, init) => {
      calls.push({ url, init });
      return { ok: true, status: 204 };
    },
    "named-save.sud",
  );
  assert.equal(out.ok, true);
  assert.equal(calls[0].url, "./current-file");
  assert.equal(calls[0].init.headers["X-Sudoku-Filename"], "named-save.sud");
}

{
  const calls = [];
  const out = await persistCurrentFileBytes(
    new Uint8Array([3]),
    async (url, init) => {
      calls.push({ url, init });
      return { ok: true, status: 204 };
    },
    "picked.sud",
    { restoreCopy: true },
  );
  assert.equal(out.ok, true);
  assert.equal(calls[0].init.headers["X-Sudoku-Restore-Copy"], "true", "restore copy stays out of the visible folder");
}

{
  const host = hostFetch({ exists: true });
  assert.equal(await hostCurrentFileExists("sudoku.sud", host.fetchFn), true);
  assert.equal(host.calls[0].url, "./current-file-exists");
  assert.equal(host.calls[0].init.headers["X-Sudoku-Filename"], "sudoku.sud");
  await assert.rejects(
    hostCurrentFileExists("sudoku.sud", async () => ({ ok: false, status: 500 })),
    /current-file check failed: 500/,
  );
}

{
  const ready = {
    kind: "empty",
    state: { cells: [] },
    legend: { new: true },
    config: { auto_save: true },
    default_save_filename: "sudoku.sud",
  };
  const session = createWebSessionFromStartup(ready);
  assert.equal(session.default_save_filename, "sudoku.sud");
  assert.equal(session.boundFilename, null);
  assert.equal(session.boundTargetExists, null);
}

{
  const ready = {
    kind: "restore",
    state: { cells: [] },
    legend: {},
    config: {},
    default_save_filename: "sudoku.sud",
  };
  const session = createWebSessionFromStartup(ready);
  assert.equal(session.boundFilename, "sudoku.sud");
}

{
  for (const key of REQUIRED_STARTUP_READY_KEYS) {
    const ready = {
      kind: "empty",
      state: { cells: [] },
      legend: {},
      config: {},
      default_save_filename: "sudoku.sud",
    };
    delete ready[key];
    assert.throws(
      () => createWebSessionFromStartup(ready),
      new RegExp(`missing ${key}`),
    );
  }
}

function makePageHideWin() {
  const listeners = new Map();
  return {
    listeners,
    addEventListener(name, fn) {
      listeners.set(name, fn);
    },
    removeEventListener(name, fn) {
      if (listeners.get(name) === fn) listeners.delete(name);
    },
  };
}

// Startup forwards the host's event to core; a restored game continues the default file.
{
  const recorded = [];
  const game = {
    fileSessionEvent(event, name) {
      recorded.push([event, name]);
      return { ok: true };
    },
  };
  const restoreEvent = Symbol("restore event");
  const idleEvent = Symbol("idle event");
  recordStartupFileSession(game, { kind: "restore", startup_context_event: restoreEvent, default_save_filename: "autosave.sud" });
  recordStartupFileSession(game, { kind: "empty", startup_context_event: idleEvent, default_save_filename: "sudoku.sud" });
  assert.deepEqual(recorded, [[restoreEvent, "autosave.sud"], [idleEvent, null]]);
}

// Pagehide while continuing a file: one keepalive host write.
{
  const win = makePageHideWin();
  const host = hostFetch();
  const game = await withCoreFlow({ serialize: () => ({ ok: true, bytes: new Uint8Array([5, 6, 7]) }) }, { autoSave: true });
  assert.equal(game.fileSessionEvent(WRITE_CONTEXT_EVENT_OPEN_SUCCESS, "autosave.sud").ok, true);
  const session = { config: { auto_save: true }, boundFilename: "autosave.sud" };
  wireFinalSnapshotOnPageHide(game, session, { win, fetchFn: host.fetchFn });
  win.listeners.get("pagehide")?.();
  await settleFlow();
  assert.equal(host.calls.length, 1);
  assert.equal(host.calls[0].url, "./current-file");
  assert.equal(host.calls[0].init.keepalive, true);
  assert.equal(host.calls[0].init.headers["X-Sudoku-Filename"], "autosave.sud");
}

// Pagehide on a detached game writes nothing: nobody is left to answer a replace question.
{
  const win = makePageHideWin();
  const host = hostFetch();
  const game = await withCoreFlow({ serialize: () => ({ ok: true, bytes: new Uint8Array([1]) }) }, { autoSave: true });
  assert.equal(game.fileSessionEvent(WRITE_CONTEXT_EVENT_NEW_GAME_SUCCESS).ok, true);
  wireFinalSnapshotOnPageHide(game, { config: { auto_save: true } }, { win, fetchFn: host.fetchFn });
  win.listeners.get("pagehide")?.();
  await settleFlow();
  assert.equal(host.calls.length, 0);
}

// Pagehide with auto-save off writes nothing even when continuing a file.
{
  const win = makePageHideWin();
  let called = false;
  const game = await withCoreFlow({
    serialize() {
      called = true;
      return { ok: true, bytes: new Uint8Array([1]) };
    },
  });
  game.fileSessionEvent(WRITE_CONTEXT_EVENT_OPEN_SUCCESS, "autosave.sud");
  wireFinalSnapshotOnPageHide(game, { config: { auto_save: false }, boundFilename: "autosave.sud" }, {
    win,
    fetchFn: async () => ({ ok: true, status: 204 }),
  });
  win.listeners.get("pagehide")?.();
  await settleFlow();
  assert.equal(called, false);
}

{
  assert.equal(currentFileLabel({}), CURRENT_FILE_UNSAVED_LABEL);
  assert.equal(currentFileLabel({ default_save_filename: "sudoku.sud" }), CURRENT_FILE_UNSAVED_LABEL);
  assert.equal(currentFileLabel({ boundFilename: "game.sud" }), "game.sud");
}

{
  const session = {
    state: { cells: [] },
    legend: { save: false },
    config: { theme: "dark" },
  };
  const nextState = { cells: [{ value: 2, given: false, conflict: false }] };
  const nextLegend = { save: true };
  applySessionOutcome(session, { state: nextState, legend: nextLegend });
  assert.equal(session.state, nextState);
  assert.equal(session.legend, nextLegend);
  assert.equal(session.config.theme, "dark");
}

{
  const status = { textContent: "old", className: "" };
  const labels = { [CURRENT_FILE_DESKTOP_ID]: { textContent: "" } };
  const root = {
    getElementById(id) {
      return labels[id] ?? null;
    },
  };
  const session = {
    default_save_filename: "save.sud",
    state: { cells: [] },
    legend: {},
    config: {},
  };
  const nextState = { cells: [{ value: 7, given: false, conflict: false }] };
  applySessionOutcomeStatus(session, status, { state: nextState, msg: "updated" });
  syncCurrentFileLabels(session, root);
  assert.equal(session.state, nextState);
  assert.equal(status.textContent, "updated");
  assert.equal(labels[CURRENT_FILE_DESKTOP_ID].textContent, CURRENT_FILE_UNSAVED_LABEL);
}

{
  const nodes = {
    [CURRENT_FILE_DESKTOP_ID]: { textContent: "" },
  };
  const root = {
    getElementById(id) {
      return nodes[id] ?? null;
    },
  };
  syncCurrentFileLabels({ boundFilename: "alpha.sud" }, root);
  assert.equal(nodes[CURRENT_FILE_DESKTOP_ID].textContent, "alpha.sud");
}

{
  assert.deepEqual(
    hostViewPrefsForPersist({
      theme: "light",
      show_region: true,
      warn_solvability: false,
      auto_restore: true,
      auto_new: true,
      auto_save: true,
    }),
    {
      difficulty: "easy",
      log_level: "info",
      theme: "light",
      show_region: true,
      warn_solvability: false,
      auto_restore: true,
      auto_new: true,
      auto_save: true,
    },
  );
}

// ── initializeWebSession: host config boot + host startup policy payload ──
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
    setClientLogLevel(2);
    clientLog("startup", "debug", "suppressed_debug");
    clientLog("startup", "info", "suppressed_info");
    clientLog("startup", "warn", "allowed_warn");
    clientLog("startup", "err", "allowed_err");

    const hasText = (needle) => calls.some((c) => String(c.args[0] ?? "").includes(needle));
    assert.equal(hasText("suppressed_debug"), false);
    assert.equal(hasText("suppressed_info"), false);
    assert.equal(hasText("allowed_warn"), true);
    assert.equal(hasText("allowed_err"), true);
  } finally {
    setClientLogLevel("info");
    delete globalThis.__SUDOKU_LOG;
    delete globalThis.__SUDOKU_LOG_POST;
    console.debug = originalDebug;
    console.info = originalInfo;
    console.warn = originalWarn;
    console.error = originalError;
    globalThis.fetch = originalFetch;
  }
}

{
  const hostCfg = {
    difficulty: 2,
    log_level: 1,
    theme: "dark",
    show_region: false,
    warn_solvability: false,
    auto_restore: false,
    auto_new: false,
    auto_save: false,
    default_save_filename: "sudoku_save.sud",
    startup_action: "new",
    startup_context_event: "startup_new",
    on_restore_solved: "prompt",
    startup_status: null,
  };
  const game = {
    bootstrapHostConfig(cfg) {
      assert.deepEqual(cfg, {
        difficulty: 2,
        logLevel: 1,
        theme: "dark",
        show_region: false,
        warn_solvability: false,
        auto_restore: false,
        auto_new: false,
        auto_save: false,
      });
      return { ok: true, msg: "engine ready" };
    },
    getState() {
      return { cells: [{ value: 0, given: false, conflict: false }] };
    },
    getLegend() {
      return { new: true };
    },
    getConfig() {
      return {
        difficulty: 2,
        log_level: 1,
        theme: "dark",
        show_region: false,
        warn_solvability: false,
        auto_restore: false,
        auto_new: false,
        auto_save: false,
      };
    },
    deserialize() {
      return { ok: false };
    },
  };
  const out = await initializeWebSession(game, {
    fetchFn: async () => ({ ok: true, json: async () => hostCfg }),
  });
  assert.equal(out.ok, true);
  assert.equal(out.kind, "empty");
  assert.equal(out.config.difficulty, 2);
  assert.equal(out.startup_action, "new");
  assert.equal(out.startup_context_event, "startup_new");
}

{
  const hostCfg = {
    difficulty: 1,
    log_level: 1,
    theme: "dark",
    show_region: false,
    warn_solvability: false,
    auto_restore: false,
    auto_new: false,
    auto_save: false,
    default_save_filename: "sudoku_save.sud",
    startup_action: "idle",
    startup_context_event: "startup_idle",
    on_restore_solved: "prompt",
    startup_status: "Welcome to sudoku-zig! Choose New or Open to play",
  };
  const game = {
    bootstrapHostConfig() {
      return { ok: true };
    },
    getState() {
      return { cells: [{ value: 5, given: true, conflict: false }] };
    },
    getLegend() {
      return {};
    },
    getConfig() {
      return hostCfg;
    },
  };
  const out = await initializeWebSession(game, {
    fetchFn: async () => ({ ok: true, json: async () => hostCfg }),
  });
  assert.equal(out.ok, true);
  assert.equal(out.kind, "empty");
  assert.equal(out.startup_action, "idle");
  assert.equal(out.startup_context_event, "startup_idle");
  assert.equal(out.startup_status, "Welcome to sudoku-zig! Choose New or Open to play");
}

// ── offerInitialNewGame: action=new runs generation; action=idle remains manual ──
{
  const manual = await offerInitialNewGame(
    {},
    {
      ok: true,
      kind: "empty",
      startup_action: "idle",
      startup_context_event: "startup_idle",
      state: {},
      legend: {},
      config: {},
      startup_status: "Welcome to sudoku-zig! Choose New or Open to play",
    },
    null,
  );
  assert.equal(manual.kind, "empty");
  assert.equal(manual.msg, "Welcome to sudoku-zig! Choose New or Open to play");
}

{
  const restoredState = { cells: [{ value: 7, given: false, conflict: false }] };
  let deserializeCalls = 0;
  let importCalls = 0;
  const game = {
    deserialize() {
      deserializeCalls += 1;
      return { ok: true, state: restoredState, msg: "opened: startup-save.sud" };
    },
    importPuzzle() {
      importCalls += 1;
      return { ok: true, state: { cells: [{ value: 1, given: true, conflict: false }] } };
    },
    getLegend() {
      return { save: true };
    },
    getConfig() {
      return { difficulty: 1, log_level: 1 };
    },
    getState() {
      return { cells: [] };
    },
  };
  const out = await offerInitialNewGame(
    game,
    {
      ok: true,
      kind: "empty",
      startup_action: "restore",
      startup_context_event: "startup_restore",
      on_restore_solved: "prompt",
      startup_status: null,
      startup_save_path: "./current-file",
      default_save_filename: "sudoku.sud",
      state: {},
      legend: {},
      config: {},
    },
    null,
    { fetchFn: async () => ({ ok: true, arrayBuffer: async () => new Uint8Array([1, 2, 3]).buffer }) },
  );
  assert.equal(out.ok, true);
  assert.equal(out.kind, "restore");
  assert.equal(out.state.cells[0].value, 7);
  assert.equal(out.state.cells[0].given, false);
  assert.equal(deserializeCalls, 1, "restore startup path must use deserialize");
  assert.equal(importCalls, 0, "restore startup path must not use one-line import path");
  assert.equal(out.default_save_filename, "sudoku.sud");
}

{
  // End-to-end startup-restore status pass-through: core-concatenated message
  // must survive shell startup + status rendering unchanged.
  const concatMsg = "opened: dead.sud; this puzzle has no solution (no-solution)";
  const game = {
    deserialize() {
      return {
        ok: true,
        state: { cells: [{ value: 7, given: false, conflict: false }] },
        msg: concatMsg,
      };
    },
    getLegend() {
      return { save: true };
    },
    getConfig() {
      return { difficulty: 1, log_level: 1 };
    },
    getState() {
      return { cells: [] };
    },
  };
  const ready = await offerInitialNewGame(
    game,
    {
      ok: true,
      kind: "empty",
      startup_action: "restore",
      on_restore_solved: "prompt",
      startup_status: null,
      startup_save_path: "./current-file",
      default_save_filename: "sudoku.sud",
      state: {},
      legend: {},
      config: {},
    },
    null,
    { fetchFn: async () => ({ ok: true, arrayBuffer: async () => new Uint8Array([1, 2, 3]).buffer }) },
  );
  assert.equal(ready.ok, true);
  assert.equal(ready.kind, "restore");
  assert.equal(ready.msg, concatMsg);

  const status = { textContent: "old", className: "" };
  const session = createWebSessionFromStartup(ready);
  applySessionOutcomeStatus(session, status, { msg: ready.msg });
  assert.equal(status.textContent, concatMsg);
}

{
  const solvedCells = Array.from({ length: 81 }, () => ({ value: 1, given: true, conflict: false }));
  let startNewCalls = 0;
  const game = {
    getLegend() {
      return { save: true };
    },
    getConfig() {
      return { difficulty: 2, log_level: 1 };
    },
    getState() {
      return { cells: [] };
    },
  };
  const out = await applyWebStartupAction(
    game,
    {
      ok: true,
      kind: "empty",
      startup_action: "restore",
      on_restore_solved: "prompt",
      startup_status: null,
      startup_save_path: "./current-file",
      default_save_filename: "sudoku.sud",
      state: {},
      legend: {},
      config: { difficulty: 2, log_level: 1 },
    },
    {
      fetchStartupSaveBytes: async () => ({ ok: true, bytes: new Uint8Array([1]) }),
      openFromSaveBytes: () => ({
        ok: true,
        state: { cells: solvedCells },
        msg: "You win!",
        startup_prompt_new_game: true,
      }),
      startNewGame: async () => {
        startNewCalls += 1;
        return { ok: true };
      },
    },
  );
  assert.equal(out.ok, true);
  assert.equal(out.kind, "restore");
  assert.equal(out.msg, "You win!");
  assert.equal(out.startup_prompt_new_game, true);
  assert.equal(startNewCalls, 0, "startup restore path should not start new before UI prompt");
}

{
  const solvedCells = Array.from({ length: 81 }, () => ({ value: 1, given: true, conflict: false }));
  const game = {
    getLegend() {
      return { save: true };
    },
    getConfig() {
      return { difficulty: 2, log_level: 1 };
    },
    getState() {
      return { cells: [] };
    },
  };
  const out = await applyWebStartupAction(
    game,
    {
      ok: true,
      kind: "empty",
      startup_action: "restore",
      on_restore_solved: "prompt",
      startup_status: null,
      startup_save_path: "./current-file",
      default_save_filename: "sudoku.sud",
      state: {},
      legend: {},
      config: { difficulty: 2, log_level: 1 },
    },
    {
      fetchStartupSaveBytes: async () => ({ ok: true, bytes: new Uint8Array([1]) }),
      openFromSaveBytes: () => ({
        ok: true,
        state: { cells: solvedCells },
        msg: "You win!",
        startup_prompt_new_game: true,
      }),
      startNewGame: async () => ({
        ok: true,
        state: { cells: [{ value: 0, given: false, conflict: false }] },
        legend: { new: true },
        config: { difficulty: 2, log_level: 1 },
        msg: "new game started",
      }),
    },
  );
  assert.equal(out.ok, true);
  assert.equal(out.kind, "restore");
  assert.equal(out.startup_prompt_new_game, true);
}

{
  // First autosave with nothing on disk writes the host default file and binds its name.
  const game = await withCoreFlow({ serialize: () => ({ ok: true, bytes: new Uint8Array([1, 2, 3]) }) }, { autoSave: true });
  const session = { config: { auto_save: true }, default_save_filename: "sudoku.sud", boundFilename: null };
  const host = hostFetch({ exists: false });
  const outcome = await startAutoSavePolicy(game, session, "fill", { fetchFn: host.fetchFn });
  assert.equal(outcome.kind, "done");
  assert.equal(session.boundFilename, "sudoku.sud");
  assert.equal(postedCurrentFile(host.calls)?.init?.headers?.["X-Sudoku-Restore-Copy"], undefined, "host file is the user's file");
}

{
  // Commands outside the core trigger list write nothing.
  const game = await withCoreFlow({ serialize: () => ({ ok: true, bytes: new Uint8Array([1]) }) }, { autoSave: true });
  const host = hostFetch();
  const outcome = await startAutoSavePolicy(game, { default_save_filename: "sudoku.sud" }, "new", { fetchFn: host.fetchFn });
  assert.equal(outcome.kind, "done");
  assert.equal(host.calls.length, 0);
}

/** Session continuing `bound.sud` through a bound writer that records into `writes`. */
async function boundAutosaveSetup(writes, boundResult = { ok: true }) {
  const game = await withCoreFlow({ serialize: () => ({ ok: true, bytes: new Uint8Array([4, 2]) }) }, { autoSave: true });
  assert.equal(game.fileSessionEvent(WRITE_CONTEXT_EVENT_OPEN_SUCCESS, "bound.sud").ok, true);
  const session = {
    config: { auto_save: true },
    boundFilename: "bound.sud",
    boundTargetExists: () => true,
    boundSnapshotWriter: async (bytes) => {
      writes.push({ lane: "bound", bytes: [...bytes] });
      return boundResult;
    },
  };
  const fetchFn = async (url, init) => {
    if (url === "./current-file") {
      writes.push({ lane: "host", bytes: [...new Uint8Array(init.body)], restoreCopy: init.headers["X-Sudoku-Restore-Copy"] });
      return { ok: true, status: 204 };
    }
    throw new Error(`unexpected fetch url: ${url}`);
  };
  return { game, session, fetchFn };
}

{
  // Continuing a bound file: write it first, then the host restore copy; nobody is asked.
  const writes = [];
  const { game, session, fetchFn } = await boundAutosaveSetup(writes);
  const prevChoose = globalThis.__sudokuChoose;
  globalThis.__sudokuChoose = async () => assert.fail("continuation must not ask");
  await startAutoSavePolicy(game, session, "fill", { fetchFn });
  globalThis.__sudokuChoose = prevChoose;
  assert.deepEqual(writes, [
    { lane: "bound", bytes: [4, 2] },
    { lane: "host", bytes: [4, 2], restoreCopy: "true" },
  ]);
}

{
  // A failed bound write skips the host copy and surfaces the error.
  const writes = [];
  const { game, session, fetchFn } = await boundAutosaveSetup(writes, { ok: false, error: "bound write failed" });
  let surfaced = null;
  const outcome = await startAutoSavePolicy(game, session, "fill", {
    fetchFn,
    onError: (err) => {
      surfaced = err;
    },
  });
  assert.equal(outcome.kind, "show_error");
  assert.deepEqual(writes, [{ lane: "bound", bytes: [4, 2] }], "host copy must not run when bound autosave fails");
  assert.equal(surfaced?.error, "bound write failed");
}

{
  // An opened game continues its file: the first autosave writes without a replace question.
  const game = await withCoreFlow({ serialize: () => ({ ok: true, bytes: new Uint8Array([9]) }) }, { autoSave: true });
  game.fileSessionEvent(WRITE_CONTEXT_EVENT_OPEN_SUCCESS, "autosave.sud");
  const host = hostFetch({ exists: true });
  const prevChoose = globalThis.__sudokuChoose;
  globalThis.__sudokuChoose = async () => assert.fail("continued file must not ask");
  await startAutoSavePolicy(game, { config: { auto_save: true }, boundFilename: "autosave.sud" }, "fill", { fetchFn: host.fetchFn });
  globalThis.__sudokuChoose = prevChoose;
  assert.equal(postedCurrentFile(host.calls)?.init?.headers?.["X-Sudoku-Filename"], "autosave.sud");
}

{
  // Overlapping autosaves run one at a time, so the latest snapshot lands last.
  const writes = [];
  let firstWriteResolve = null;
  let currentSnapshot = new Uint8Array([1]);
  const game = await withCoreFlow({ serialize: () => ({ ok: true, bytes: currentSnapshot }) }, { autoSave: true });
  game.fileSessionEvent(WRITE_CONTEXT_EVENT_OPEN_SUCCESS, "autosave.sud");
  const session = { config: { auto_save: true }, boundFilename: "autosave.sud" };
  const fetchFn = async (url, init) => {
    if (url === "./current-file-exists") return { ok: true, json: async () => ({ exists: true }) };
    if (url === "./current-file") {
      const bodyBytes = new Uint8Array(init.body);
      if (firstWriteResolve == null) {
        return await new Promise((resolve) => {
          firstWriteResolve = () => {
            writes.push(bodyBytes);
            resolve({ ok: true, status: 204 });
          };
        });
      }
      writes.push(bodyBytes);
      return { ok: true, status: 204 };
    }
    throw new Error(`unexpected fetch url: ${url}`);
  };

  const first = startAutoSavePolicy(game, session, "fill", { fetchFn });
  await settleFlow();
  currentSnapshot = new Uint8Array([2]);
  const second = startAutoSavePolicy(game, session, "fill", { fetchFn });
  await settleFlow();
  assert.equal(writes.length, 0, "second autosave waits for the first");
  firstWriteResolve?.();
  await Promise.all([first, second]);
  assert.deepEqual(writes.map((bytes) => [...bytes]), [[1], [2]], "latest autosave snapshot lands last");
}

{
  // Full-cycle regression guard: autosave snapshot must survive restart with
  // player-entered cells still marked as non-givens.
  const idx = (row, col) => row * 9 + col;
  const lineToCells = (line) =>
    Array.from(line, (ch) => {
      const value = Number(ch);
      return { value, given: value !== 0, conflict: false };
    });
  const fixture = AUTOSAVE_RESTORE_PARITY_FIXTURE;
  const baseCells = lineToCells(fixture.puzzle_line);

  let savedBytes = null;
  const hostCfg = () => ({
    difficulty: 1,
    log_level: 1,
    theme: "dark",
    show_region: false,
    warn_solvability: false,
    auto_restore: true,
    auto_new: false,
    auto_save: true,
    default_save_filename: "sudoku.sud",
    startup_action: savedBytes ? "restore" : "idle",
    startup_context_event: savedBytes ? "startup_restore" : "startup_idle",
    on_restore_solved: "prompt",
    startup_status: savedBytes ? null : "manual startup",
    startup_save_path: savedBytes ? "./current-file" : null,
  });
  const fetchFn = async (url, init) => {
    if (url === "./host-config.json") return { ok: true, json: async () => hostCfg() };
    if (url === "./current-file" && !init) {
      if (!savedBytes) return { ok: false, status: 404 };
      return { ok: true, arrayBuffer: async () => savedBytes.buffer.slice(0) };
    }
    if (url === "./current-file" && init?.method === "POST") {
      savedBytes = new Uint8Array(init.body);
      return { ok: true, status: 204 };
    }
    if (url === "./current-file-exists") return { ok: true, json: async () => ({ exists: savedBytes != null }) };
    throw new Error(`unexpected fetch url: ${url}`);
  };

  const makeGame = () => {
    let state = { cells: baseCells.map((c) => ({ ...c })) };
    let config = {};
    return {
      bootstrapHostConfig(next) {
        config = { ...next };
        return { ok: true, msg: "engine ready" };
      },
      getState() {
        return { cells: state.cells.map((c) => ({ ...c })) };
      },
      getLegend() {
        return { fill: true, clear: true, undo: true, redo: true, save: true };
      },
      getConfig() {
        return {
          difficulty: config.difficulty ?? 1,
          log_level: config.logLevel ?? 1,
          theme: config.theme ?? "dark",
          show_region: config.show_region ?? false,
          warn_solvability: config.warn_solvability ?? false,
          auto_restore: config.auto_restore ?? true,
          auto_new: config.auto_new ?? false,
          auto_save: config.auto_save ?? true,
        };
      },
      exec(action) {
        if (action?.action === "fill") {
          const i = idx(action.row, action.col);
          state.cells[i] = { value: action.digit, given: false, conflict: false };
          return { ok: true, state: this.getState(), msg: null, is_quit: false };
        }
        return { ok: false, error: "unsupported action" };
      },
      serialize() {
        return { ok: true, bytes: new TextEncoder().encode(JSON.stringify(state)) };
      },
      deserialize(bytes) {
        state = JSON.parse(new TextDecoder().decode(bytes));
        return { ok: true, state: this.getState(), msg: "opened: ./current-file" };
      },
      importPuzzle() {
        return { ok: false, error: "must not import in restore path" };
      },
    };
  };

  const launchA = await withCoreFlow(makeGame(), { autoSave: true });
  const bootA = await initializeWebSession(launchA, { fetchFn });
  const readyA = await offerInitialNewGame(launchA, bootA, null, { fetchFn });
  assert.equal(readyA.ok, true);
  assert.equal(readyA.kind, "empty");
  const sessionA = {
    config: readyA.config,
    default_save_filename: readyA.default_save_filename,
    boundFilename: null,
  };
  recordStartupFileSession(launchA, readyA);

  for (const move of fixture.moves) {
    launchA.exec({ action: "fill", row: move.row, col: move.col, digit: move.digit });
    await startAutoSavePolicy(launchA, sessionA, "fill", { fetchFn });
  }
  assert.ok(savedBytes && savedBytes.length > 0, "autosave should persist a startup snapshot");

  const launchB = makeGame();
  const bootB = await initializeWebSession(launchB, { fetchFn });
  const readyB = await offerInitialNewGame(launchB, bootB, null, { fetchFn });
  assert.equal(readyB.ok, true);
  assert.equal(readyB.kind, "restore");

  const restored = readyB.state.cells;
  assert.equal(restored[idx(fixture.given_probe.row, fixture.given_probe.col)].value, fixture.given_probe.value);
  assert.equal(restored[idx(fixture.given_probe.row, fixture.given_probe.col)].given, true);
  for (const probe of fixture.move_probes) {
    assert.equal(restored[idx(probe.row, probe.col)].value, probe.value);
    assert.equal(restored[idx(probe.row, probe.col)].given, false);
  }
}

{
  // Cross-entry parity fixture: redo must not resurrect discarded history after
  // a divergent fill branch.
  const idx = (row, col) => row * 9 + col;
  const lineToCells = (line) =>
    Array.from(line, (ch) => {
      const value = Number(ch);
      return { value, given: value !== 0, conflict: false };
    });
  const fixture = HISTORY_BRANCH_PARITY_FIXTURE;
  const state = { cells: lineToCells(fixture.puzzle_line) };
  const history = [];
  let pointer = 0;

  const recordMutation = (row, col, oldValue, newValue) => {
    if (pointer < history.length) history.splice(pointer);
    history.push({ row, col, oldValue, newValue });
    pointer = history.length;
  };

  const exec = (step) => {
    if (step.action === "fill") {
      const i = idx(step.row, step.col);
      const oldValue = state.cells[i].value;
      state.cells[i] = { ...state.cells[i], value: step.digit, given: false };
      recordMutation(step.row, step.col, oldValue, step.digit);
      return;
    }
    if (step.action === "undo") {
      if (pointer === 0) return;
      const mutation = history[pointer - 1];
      pointer -= 1;
      const i = idx(mutation.row, mutation.col);
      state.cells[i] = { ...state.cells[i], value: mutation.oldValue, given: false };
      return;
    }
    if (step.action === "redo") {
      if (pointer >= history.length) return;
      const mutation = history[pointer];
      pointer += 1;
      const i = idx(mutation.row, mutation.col);
      state.cells[i] = { ...state.cells[i], value: mutation.newValue, given: false };
      return;
    }
    throw new Error(`unsupported action: ${step.action}`);
  };

  for (const step of fixture.steps) exec(step);

  assert.equal(state.cells[idx(fixture.given_probe.row, fixture.given_probe.col)].value, fixture.given_probe.value);
  assert.equal(state.cells[idx(fixture.given_probe.row, fixture.given_probe.col)].given, true);
  for (const probe of fixture.probes) {
    assert.equal(state.cells[idx(probe.row, probe.col)].value, probe.value);
    assert.equal(state.cells[idx(probe.row, probe.col)].given, probe.given);
  }
  assert.equal(pointer, fixture.history_pointer);
  assert.equal(history.length, fixture.history_length);
}

{
  // Cross-entry parity fixture: paste/import success resets history; invalid
  // paste/import preserves state + history.
  const idx = (row, col) => row * 9 + col;
  const lineToCells = (line) =>
    Array.from(line, (ch) => {
      const value = Number(ch);
      return { value, given: value !== 0, conflict: false };
    });
  const fixture = PASTE_FLOW_PARITY_FIXTURE;
  let state = { cells: lineToCells(fixture.seed_line) };
  let historyCount = 0;

  const game = {
    exec(action) {
      if (action?.action !== "fill") return { ok: false, error: "unsupported action" };
      const i = idx(action.row, action.col);
      state.cells[i] = { ...state.cells[i], value: action.digit, given: false };
      historyCount += 1;
      return { ok: true, state: this.getState(), msg: null };
    },
    importPuzzle(line) {
      if (line.length !== 81) return { ok: false, error: "import: puzzle line must be exactly 81 chars" };
      if (/[^0-9]/.test(line)) return { ok: false, error: "import: invalid character in puzzle line" };
      state = { cells: lineToCells(line) };
      historyCount = 0;
      return { ok: true, msg: "import: puzzle loaded" };
    },
    getState() {
      return { cells: state.cells.map((cell) => ({ ...cell })) };
    },
    getLegend() {
      return { paste: true };
    },
    getConfig() {
      return { auto_save: false };
    },
    historyCount() {
      return historyCount;
    },
  };

  const prefill = game.exec({ action: "fill", row: fixture.prefill.row, col: fixture.prefill.col, digit: fixture.prefill.digit });
  assert.equal(prefill.ok, true);
  assert.equal(state.cells[idx(fixture.prefill_probe.row, fixture.prefill_probe.col)].value, fixture.prefill_probe.value);
  assert.equal(state.cells[idx(fixture.prefill_probe.row, fixture.prefill_probe.col)].given, fixture.prefill_probe.given);
  assert.equal(game.historyCount(), fixture.history_after_prefill);

  const imported = importPuzzle(game, fixture.valid_import_line);
  assert.equal(imported.ok, true);
  for (const probe of fixture.success_probes) {
    assert.equal(state.cells[idx(probe.row, probe.col)].value, probe.value);
    assert.equal(state.cells[idx(probe.row, probe.col)].given, probe.given);
  }
  assert.equal(game.historyCount(), fixture.history_after_success_import);

  const refill = game.exec({ action: "fill", row: fixture.refill.row, col: fixture.refill.col, digit: fixture.refill.digit });
  assert.equal(refill.ok, true);
  assert.equal(game.historyCount(), fixture.history_after_refill);
  const beforeInvalid = JSON.stringify(game.getState());

  const invalidImport = importPuzzle(game, fixture.invalid_import_line);
  assert.equal(invalidImport.ok, false);
  assert.match(invalidImport.error ?? "", /invalid character/i);
  assert.equal(JSON.stringify(game.getState()), beforeInvalid);
  assert.equal(game.historyCount(), fixture.history_after_invalid_import);
  assert.equal(
    state.cells[idx(fixture.invalid_preserve_probe.row, fixture.invalid_preserve_probe.col)].value,
    fixture.invalid_preserve_probe.value,
  );
  assert.equal(
    state.cells[idx(fixture.invalid_preserve_probe.row, fixture.invalid_preserve_probe.col)].given,
    fixture.invalid_preserve_probe.given,
  );
}

{
  const game = {
    getLegend() {
      return {};
    },
    getConfig() {
      return {};
    },
    getState() {
      return { cells: [] };
    },
  };
  const out = await offerInitialNewGame(
    game,
    {
      ok: true,
      kind: "empty",
      startup_action: "restore",
      startup_context_event: "startup_restore",
      startup_status: null,
      startup_save_path: "./current-file",
      default_save_filename: "sudoku.sud",
      state: {},
      legend: {},
      config: {},
    },
    null,
    { fetchFn: async () => ({ ok: false, status: 404 }) },
  );
  assert.equal(out.ok, true);
  assert.equal(out.kind, "empty");
  assert.match(out.msg ?? "", /startup restore fetch failed/);
  assert.equal(out.default_save_filename, "sudoku.sud");
}

{
  const missing = await offerInitialNewGame(
    {},
    { ok: true, kind: "empty", startup_action: "new", startup_context_event: "startup_new", state: {}, legend: {}, config: {} },
    null,
  );
  assert.equal(missing.ok, false);
  assert.match(missing.error, /engine config/);
}

{
  let initDifficulty;
  const game = {
    getConfig() {
      return { difficulty: 2, log_level: 1 };
    },
    init({ difficulty }) {
      initDifficulty = difficulty;
      return { ok: true, msg: "new game started" };
    },
    getState() {
      return { cells: [] };
    },
    getLegend() {
      return {};
    },
  };
  const modal = makeModal();
  const running = offerInitialNewGame(
    game,
    {
      ok: true,
      kind: "empty",
      startup_action: "new",
      startup_context_event: "startup_new",
      startup_status: null,
      default_save_filename: "sudoku.sud",
      config: { difficulty: 2, log_level: 1 },
      state: {},
      legend: {},
    },
    modal,
  );
  await flushDialogPaint();
  let resolved = false;
  void running.then(() => {
    resolved = true;
  });
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(modal.el.hidden, false, "startup auto-new keeps generating modal open until Continue");
  assert.equal(resolved, false, "startup auto-new must not auto-continue");
  modal.continueBtn.click();
  const out = await running;
  assert.equal(out.ok, true);
  assert.equal(out.kind, "new");
  assert.equal(initDifficulty, 2);
  assert.equal(out.default_save_filename, "sudoku.sud");
}

{
  for (const key of REQUIRED_WEB_BOOT_CONFIG_KEYS) {
    const cfg = {
      difficulty: 1,
      log_level: 1,
      theme: "dark",
      show_region: false,
      warn_solvability: false,
      auto_restore: false,
      auto_new: false,
      auto_save: false,
      default_save_filename: "sudoku_save.sud",
    };
    delete cfg[key];
    assert.throws(() => assertWebBootConfig(cfg), new RegExp(`missing ${key}`));
  }
}

{
  const hostCfg = {
    difficulty: 1,
    log_level: 1,
    theme: "dark",
    show_region: false,
    warn_solvability: false,
    auto_restore: false,
    auto_new: false,
    auto_save: false,
    default_save_filename: "sudoku_save.sud",
    startup_context_event: "startup_idle",
    on_restore_solved: "prompt",
    startup_status: null,
  };
  delete hostCfg.startup_status;
  assert.throws(
    () => assertHostStartupConfig(hostCfg),
    /missing startup_status/,
  );
}

{
  const hostCfg = {
    difficulty: 1,
    log_level: 1,
    theme: "dark",
    show_region: false,
    warn_solvability: false,
    auto_restore: false,
    auto_new: false,
    auto_save: false,
    default_save_filename: "sudoku_save.sud",
    startup_context_event: "startup_idle",
    on_restore_solved: "prompt",
    startup_status: null,
  };
  delete hostCfg.default_save_filename;
  assert.throws(
    () => assertHostStartupConfig(hostCfg),
    /missing default_save_filename/,
  );
}

