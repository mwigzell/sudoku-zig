// shell.test.mjs — worker gen handoff: import on success, no import on cancel.

import assert from "node:assert/strict";
import {
  NEW_GAME_STARTED_MSG,
  hostViewPrefsForPersist,
  initializeWebSession,
  offerInitialNewGame,
  newGameWithGeneratingModal,
  newGameWithWorkerGen,
  assertWebBootConfig,
  assertHostStartupConfig,
  REQUIRED_WEB_BOOT_CONFIG_KEYS,
} from "./shell.js";
import { wireGeneratingModal } from "./generating.js";

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
      return { ok: true, msg: "import: puzzle loaded" };
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
  assert.equal(out.msg, NEW_GAME_STARTED_MSG);
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
      return { ok: true, msg: "import: puzzle loaded" };
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
  assert.equal(out.msg, NEW_GAME_STARTED_MSG);
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
  const game = {
    deserialize() {
      return { ok: true, state: restoredState, msg: "opened: startup-save.sud" };
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
      startup_status: null,
      startup_save_path: "./current-file",
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
      startup_status: null,
      startup_save_path: "./current-file",
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
}

{
  const missing = await offerInitialNewGame(
    {},
    { ok: true, kind: "empty", startup_action: "new", state: {}, legend: {}, config: {} },
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
      return { ok: true, msg: NEW_GAME_STARTED_MSG };
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
      startup_status: null,
      config: { difficulty: 2, log_level: 1 },
      state: {},
      legend: {},
    },
    modal,
  );
  await flushDialogPaint();
  modal.continueBtn.click();
  const out = await running;
  assert.equal(out.ok, true);
  assert.equal(out.kind, "new");
  assert.equal(initDifficulty, 2);
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
    startup_status: null,
  };
  delete hostCfg.default_save_filename;
  assert.throws(
    () => assertHostStartupConfig(hostCfg),
    /missing default_save_filename/,
  );
}

