// startup.test.mjs — web startup: host config boot, core startup flow, and the cross-entry parity scenarios.

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import * as sessionMod from "./session.js";
import * as startupMod from "./startup.js";
import * as webSteps from "./web_steps.js";
import * as board from "../board.js";
import * as fileMenu from "../menus/file_menu.js";
import * as menu from "../menus/menu.js";
import * as region from "../menus/region.js";
import * as themeMod from "../menus/theme.js";
import { flushDialogPaint, generatingModalStub, hostFetch, loadGame, moveWithAutosave, postedCurrentFile, settleFlow, startNewGame, coreText, fillText } from "../test_support.mjs";

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
      });
      return { ok: true, msg: "engine ready" };
    },
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
    default_save_filename: "sudoku_save.sud",
    startup_save_path: null,
  };
  const game = {
    bootstrapHostConfig() {
      return { ok: true };
    },
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
  const win = {
    __sudokuChoose: async (text, opts) => {
      asked.push({ text, ...opts });
      return answers.shift() === true;
    },
  };
  const steps = {
    ...webSteps.webSteps(game, session, { fetchFn, win }),
    showError: (text) => errors.push(text),
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
  const prevChoose = globalThis.__sudokuChoose;
  globalThis.__sudokuChoose = async () => assert.fail("a restored game continues its file");
  await moveWithAutosave(run.game, run.session, { fetchFn: host.fetchFn });
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
  assert.equal(run.asked[0].text, fillText(coreText.RESTORE_FAILED_FMT, "game.sud"));
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
    default_save_filename: "sudoku_save.sud",
    startup_save_path: null,
  };
  delete hostCfg.default_save_filename;
  assert.throws(
    () => startupMod.assertHostStartupConfig(hostCfg),
    /missing default_save_filename/,
  );
}


// ── Cross-entry parity: every shared scenario runs through the real wasm and web shell entry paths
// (startup flow, board keys, File menu) against a fake host, held to the same expectations as native.

/** @typedef {{ row: number, col: number }} CellAt */
/** @typedef {{ row: number, col: number, digit: number }} Move */
/** @typedef {{ name: string, puzzle_line: string, moves?: Move[] }} ScenarioFile */
/**
 * @typedef {{
 *   name: string,
 *   skip?: { entry: "native" | "web", gap: string, issue: number },
 *   config: { auto_restore?: boolean, auto_new?: boolean, auto_save?: boolean, difficulty?: string },
 *   current_file?: ScenarioFile,
 *   puzzle_line?: string,
 *   generated_line?: string,
 *   answers: boolean[],
 *   steps: Array<{
 *     fill?: Move, clear?: CellAt, toggle_auto_save?: boolean, toggle_region?: boolean, set_theme?: string,
 *     fill_first_empty?: boolean,
 *     undo?: boolean, redo?: boolean, paste?: string,
 *     open?: ScenarioFile, import?: string,
 *     save?: boolean, copy?: boolean, new?: string, export?: boolean, relaunch?: boolean,
 *   }>,
 *   expect: {
 *     questions: number,
 *     solved_after_startup?: boolean,
 *     written: string[],
 *     status: string | null,
 *     errors?: number,
 *     settings?: { auto_save?: boolean, show_region?: boolean, theme?: string },
 *     legend?: { undo?: boolean, redo?: boolean },
 *     probes: Array<{ row: number, col: number, value: number, given: boolean }>,
 *   },
 * }} Scenario
 */

const PARITY_SCENARIOS = JSON.parse(readFileSync(new URL("../../test/fixtures/parity_scenarios.json", import.meta.url), "utf8"));
const DIFFICULTY_WIRE = { easy: 1, medium: 2, hard: 3 };
const PARITY_CURRENT_FILE = "./current-file";
const PARITY_CURRENT_FILE_EXISTS = "./current-file-exists";
const PARITY_SETTINGS = "./settings.json";
const FILENAME_HEADER = "X-Sudoku-Filename";
const WEB_ENTRY = "web";
const DEFAULT_SAVE_NAME = "sudoku.sud";

/** Host fake: files by name, the current file served at `/current-file`, writes and settings recorded. */
function parityHost() {
  /** @type {Map<string, Uint8Array>} */
  const files = new Map();
  /** @type {string[]} */
  const written = [];
  /** @type {object | null} */
  let settings = null;
  const host = {
    files,
    written,
    /** @type {string | null} */
    current: null,
    settings: () => settings,
    fetchFn: async (url, init = {}) => {
      const name = init.headers?.[FILENAME_HEADER];
      if (url === PARITY_CURRENT_FILE_EXISTS) return { ok: true, json: async () => ({ exists: files.has(name) }) };
      if (url === PARITY_CURRENT_FILE && init.method === "POST") {
        files.set(name, new Uint8Array(init.body));
        written.push(name);
        return { ok: true, status: 204 };
      }
      if (url === PARITY_CURRENT_FILE && init.method === "DELETE") return { ok: true, status: 204 };
      if (url === PARITY_CURRENT_FILE) {
        const bytes = files.get(host.current);
        if (!bytes) return { ok: false, status: 404 };
        return { ok: true, arrayBuffer: async () => bytes.slice().buffer };
      }
      if (url === PARITY_SETTINGS && init.method === "POST") {
        settings = JSON.parse(init.body);
        return { ok: true, status: 204 };
      }
      throw new Error(`unexpected host request: ${init.method ?? "GET"} ${url}`);
    },
  };
  return host;
}

function makeBtn() {
  return {
    handlers: {},
    addEventListener(type, fn) {
      this.handlers[type] = fn;
    },
    async click() {
      await this.handlers.click?.();
    },
  };
}

/** A View menu item: records its click listener and accepts checked-state updates. */
const makeMenuItem = () => ({
  ...makeBtn(),
  setAttribute() {},
  classList: { toggle() {}, add() {}, remove() {}, contains: () => false },
  click() {
    return this.handlers.click?.();
  },
});

const themeRoot = () => ({
  documentElement: { dataset: {} },
  defaultView: { matchMedia: () => ({ matches: false, addEventListener() {} }) },
});

const makeBoard = () => ({ children: [], replaceChildren(...nodes) { this.children = nodes; } });
const createElement = (tag) => ({ tag, classList: { add() {}, remove() {} }, textContent: "", dataset: {}, setAttribute() {} });

/** Bytes of a saved game: `puzzle_line` with the player's `moves` on top. */
async function savedGame(file) {
  const game = await loadGame();
  startNewGame(game, file.puzzle_line);
  for (const m of file.moves ?? []) {
    assert.equal(game.exec({ action: "fill", row: m.row, col: m.col, digit: m.digit }).ok, true);
  }
  const saved = game.toSaveFormat();
  assert.equal(saved.ok, true);
  return saved.bytes;
}

const isSolved = (state) => state.cells.every((c) => c.value !== 0 && !c.conflict);

/** First empty cell and the lowest digit that does not repeat in its row, column or box. */
function firstEmptyLegalFill(state) {
  const at = (r, c) => state.cells[r * 9 + c].value;
  for (let r = 0; r < 9; r += 1) {
    for (let c = 0; c < 9; c += 1) {
      if (at(r, c) !== 0) continue;
      for (let d = 1; d <= 9; d += 1) {
        let clash = false;
        for (let i = 0; i < 9 && !clash; i += 1) {
          const br = Math.floor(r / 3) * 3 + Math.floor(i / 3);
          const bc = Math.floor(c / 3) * 3 + (i % 3);
          clash = at(r, i) === d || at(i, c) === d || at(br, bc) === d;
        }
        if (!clash) return { row: r, col: c, digit: d };
      }
    }
  }
  throw new Error("no legal fill");
}

/**
 * One launch of the web shell: a fresh game and session, the startup flow on the host's current
 * file (if any), and the menus wired to it. A relaunch calls this again against the same host.
 */
async function launchWeb(cfg, host, ui, { generatedLine, expectSolved } = {}) {
  const game = await loadGame(cfg);
  const boot = {
    state: game.getState(),
    legend: game.getLegend(),
    config: game.getConfig(),
    default_save_filename: host.current ?? DEFAULT_SAVE_NAME,
    startup_save_path: host.current ? PARITY_CURRENT_FILE : null,
  };
  const session = sessionMod.createWebSessionFromStartup(boot);
  const run = {
    game,
    session,
    /** @type {import("../types").PickResult | null} */
    picked: null,
    /** @type {string | null} */
    newLine: generatedLine ?? null,
    /** Clipboard text the next Paste reads. */
    pasted: "",
    controls: { new: makeBtn(), open: makeBtn(), import: makeBtn(), save: makeBtn(), export: makeBtn(), autoSave: makeBtn(), viewRegion: makeMenuItem(), viewLight: makeMenuItem(), viewDark: makeMenuItem(), viewSystem: makeMenuItem() },
    easyButton: { el: makeBtn(), difficulty: "easy" },
    steps: null,
  };
  run.steps = {
    ...webSteps.webSteps(game, session, {
      fetchFn: host.fetchFn,
      statusEl: ui.statusEl,
      errorModal: ui.errorModal,
      clipboard: { readText: async () => run.pasted, writeText: async () => {} },
      pick: async () => run.picked,
      download() {},
      exportText: async (_bytes, _session, name) => {
        host.written.push(name);
        return { ok: true, filename: name };
      },
    }),
    generateGame: async () => ({ ok: true, line: run.newLine }),
  };
  if (host.current) {
    const startupErrors = [];
    await startupMod.runStartupFlow(game, boot, { ...run.steps, showError: (t) => startupErrors.push(t) });
    assert.deepEqual(startupErrors, []);
    if (expectSolved !== undefined) assert.equal(isSolved(game.getState()), expectSolved, "solved after startup");
  }

  const { controls, steps } = run;
  region.wireRegionMenu(controls, game, session, ui.boardEl, () => null, { steps });
  themeMod.wireThemeMenu(controls, game, session, { root: themeRoot(), steps });
  fileMenu.wireFileMenu(controls, game, ui.boardEl, { select() {}, deselect() {} }, ui.statusEl, session, { sync() {} }, {
    createElement,
    difficultyDialog: { el: { hidden: true }, buttons: [run.easyButton] },
    steps,
  });
  return run;
}

/** @param {Scenario} scenario */
async function runParityScenario(scenario) {
  const cfg = { ...scenario.config };
  if (typeof cfg.difficulty === "string") cfg.difficulty = DIFFICULTY_WIRE[cfg.difficulty];
  const host = parityHost();
  const answers = [...scenario.answers];
  let questions = 0;
  const prevChoose = globalThis.__sudokuChoose;
  const prevFetch = globalThis.fetch;
  globalThis.__sudokuChoose = async () => {
    questions += 1;
    return answers.shift() ?? true;
  };
  globalThis.fetch = host.fetchFn;
  let errors = 0;
  let lastError = "";
  const ui = {
    statusEl: { textContent: "", className: "" },
    errorModal: {
      el: { hidden: true },
      msgEl: {
        get textContent() {
          return lastError;
        },
        set textContent(text) {
          errors += 1;
          lastError = text;
        },
      },
    },
    boardEl: makeBoard(),
  };
  const { statusEl, boardEl } = ui;
  try {
    if (scenario.current_file) {
      host.files.set(scenario.current_file.name, await savedGame(scenario.current_file));
      host.current = scenario.current_file.name;
    }
    let run = await launchWeb(cfg, host, ui, {
      generatedLine: scenario.generated_line,
      expectSolved: scenario.expect.solved_after_startup,
    });
    if (scenario.puzzle_line) {
      startNewGame(run.game, scenario.puzzle_line);
      run.session.state = run.game.getState();
      run.session.legend = run.game.getLegend();
    }

    for (const step of scenario.steps) {
      const { game, session, controls, steps } = run;
      if (step.relaunch) {
        assert.ok(host.written.length > 0, "relaunch needs a written file");
        host.current = host.written[host.written.length - 1];
        run = await launchWeb(game.getConfig(), host, ui);
        continue;
      }
      if (step.toggle_auto_save) {
        await controls.autoSave.click();
        continue;
      }
      if (step.toggle_region) {
        controls.viewRegion.click();
        await settleFlow();
        continue;
      }
      if (step.set_theme) {
        const item = { light: controls.viewLight, dark: controls.viewDark, system: controls.viewSystem }[step.set_theme];
        item.click();
        await settleFlow();
        continue;
      }
      const edit = step.undo ? "undo" : step.redo ? "redo" : step.hint ? "hint" : step.solve ? "solve" : null;
      if (edit) {
        const selection = { getSelection: () => null, select() {}, deselect() {} };
        await menu.handleEditAction(edit, game, boardEl, selection, session, createElement, { steps }).done;
        continue;
      }
      if (step.paste !== undefined) {
        run.pasted = step.paste;
        await menu.handlePastePuzzle(game, session, steps).done;
        continue;
      }
      if (step.open) {
        run.picked = { ok: true, name: step.open.name, bytes: await savedGame(step.open) };
        await controls.open.click();
        continue;
      }
      if (step.save) {
        await controls.save.click();
        continue;
      }
      if (step.new) {
        run.newLine = step.new;
        await controls.new.click();
        await run.easyButton.el.click();
        continue;
      }
      if (step.export) {
        await controls.export.click();
        continue;
      }
      if (step.copy) {
        await menu.handleCopyPuzzle(game, session, steps);
        continue;
      }
      if (step.import !== undefined) {
        run.picked = { ok: true, name: "puzzle.txt", bytes: new TextEncoder().encode(step.import) };
        await controls.import.click();
        continue;
      }
      const move = step.fill ?? step.clear ?? (step.fill_first_empty ? firstEmptyLegalFill(game.getState()) : null);
      if (!move) throw new Error(`unknown scenario step: ${JSON.stringify(step)}`);
      const selection = { getSelection: () => ({ row: move.row, col: move.col }), select() {} };
      const key = step.clear ? "Delete" : String(move.digit);
      const outcome = board.handlePlayKey(game, boardEl, selection, key, createElement, "", { steps });
      assert.equal(outcome.handled, true);
      await outcome.done;
    }

    const e = scenario.expect;
    assert.equal(questions, e.questions, "questions asked");
    assert.deepEqual(host.written, e.written, "files written");
    assert.equal(statusEl.textContent === "" ? null : statusEl.textContent, e.status, "status");
    assert.equal(errors, e.errors ?? 0, `errors shown (last: ${lastError})`);
    for (const [key, want] of Object.entries(e.settings ?? {})) {
      assert.equal(host.settings()?.[key], want, `persisted ${key}`);
    }
    const legend = run.game.getLegend();
    if (e.legend?.undo !== undefined) assert.equal(legend.undo, e.legend.undo, "legend undo");
    if (e.legend?.redo !== undefined) assert.equal(legend.redo, e.legend.redo, "legend redo");
    const cells = run.game.getState().cells;
    for (const p of e.probes) {
      const c = cells[p.row * 9 + p.col];
      assert.equal(c.value, p.value, `probe ${p.row},${p.col} value`);
      assert.equal(c.given, p.given, `probe ${p.row},${p.col} given`);
    }
  } finally {
    globalThis.__sudokuChoose = prevChoose;
    globalThis.fetch = prevFetch;
  }
}

assert.ok(PARITY_SCENARIOS.scenarios.length > 0);
for (const scenario of PARITY_SCENARIOS.scenarios) {
  if (scenario.skip?.entry === WEB_ENTRY) continue;
  try {
    await runParityScenario(scenario);
  } catch (err) {
    console.error(`parity scenario failed: ${scenario.name}`);
    throw err;
  }
}
