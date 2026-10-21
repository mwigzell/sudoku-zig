// shell.test.mjs — worker gen handoff: import on success, no import on cancel.

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import {
  NEW_GAME_STARTED_MSG,
  CURRENT_FILE_DESKTOP_ID,
  persistCurrentFileSnapshot,
  startAutoSavePolicy,
  postWriteContextEvent,
  applySessionOutcome,
  applySessionOutcomeStatus,
  persistCurrentFileSnapshotWithReplacePrompt,
  hostViewPrefsForPersist,
  postWriteContextEventForSession,
  postSessionWriteContextEvent,
  WRITE_CONTEXT_CONTINUATION,
  WRITE_CONTEXT_DETACHED,
  initializeWebSession,
  offerInitialNewGame,
  newGameWithGeneratingModal,
  newGameWithWorkerGen,
  importPuzzle,
  currentFileLabel,
  syncCurrentFileLabels,
  createWebSessionFromStartup,
  startStartupContextPublish,
  wireFinalSnapshotOnPageHide,
  assertWebBootConfig,
  assertHostStartupConfig,
  REQUIRED_WEB_BOOT_CONFIG_KEYS,
  REQUIRED_WRITE_CONTEXT_EVENT_KEYS,
  REQUIRED_STARTUP_READY_KEYS,
} from "./shell.js";
import { wireGeneratingModal } from "./generating.js";

const AUTO_SAVE_TRIGGERS = [
  "fill",
  "clear",
  "undo",
  "redo",
  "solve",
  "solve_for_me",
  "open",
  "import",
  "paste",
];
const WRITE_CONTEXT_EVENTS = Object.fromEntries(
  REQUIRED_WRITE_CONTEXT_EVENT_KEYS.map((name) => [name, name]),
);
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
  const calls = [];
  const game = {
    serialize() {
      return { ok: true, bytes: new Uint8Array([1, 2]) };
    },
  };
  const out = await persistCurrentFileSnapshot(
    game,
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
  const out = await postWriteContextEvent("new_game_success", async (url, init) => {
    calls.push({ url, init });
    return { ok: true, status: 204 };
  });
  assert.equal(out.ok, true);
  assert.equal(calls[0].url, "./current-file-context");
  assert.equal(calls[0].init.method, "POST");
  assert.equal(calls[0].init.body, "new_game_success");
}

{
  const ready = {
    state: { cells: [] },
    legend: { new: true },
    config: { auto_save: true },
    default_save_filename: "sudoku.sud",
    autosave_trigger_commands: AUTO_SAVE_TRIGGERS,
    write_context_events: WRITE_CONTEXT_EVENTS,
  };
  const session = createWebSessionFromStartup(ready);
  assert.equal(session.write_context, WRITE_CONTEXT_DETACHED);
  assert.equal(typeof session.writeContextEvent, "function");
  assert.equal(session.startup_context_ready, null);
  assert.equal(session.default_save_filename, "sudoku.sud");
}

{
  const ready = {
    state: { cells: [] },
    legend: {},
    config: {},
    default_save_filename: "sudoku.sud",
    autosave_trigger_commands: [],
  };
  assert.throws(
    () => createWebSessionFromStartup(ready),
    /autosave_trigger_commands must be a non-empty array/,
  );
}

{
  for (const key of REQUIRED_STARTUP_READY_KEYS) {
    const ready = {
      state: { cells: [] },
      legend: {},
      config: {},
      default_save_filename: "sudoku.sud",
      autosave_trigger_commands: AUTO_SAVE_TRIGGERS,
    };
    delete ready[key];
    assert.throws(
      () => createWebSessionFromStartup(ready),
      new RegExp(`missing ${key}`),
    );
  }
}

{
  const session = {
    write_context: WRITE_CONTEXT_DETACHED,
    writeContextEvent: postWriteContextEvent,
  };
  const pending = startStartupContextPublish(
    session,
    "startup_restore",
    async () => ({
      ok: true,
      status: 200,
      json: async () => ({ write_context: WRITE_CONTEXT_CONTINUATION }),
    }),
  );
  assert.equal(session.startup_context_ready, pending);
  const out = await pending;
  assert.equal(out.ok, true);
  assert.equal(session.write_context, WRITE_CONTEXT_CONTINUATION);
}

{
  const listeners = new Map();
  const win = {
    addEventListener(name, fn) {
      listeners.set(name, fn);
    },
    removeEventListener(name, fn) {
      if (listeners.get(name) === fn) listeners.delete(name);
    },
  };
  const calls = [];
  const game = {
    serialize() {
      return { ok: true, bytes: new Uint8Array([5, 6, 7]) };
    },
  };
  const session = {
    config: { auto_save: true },
    boundFilename: "autosave.sud",
  };
  wireFinalSnapshotOnPageHide(game, session, {
    win,
    fetchFn: async (url, init) => {
      calls.push({ url, init });
      return { ok: true, status: 204 };
    },
  });
  listeners.get("pagehide")?.();
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(calls.length, 1);
  assert.equal(calls[0].url, "./current-file");
  assert.equal(calls[0].init.keepalive, true);
}

{
  const listeners = new Map();
  const win = {
    addEventListener(name, fn) {
      listeners.set(name, fn);
    },
    removeEventListener(name, fn) {
      if (listeners.get(name) === fn) listeners.delete(name);
    },
  };
  let called = false;
  const game = {
    serialize() {
      called = true;
      return { ok: true, bytes: new Uint8Array([1]) };
    },
  };
  const session = {
    config: { auto_save: false },
    boundFilename: "autosave.sud",
  };
  wireFinalSnapshotOnPageHide(game, session, {
    win,
    fetchFn: async () => ({ ok: true, status: 204 }),
  });
  listeners.get("pagehide")?.();
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(called, false);
}

{
  const session = { write_context: WRITE_CONTEXT_DETACHED, writeContextEvent: postWriteContextEvent };
  const out = await postWriteContextEventForSession(
    session,
    "startup_restore",
    async () => ({ ok: true, status: 200, json: async () => ({ write_context: WRITE_CONTEXT_CONTINUATION }) }),
  );
  assert.equal(out.ok, true);
  assert.equal(session.write_context, WRITE_CONTEXT_CONTINUATION);
}

{
  const session = {
    write_context: WRITE_CONTEXT_DETACHED,
    write_context_events: { auto_save_success: "auto_save_success_custom" },
    writeContextEvent: postWriteContextEvent,
  };
  const calls = [];
  const out = await postSessionWriteContextEvent(
    session,
    "auto_save_success",
    async (url, init) => {
      calls.push({ url, init });
      return {
        ok: true,
        status: 200,
        json: async () => ({ write_context: WRITE_CONTEXT_CONTINUATION }),
      };
    },
  );
  assert.equal(out.ok, true);
  assert.equal(calls.length, 1);
  assert.equal(calls[0].init.body, "auto_save_success_custom");
  assert.equal(session.write_context, WRITE_CONTEXT_CONTINUATION);
}

{
  const game = {
    serialize() {
      return { ok: true, bytes: new Uint8Array([1, 2]) };
    },
  };
  const calls = [];
  const out = await persistCurrentFileSnapshot(game, async (url, init) => {
    calls.push({ url, init });
    if (calls.length === 1) return { ok: false, status: 409, text: async () => "file already exists, replace?" };
    return { ok: true, status: 204 };
  });
  assert.equal(out.ok, false);
  assert.equal(out.replace_required, true);
  assert.equal(out.error, "file already exists, replace?");
}

{
  const game = {
    serialize() {
      return { ok: true, bytes: new Uint8Array([1, 2]) };
    },
  };
  const calls = [];
  const out = await persistCurrentFileSnapshotWithReplacePrompt(game, {
    fetchFn: async (url, init) => {
      calls.push({ url, init });
      if (calls.length === 1) return { ok: false, status: 409, text: async () => "file already exists, replace?" };
      return { ok: true, status: 204 };
    },
    askConfirm: (msg) => {
      assert.equal(msg, "existing.sud exists, replace?");
      return true;
    },
    saveName: "existing.sud",
  });
  assert.equal(out.ok, true);
  assert.equal(calls.length, 2);
  assert.equal(calls[1].init.headers["X-Sudoku-Replace"], "true");
}

{
  const game = {
    serialize() {
      return { ok: true, bytes: new Uint8Array([1, 2]) };
    },
  };
  const out = await persistCurrentFileSnapshotWithReplacePrompt(game, {
    fetchFn: async () => ({ ok: false, status: 409, text: async () => "file already exists, replace?" }),
    askConfirm: (msg) => {
      assert.equal(msg, "File exists, replace?");
      return false;
    },
  });
  assert.equal(out.ok, false);
  assert.equal(out.cancelled, true);
}

{
  assert.equal(currentFileLabel({}), "");
  assert.equal(currentFileLabel({ default_save_filename: "sudoku.sud" }), "sudoku.sud");
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
  assert.equal(labels[CURRENT_FILE_DESKTOP_ID].textContent, "save.sud");
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
  const hostCfg = {
    difficulty: 2,
    log_level: 1,
    theme: "dark",
    show_region: false,
    warn_solvability: false,
    auto_restore: false,
    auto_new: false,
    auto_save: false,
    autosave_trigger_commands: AUTO_SAVE_TRIGGERS,
    write_context_events: WRITE_CONTEXT_EVENTS,
    default_save_filename: "sudoku_save.sud",
    startup_action: "new",
    startup_context_event: "startup_new",
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
    autosave_trigger_commands: AUTO_SAVE_TRIGGERS,
    write_context_events: WRITE_CONTEXT_EVENTS,
    default_save_filename: "sudoku_save.sud",
    startup_action: "idle",
    startup_context_event: "startup_idle",
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
      autosave_trigger_commands: AUTO_SAVE_TRIGGERS,
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
  assert.deepEqual(manual.autosave_trigger_commands, AUTO_SAVE_TRIGGERS);
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
      autosave_trigger_commands: AUTO_SAVE_TRIGGERS,
      startup_context_event: "startup_restore",
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
  assert.deepEqual(out.autosave_trigger_commands, AUTO_SAVE_TRIGGERS);
}

{
  // Slow-user lifecycle seam: startup context publish is fire-and-forget, so the
  // first autosave after restore can race and be dropped (no retry).
  const writes = [];
  let contextReady = false;
  let releaseContext = null;
  const game = {
    serialize() {
      return { ok: true, bytes: new Uint8Array([9]) };
    },
  };
  const session = {
    config: { auto_save: true },
    autosave_trigger_commands: AUTO_SAVE_TRIGGERS,
    boundFilename: "autosave.sud",
    write_context: WRITE_CONTEXT_DETACHED,
    writeContextEvent: postWriteContextEvent,
  };
  const fetchFn = async (url, init) => {
    if (url === "./current-file-context") {
      return await new Promise((resolve) => {
        releaseContext = () => {
          contextReady = true;
          resolve({
            ok: true,
            status: 200,
            json: async () => ({ write_context: WRITE_CONTEXT_CONTINUATION }),
          });
        };
      });
    }
    if (url === "./current-file") {
      if (!contextReady) {
        return { ok: false, status: 409, text: async () => "file already exists, replace?" };
      }
      writes.push(new Uint8Array(init.body));
      return { ok: true, status: 204 };
    }
    throw new Error(`unexpected fetch url: ${url}`);
  };

  // Matches page boot behavior: startup context publish starts before user edits.
  session.startup_context_ready = postWriteContextEventForSession(
    session,
    "startup_restore",
    fetchFn,
  );
  startAutoSavePolicy(game, session, "fill", { fetchFn });
  await new Promise((resolve) => setImmediate(resolve));
  releaseContext?.();
  await new Promise((resolve) => setImmediate(resolve));

  assert.equal(
    writes.length,
    1,
    "first autosave after restore should not be dropped when startup context publish is in-flight",
  );
}

{
  // Reliability seam: failed startup-context publish must not block autosave.
  const writes = [];
  const startupContextFailed = Promise.reject(new Error("context publish failed"));
  startupContextFailed.catch(() => {});
  const game = {
    serialize() {
      return { ok: true, bytes: new Uint8Array([7]) };
    },
  };
  const session = {
    config: { auto_save: true },
    autosave_trigger_commands: AUTO_SAVE_TRIGGERS,
    boundFilename: "autosave.sud",
    writeContextEvent: async () => ({ ok: true }),
    startup_context_ready: startupContextFailed,
  };
  const fetchFn = async (url, init) => {
    if (url === "./current-file") {
      writes.push(new Uint8Array(init.body));
      return { ok: true, status: 204 };
    }
    throw new Error(`unexpected fetch url: ${url}`);
  };

  startAutoSavePolicy(game, session, "fill", { fetchFn });
  await session.__autosave_lane;
  assert.equal(writes.length, 1, "autosave should proceed even when startup context publish fails");
  assert.equal(session.startup_context_ready, null, "failed startup context promise should be cleared");
}

{
  // Autosave ordering contract: overlapping saves must persist latest state.
  const writes = [];
  let firstWriteResolve = null;
  let currentSnapshot = new Uint8Array([1]);
  const game = {
    serialize() {
      return { ok: true, bytes: currentSnapshot };
    },
  };
  const session = {
    config: { auto_save: true },
    autosave_trigger_commands: AUTO_SAVE_TRIGGERS,
    boundFilename: "autosave.sud",
    write_context: WRITE_CONTEXT_DETACHED,
    writeContextEvent: postWriteContextEvent,
  };
  const fetchFn = async (url, init) => {
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
    if (url === "./current-file-context") {
      return {
        ok: true,
        status: 200,
        json: async () => ({ write_context: WRITE_CONTEXT_CONTINUATION }),
      };
    }
    throw new Error(`unexpected fetch url: ${url}`);
  };

  // First autosave captures snapshot [1], but is delayed.
  startAutoSavePolicy(game, session, "fill", { fetchFn });
  // Second autosave captures newer snapshot [2], and completes immediately.
  currentSnapshot = new Uint8Array([2]);
  startAutoSavePolicy(game, session, "fill", { fetchFn });
  await new Promise((resolve) => setImmediate(resolve));

  // Release the delayed first save last (stale completion ordering hazard).
  firstWriteResolve?.();
  await new Promise((resolve) => setImmediate(resolve));

  assert.equal(writes.length, 2);
  assert.deepEqual(
    [...writes[writes.length - 1]],
    [2],
    "latest autosave snapshot must win even if earlier save completes later",
  );
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
  let writeContext = WRITE_CONTEXT_DETACHED;
  const hostCfg = () => ({
    difficulty: 1,
    log_level: 1,
    theme: "dark",
    show_region: false,
    warn_solvability: false,
    auto_restore: true,
    auto_new: false,
    auto_save: true,
    autosave_trigger_commands: AUTO_SAVE_TRIGGERS,
    write_context_events: WRITE_CONTEXT_EVENTS,
    default_save_filename: "sudoku.sud",
    startup_action: savedBytes ? "restore" : "idle",
    startup_context_event: savedBytes ? "startup_restore" : "startup_idle",
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
    if (url === "./current-file-context" && init?.method === "POST") {
      const event = String(init.body ?? "");
      if (event === "startup_restore" || event === "auto_save_success") writeContext = WRITE_CONTEXT_CONTINUATION;
      if (event === "startup_new" || event === "startup_idle" || event === "new_game_success" || event === "import_success" || event === "paste_success") {
        writeContext = WRITE_CONTEXT_DETACHED;
      }
      return { ok: true, status: 200, json: async () => ({ write_context: writeContext }) };
    }
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

  const launchA = makeGame();
  const bootA = await initializeWebSession(launchA, { fetchFn });
  const readyA = await offerInitialNewGame(launchA, bootA, null, { fetchFn });
  assert.equal(readyA.ok, true);
  assert.equal(readyA.kind, "empty");
  const sessionA = {
    config: readyA.config,
    autosave_trigger_commands: readyA.autosave_trigger_commands,
    default_save_filename: readyA.default_save_filename,
    boundFilename: null,
    write_context: WRITE_CONTEXT_DETACHED,
    writeContextEvent: postWriteContextEvent,
  };
  sessionA.startup_context_ready = postWriteContextEventForSession(
    sessionA,
    readyA.startup_context_event,
    fetchFn,
  );

  for (const move of fixture.moves) {
    launchA.exec({ action: "fill", row: move.row, col: move.col, digit: move.digit });
    startAutoSavePolicy(launchA, sessionA, "fill", { fetchFn });
  }
  await sessionA.__autosave_lane;
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
      autosave_trigger_commands: AUTO_SAVE_TRIGGERS,
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
  assert.deepEqual(out.autosave_trigger_commands, AUTO_SAVE_TRIGGERS);
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
      autosave_trigger_commands: AUTO_SAVE_TRIGGERS,
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
  modal.continueBtn.click();
  const out = await running;
  assert.equal(out.ok, true);
  assert.equal(out.kind, "new");
  assert.equal(initDifficulty, 2);
  assert.equal(out.default_save_filename, "sudoku.sud");
  assert.deepEqual(out.autosave_trigger_commands, AUTO_SAVE_TRIGGERS);
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
      autosave_trigger_commands: AUTO_SAVE_TRIGGERS,
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
    autosave_trigger_commands: AUTO_SAVE_TRIGGERS,
    write_context_events: WRITE_CONTEXT_EVENTS,
    default_save_filename: "sudoku_save.sud",
    startup_context_event: "startup_idle",
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
    autosave_trigger_commands: AUTO_SAVE_TRIGGERS,
    write_context_events: WRITE_CONTEXT_EVENTS,
    default_save_filename: "sudoku_save.sud",
    startup_context_event: "startup_idle",
    startup_status: null,
  };
  delete hostCfg.default_save_filename;
  assert.throws(
    () => assertHostStartupConfig(hostCfg),
    /missing default_save_filename/,
  );
}

