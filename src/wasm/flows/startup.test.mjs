// startup.test.mjs — web startup: host config boot and the core startup flow.

import assert from "node:assert/strict";
import * as sessionMod from "./session.js";
import * as startupMod from "./startup.js";
import * as webSteps from "./web_steps.js";
import * as board from "../board.js";
import { flushDialogPaint, generatingModalStub, hostFetch, loadGame, moveWithAutosave, noPromptDialog, postedCurrentFile, startNewGame, coreText, fillText } from "../test_support.mjs";

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
    show_marks: false,
    default_save_filename: "sudoku_save.sud",
    startup_save_path: "/current-file",
  };
  /** @type {unknown[]} */
  const buildInfoCalls = [];
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
        show_marks: false,
      });
      return { ok: true, msg: "engine ready" };
    },
    logEnabled: () => false,
    setHostBuildInfo(info) {
      buildInfoCalls.push(info);
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
        show_marks: false,
      };
    },
  };
  const out = await startupMod.initializeWebSession(game, {
    fetchFn: async (url) => ({
      ok: true,
      json: async () => (url === "./build-info.json" ? { debug_build: true } : hostCfg),
    }),
  });
  assert.equal(out.ok, true);
  assert.deepEqual(buildInfoCalls, [{ debug_build: true }], "host build facts reach wasm apart from config");
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
    show_marks: false,
    default_save_filename: "sudoku_save.sud",
    startup_save_path: null,
  };
  const game = {
    bootstrapHostConfig() {
      return { ok: true };
    },
    logEnabled: () => false,
    setHostBuildInfo() {},
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
  const out = await startupMod.initializeWebSession(game, {
    fetchFn: async () => ({ ok: true, json: async () => hostCfg }),
  });
  assert.equal(out.ok, true);
  assert.equal(out.startup_save_path, null);
}

// ── startup flow: core decides restore / new / idle; the web only fetches, draws and asks ──
const SOLVED_LINE = "483921657967345821251876493548132976729564138136798245372689514814253769695417382";
const OPEN_LINE = "530070000600195000098000060800060003400803001700020006060000280000419005000080079";
const WELCOME_STATUS = coreText.IDLE_STARTUP_STATUS;
const HOST_CURRENT_FILE = "/current-file";

/** Bytes of a saved game holding `line`. */
async function savedGameBytes(line) {
  const source = await loadGame();
  startNewGame(source, line);
  return source.toSaveFormat().bytes;
}

/**
 * Run the startup flow on a real game with recording handlers.
 * `answers` feeds each `ask`; `generated` answers each `generate_game`.
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
  const session = sessionMod.createWebSessionFromStartup(boot);
  const promptDialog = {
    show: async (step) => {
      if (step.buttons.length === 1) {
        errors.push(step.text);
        return step.default;
      }
      asked.push(step);
      return answers.shift() === true ? step.default : step.dismiss;
    },
    dismiss() {},
  };
  const steps = {
    ...webSteps.webSteps(game, session, { fetchFn, promptDialog }),
    generateGame: async (difficulty) => {
      generateCalls.push(difficulty);
      return generated.shift() ?? { ok: false, error: "no generation scripted" };
    },
  };
  const outcome = await startupMod.runStartupFlow(game, boot, steps, (step) => shown.push({ text: step.text, file: step.file }));
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

  const host = hostFetch({ exists: true });
  await moveWithAutosave(run.game, run.session, { fetchFn: host.fetchFn, promptDialog: noPromptDialog("a restored game continues its file") });
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
  assert.equal(run.asked[0].text, fillText(coreText.RESTORE_FAILED_FMT, "game.sud"));
  assert.equal(run.asked[0].type, "error");
  assert.deepEqual(run.asked[0].buttons, ["Keep", "Delete"]);
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
  assert.equal(run.asked[0].type, "information");
  assert.equal(run.asked[0].buttons[run.asked[0].default], "New game");
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
  assert.equal(run.outcome.kind, "done");
  assert.deepEqual(run.shown, [{ text: WELCOME_STATUS, file: null }]);
  assert.deepEqual(run.errors, [coreText.GENERATE_FAILED_MSG]);
}

{
  // The web generate_game step hands core the line; Continue still closes the modal.
  const game = {
    getConfig: () => ({ difficulty: 1, log_level: 1 }),
    generatePuzzle: ({ difficulty }) => ({ ok: true, line: `${difficulty}`.repeat(81) }),
  };
  const modal = generatingModalStub();
  const steps = webSteps.webSteps(game, {}, { generatingModal: modal });
  const running = steps.generateGame(2);
  await flushDialogPaint();
  assert.equal(modal.el.hidden, false, "startup generation waits for Continue");
  modal.continueBtn.click();
  const out = await running;
  assert.equal(out.ok, true);
  assert.equal(out.line, "2".repeat(81));
}

{
  for (const key of startupMod.REQUIRED_WEB_BOOT_CONFIG_KEYS) {
    const cfg = {
      difficulty: 1,
      log_level: 1,
      theme: "dark",
      show_region: false,
      warn_solvability: false,
      auto_restore: false,
      auto_new: false,
      auto_save: false,
      show_marks: false,
      default_save_filename: "sudoku_save.sud",
    };
    delete cfg[key];
    assert.throws(() => startupMod.assertWebBootConfig(cfg), new RegExp(`missing ${key}`));
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
    show_marks: false,
    default_save_filename: "sudoku_save.sud",
    startup_save_path: null,
  };
  delete hostCfg.startup_save_path;
  assert.throws(
    () => startupMod.assertHostStartupConfig(hostCfg),
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
    show_marks: false,
    default_save_filename: "sudoku_save.sud",
    startup_save_path: null,
  };
  delete hostCfg.default_save_filename;
  assert.throws(
    () => startupMod.assertHostStartupConfig(hostCfg),
    /missing default_save_filename/,
  );
}
