// shell.test.mjs — worker gen handoff: import on success, no import on cancel.

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import {
  CURRENT_FILE_DESKTOP_ID,
  persistCurrentFileBytes,
  hostCurrentFileExists,
  startAutoSavePolicy,
  WRITE_CONTEXT_EVENT_NEW_GAME_SUCCESS,
  WRITE_CONTEXT_EVENT_OPEN_SUCCESS,
  applySessionOutcome,
  applySessionOutcomeStatus,
  hostViewPrefsForPersist,
  initializeWebSession,
  runStartupFlow,
  startupHandlers,
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
import { hostFetch, loadGame, postedCurrentFile, settleFlow, withCoreFlow } from "./test_support.mjs";
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
  for (const key of REQUIRED_STARTUP_READY_KEYS) {
    const ready = {
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
    startup_save_path: "/current-file",
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
  assert.equal(out.config.difficulty, 2);
  assert.equal(out.startup_save_path, "/current-file");
  assert.equal(out.default_save_filename, "sudoku_save.sud");
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
    startup_save_path: null,
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
  assert.equal(out.startup_save_path, null);
}

// ── startup flow: core decides restore / new / idle; the web only fetches, draws and asks ──
const SOLVED_LINE = "483921657967345821251876493548132976729564138136798245372689514814253769695417382";
const OPEN_LINE = "530070000600195000098000060800060003400803001700020006060000280000419005000080079";
const WELCOME_STATUS = "Welcome to sudoku-zig! Choose New or Open to play";
const HOST_CURRENT_FILE = "/current-file";

/** Bytes of a saved game holding `line`. */
async function savedGameBytes(line) {
  const source = await loadGame();
  assert.equal(source.importPuzzle(line).ok, true);
  return source.serialize().bytes;
}

/**
 * Run the startup flow on a real game with recording handlers.
 * `answers` feeds each `ask`; `generated` answers each `generate`.
 */
async function runStartupScenario({ config = {}, currentFile = null, answers = [], generated = [] } = {}) {
  const game = await loadGame(config);
  const calls = [];
  const fetchFn = async (url, init = {}) => {
    calls.push({ url, init });
    if (url === HOST_CURRENT_FILE && init.method === "DELETE") return { ok: true, status: 204 };
    if (url === HOST_CURRENT_FILE) {
      if (!currentFile?.bytes) return { ok: false, status: 404 };
      return { ok: true, arrayBuffer: async () => currentFile.bytes.slice().buffer };
    }
    throw new Error(`unexpected fetch url: ${url}`);
  };
  const shown = [];
  const asked = [];
  const errors = [];
  const generateCalls = [];
  const boot = {
    state: game.getState(),
    legend: game.getLegend(),
    config: game.getConfig(),
    default_save_filename: currentFile?.name ?? "sudoku.sud",
    startup_save_path: currentFile ? HOST_CURRENT_FILE : null,
  };
  const session = createWebSessionFromStartup(boot);
  const win = {
    __sudokuChoose: async (text, opts) => {
      asked.push({ text, ...opts });
      return answers.shift() === true;
    },
  };
  const handlers = {
    ...startupHandlers(game, session, {
      fetchFn,
      win,
      showGame: (step) => shown.push({ text: step.text, file: step.file }),
      showError: (text) => errors.push(text),
    }),
    generate: async (difficulty) => {
      generateCalls.push(difficulty);
      return generated.shift() ?? { ok: false, error: "no generation scripted" };
    },
  };
  const outcome = await runStartupFlow(game, boot, handlers);
  return { game, session, outcome, calls, shown, asked, errors, generateCalls, fetchFn };
}

{
  // No current file and no auto new: the idle board with the welcome line.
  const run = await runStartupScenario({ config: { auto_restore: true } });
  assert.equal(run.outcome.kind, "done");
  assert.deepEqual(run.shown, [{ text: WELCOME_STATUS, file: null }]);
  assert.equal(run.calls.length, 0);
  assert.equal(run.session.boundFilename, null);
}

{
  // Restore: the saved game comes back, labelled with its file, and autosave continues it without asking.
  const bytes = await savedGameBytes(OPEN_LINE);
  const run = await runStartupScenario({
    config: { auto_restore: true, auto_new: true, auto_save: true },
    currentFile: { name: "game.sud", bytes },
  });
  assert.equal(run.outcome.kind, "done");
  assert.equal(run.shown.length, 1);
  assert.equal(run.shown[0].file, "game.sud");
  assert.equal(run.session.boundFilename, "game.sud");
  assert.equal(run.session.state.cells[0].value, 5);
  assert.equal(run.asked.length, 0);
  assert.equal(run.generateCalls.length, 0);

  run.game.exec({ action: "fill", row: 0, col: 2, digit: 4 });
  const host = hostFetch({ exists: true });
  const prevChoose = globalThis.__sudokuChoose;
  globalThis.__sudokuChoose = async () => assert.fail("a restored game continues its file");
  await startAutoSavePolicy(run.game, run.session, "fill", { fetchFn: host.fetchFn });
  globalThis.__sudokuChoose = prevChoose;
  assert.equal(postedCurrentFile(host.calls)?.init?.headers?.["X-Sudoku-Filename"], "game.sud");
}

for (const deleteIt of [true, false]) {
  // Restore failure: idle board, one question, then the host forgets (and maybe deletes) the file.
  const run = await runStartupScenario({
    config: { auto_restore: true, auto_new: true },
    currentFile: { name: "game.sud", bytes: null },
    answers: [deleteIt],
  });
  assert.equal(run.outcome.kind, "done");
  assert.deepEqual(run.shown, [{ text: WELCOME_STATUS, file: null }]);
  assert.equal(run.asked.length, 1);
  assert.equal(run.asked[0].title, "Restore failed");
  assert.equal(run.asked[0].text, "game.sud could not be restored (fetch failed: 404). Do you want to delete it?");
  assert.equal(run.asked[0].okLabel, "Delete");
  assert.equal(run.asked[0].cancelLabel, "Keep");
  const forget = run.calls.find((c) => c.init.method === "DELETE");
  assert.ok(forget, "the host must forget the current file");
  assert.equal(forget.init.headers["X-Sudoku-Delete-File"], deleteIt ? "true" : undefined);
  assert.equal(run.generateCalls.length, 0, "a failed restore never falls back to a new game");
}

{
  // Unreadable bytes are a restore failure too.
  const run = await runStartupScenario({
    config: { auto_restore: true },
    currentFile: { name: "game.sud", bytes: new Uint8Array([1, 2, 3]) },
    answers: [false],
  });
  assert.equal(run.asked[0].title, "Restore failed");
}

{
  // Restored game already solved: core asks; New game generates at the saved difficulty.
  const bytes = await savedGameBytes(SOLVED_LINE);
  const run = await runStartupScenario({
    config: { auto_restore: true, difficulty: 3 },
    currentFile: { name: "game.sud", bytes },
    answers: [true],
    generated: [{ ok: true, line: OPEN_LINE }],
  });
  assert.equal(run.outcome.kind, "done");
  assert.equal(run.asked[0].title, "Puzzle solved");
  assert.equal(run.asked[0].okLabel, "New game");
  assert.deepEqual(run.generateCalls, [3]);
  assert.equal(run.shown.length, 2);
  assert.equal(run.session.state.cells[0].value, 5);
}

{
  // Restored game already solved, Keep: the solved board stays.
  const bytes = await savedGameBytes(SOLVED_LINE);
  const run = await runStartupScenario({
    config: { auto_restore: true },
    currentFile: { name: "game.sud", bytes },
    answers: [false],
  });
  assert.equal(run.outcome.kind, "done");
  assert.equal(run.generateCalls.length, 0);
  assert.equal(run.session.state.cells[0].value, 4);
}

{
  // Auto new: core imports the generated line itself.
  const run = await runStartupScenario({ config: { auto_new: true, difficulty: 2 }, generated: [{ ok: true, line: OPEN_LINE }] });
  assert.equal(run.outcome.kind, "done");
  assert.deepEqual(run.generateCalls, [2]);
  assert.equal(run.shown.length, 1);
  assert.notEqual(run.shown[0].text, WELCOME_STATUS);
  assert.equal(run.session.state.cells[0].value, 5);
}

{
  // Auto new cancelled: straight to the idle board.
  const run = await runStartupScenario({ config: { auto_new: true }, generated: [{ ok: false, cancelled: true }] });
  assert.equal(run.outcome.kind, "done");
  assert.deepEqual(run.shown, [{ text: WELCOME_STATUS, file: null }]);
  assert.equal(run.errors.length, 0);
}

{
  // Auto new failed: the idle board, then the error; boot itself does not fail.
  const run = await runStartupScenario({ config: { auto_new: true }, generated: [{ ok: false, error: "worker crashed" }] });
  assert.equal(run.outcome.kind, "show_error");
  assert.deepEqual(run.shown, [{ text: WELCOME_STATUS, file: null }]);
  assert.deepEqual(run.errors, ["A new game could not be generated (worker crashed)."]);
}

{
  // The web generate step hands core the line and does not import it; Continue still closes the modal.
  let imported = 0;
  const game = {
    getConfig: () => ({ difficulty: 1, log_level: 1 }),
    generatePuzzle: ({ difficulty }) => ({ ok: true, line: `${difficulty}`.repeat(81) }),
    importPuzzleNewGame: () => {
      imported += 1;
      return { ok: true };
    },
  };
  const modal = makeModal();
  const handlers = startupHandlers(game, {}, { generatingModal: modal });
  const running = handlers.generate(2);
  await flushDialogPaint();
  assert.equal(modal.el.hidden, false, "startup generation waits for Continue");
  modal.continueBtn.click();
  const out = await running;
  assert.equal(out.ok, true);
  assert.equal(out.line, "2".repeat(81));
  assert.equal(imported, 0);
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
  // Full-cycle regression guard: an autosave snapshot survives restart with
  // player-entered cells still marked as non-givens.
  const idx = (row, col) => row * 9 + col;
  const fixture = AUTOSAVE_RESTORE_PARITY_FIXTURE;
  let savedBytes = null;
  const fetchFn = async (url, init) => {
    if (url === "./current-file" && init?.method === "POST") {
      savedBytes = new Uint8Array(init.body);
      return { ok: true, status: 204 };
    }
    if (url === "./current-file-exists") return { ok: true, json: async () => ({ exists: savedBytes != null }) };
    throw new Error(`unexpected fetch url: ${url}`);
  };

  const launchA = await loadGame({ auto_restore: true, auto_save: true });
  assert.equal(launchA.importPuzzle(fixture.puzzle_line).ok, true);
  const sessionA = { config: launchA.getConfig(), default_save_filename: "sudoku.sud", boundFilename: null };
  for (const move of fixture.moves) {
    assert.equal(launchA.exec({ action: "fill", row: move.row, col: move.col, digit: move.digit }).ok, true);
    await startAutoSavePolicy(launchA, sessionA, "fill", { fetchFn });
  }
  assert.ok(savedBytes && savedBytes.length > 0, "autosave should persist a startup snapshot");

  const run = await runStartupScenario({
    config: { auto_restore: true, auto_save: true },
    currentFile: { name: "sudoku.sud", bytes: savedBytes },
  });
  assert.equal(run.outcome.kind, "done");
  const restored = run.session.state.cells;
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
    startup_save_path: null,
  };
  delete hostCfg.startup_save_path;
  assert.throws(
    () => assertHostStartupConfig(hostCfg),
    /missing startup_save_path/,
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
    startup_save_path: null,
  };
  delete hostCfg.default_save_filename;
  assert.throws(
    () => assertHostStartupConfig(hostCfg),
    /missing default_save_filename/,
  );
}

