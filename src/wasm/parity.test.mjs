// parity.test.mjs — cross-entry parity scenarios, web side: each scenario in
// `src/test/parity/scenarios.json` runs through the real wasm and web shell entry paths
// (startup flow, board keys, File menu) against a fake host, and must meet the shared expectations.

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { loadGame, settleFlow } from "./test_support.mjs";
import { createWebSessionFromStartup, runStartupFlow, settingsHandlers, startupHandlers } from "./shell.js";
import { handlePlayKey } from "./board.js";
import { wireFileMenu } from "./file_menu.js";
import { handleEditAction, handlePastePuzzle } from "./menu.js";

/** @typedef {{ row: number, col: number }} CellAt */
/** @typedef {{ row: number, col: number, digit: number }} Move */
/**
 * @typedef {{
 *   name: string,
 *   skip?: { entry: "native" | "web", gap: string, issue: number },
 *   config: { auto_restore?: boolean, auto_new?: boolean, auto_save?: boolean, difficulty?: string },
 *   current_file?: { name: string, puzzle_line: string, moves?: Move[] },
 *   puzzle_line?: string,
 *   generated_line?: string,
 *   answers: boolean[],
 *   steps: Array<{
 *     fill?: Move, clear?: CellAt, set_auto_save?: boolean, fill_first_empty?: boolean,
 *     undo?: boolean, redo?: boolean, paste?: string,
 *   }>,
 *   expect: {
 *     questions: number,
 *     solved_after_startup?: boolean,
 *     written: string[],
 *     status: string | null,
 *     errors?: number,
 *     settings?: { auto_save?: boolean },
 *     legend?: { undo?: boolean, redo?: boolean },
 *     probes: Array<{ row: number, col: number, value: number, given: boolean }>,
 *   },
 * }} Scenario
 */

const SCENARIOS = JSON.parse(readFileSync(new URL("../test/parity/scenarios.json", import.meta.url), "utf8"));
const DIFFICULTY_WIRE = { easy: 1, medium: 2, hard: 3 };
const CURRENT_FILE = "./current-file";
const CURRENT_FILE_EXISTS = "./current-file-exists";
const SETTINGS = "./settings.json";
const FILENAME_HEADER = "X-Sudoku-Filename";
const WEB_ENTRY = "web";

/** Host fake: files by name, the current file served at `/current-file`, writes and settings recorded. */
function fakeHost(currentName) {
  /** @type {Map<string, Uint8Array>} */
  const files = new Map();
  /** @type {string[]} */
  const written = [];
  /** @type {object | null} */
  let settings = null;
  const fetchFn = async (url, init = {}) => {
    const name = init.headers?.[FILENAME_HEADER];
    if (url === CURRENT_FILE_EXISTS) return { ok: true, json: async () => ({ exists: files.has(name) }) };
    if (url === CURRENT_FILE && init.method === "POST") {
      files.set(name, new Uint8Array(init.body));
      written.push(name);
      return { ok: true, status: 204 };
    }
    if (url === CURRENT_FILE && init.method === "DELETE") return { ok: true, status: 204 };
    if (url === CURRENT_FILE) {
      const bytes = files.get(currentName);
      if (!bytes) return { ok: false, status: 404 };
      return { ok: true, arrayBuffer: async () => bytes.slice().buffer };
    }
    if (url === SETTINGS && init.method === "POST") {
      settings = JSON.parse(init.body);
      return { ok: true, status: 204 };
    }
    throw new Error(`unexpected host request: ${init.method ?? "GET"} ${url}`);
  };
  return { files, written, fetchFn, settings: () => settings };
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

const makeBoard = () => ({ children: [], replaceChildren(...nodes) { this.children = nodes; } });
const createElement = (tag) => ({ tag, classList: { add() {}, remove() {} }, textContent: "", dataset: {}, setAttribute() {} });

/** Bytes of a saved game: `puzzle_line` with the player's `moves` on top. */
async function savedGame(file) {
  const game = await loadGame();
  assert.equal(game.importPuzzle(file.puzzle_line).ok, true);
  for (const m of file.moves ?? []) {
    assert.equal(game.exec({ action: "fill", row: m.row, col: m.col, digit: m.digit }).ok, true);
  }
  const saved = game.serialize();
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

/** @param {Scenario} scenario */
async function runScenario(scenario) {
  const cfg = { ...scenario.config };
  if (typeof cfg.difficulty === "string") cfg.difficulty = DIFFICULTY_WIRE[cfg.difficulty];
  const game = await loadGame(cfg);
  const host = fakeHost(scenario.current_file?.name ?? null);
  const answers = [...scenario.answers];
  let questions = 0;
  const prevChoose = globalThis.__sudokuChoose;
  const prevFetch = globalThis.fetch;
  globalThis.__sudokuChoose = async () => {
    questions += 1;
    return answers.shift() ?? true;
  };
  globalThis.fetch = host.fetchFn;
  const statusEl = { textContent: "", className: "" };
  let errors = 0;
  let lastError = "";
  const errorModal = {
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
  };
  const boardEl = makeBoard();
  try {
    const boot = {
      state: game.getState(),
      legend: game.getLegend(),
      config: game.getConfig(),
      default_save_filename: scenario.current_file?.name ?? "sudoku.sud",
      startup_save_path: scenario.current_file ? CURRENT_FILE : null,
    };
    const session = createWebSessionFromStartup(boot);

    if (scenario.current_file) {
      host.files.set(scenario.current_file.name, await savedGame(scenario.current_file));
      const errors = [];
      const handlers = {
        ...startupHandlers(game, session, { fetchFn: host.fetchFn, win: globalThis, showError: (t) => errors.push(t) }),
        generate: async () => ({ ok: true, line: scenario.generated_line }),
      };
      await runStartupFlow(game, boot, handlers);
      assert.deepEqual(errors, []);
      if (scenario.expect.solved_after_startup !== undefined) {
        assert.equal(isSolved(game.getState()), scenario.expect.solved_after_startup, "solved after startup");
      }
    }
    if (scenario.puzzle_line) {
      assert.equal(game.importPuzzle(scenario.puzzle_line).ok, true);
      session.state = game.getState();
      session.legend = game.getLegend();
    }

    const controls = { autoSave: makeBtn() };
    wireFileMenu(controls, game, boardEl, { select() {}, deselect() {} }, statusEl, errorModal, session, { sync() {} }, {
      createElement,
      difficultyDialog: { el: { hidden: true }, buttons: [] },
      settingsFlow: settingsHandlers({ fetchFn: host.fetchFn }),
    });

    for (const step of scenario.steps) {
      if (step.set_auto_save !== undefined) {
        if ((session.config?.auto_save === true) !== step.set_auto_save) await controls.autoSave.click();
        continue;
      }
      const edit = step.undo ? "undo" : step.redo ? "redo" : null;
      if (edit) {
        const selection = { getSelection: () => null, select() {}, deselect() {} };
        handleEditAction(edit, game, boardEl, selection, statusEl, errorModal, session, createElement);
        await settleFlow();
        continue;
      }
      if (step.paste !== undefined) {
        const clipboard = { readText: async () => step.paste };
        await handlePastePuzzle(game, session, statusEl, errorModal, { clipboard });
        await settleFlow();
        continue;
      }
      const move = step.fill ?? step.clear ?? (step.fill_first_empty ? firstEmptyLegalFill(game.getState()) : null);
      if (!move) throw new Error(`unknown scenario step: ${JSON.stringify(step)}`);
      const selection = { getSelection: () => ({ row: move.row, col: move.col }), select() {} };
      const key = step.clear ? "Delete" : String(move.digit);
      const outcome = handlePlayKey(game, boardEl, selection, statusEl, errorModal, key, session, createElement);
      assert.equal(outcome.handled, true);
      await settleFlow();
    }

    const e = scenario.expect;
    assert.equal(questions, e.questions, "questions asked");
    assert.deepEqual(host.written, e.written, "files written");
    assert.equal(statusEl.textContent === "" ? null : statusEl.textContent, e.status, "status");
    assert.equal(errors, e.errors ?? 0, `errors shown (last: ${lastError})`);
    if (e.settings?.auto_save !== undefined) {
      assert.equal(host.settings()?.auto_save, e.settings.auto_save, "persisted auto_save");
    }
    const legend = game.getLegend();
    if (e.legend?.undo !== undefined) assert.equal(legend.undo, e.legend.undo, "legend undo");
    if (e.legend?.redo !== undefined) assert.equal(legend.redo, e.legend.redo, "legend redo");
    const cells = game.getState().cells;
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

assert.ok(SCENARIOS.scenarios.length > 0);
for (const scenario of SCENARIOS.scenarios) {
  if (scenario.skip?.entry === WEB_ENTRY) continue;
  try {
    await runScenario(scenario);
  } catch (err) {
    console.error(`parity scenario failed: ${scenario.name}`);
    throw err;
  }
}
