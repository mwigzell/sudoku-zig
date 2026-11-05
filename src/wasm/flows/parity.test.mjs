// parity.test.mjs — cross-front-end parity, web and Android side: every shared scenario runs through the
// real web shell entries (startup flow, board keys, Edit, File, View and Settings menus) with the browser's
// and Android's step handlers over a fake folder, host and file bridge. Each run must meet the scenario's
// expectations and record the same steps and end state as the native run (`test/parity/native.zig`).

import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import * as androidSteps from "./android_steps.js";
import * as autosave from "./autosave.js";
import * as sessionMod from "./session.js";
import * as startupMod from "./startup.js";
import * as stepRunner from "./step_runner.js";
import * as webSteps from "./web_steps.js";
import * as board from "../board.js";
import * as fileMenu from "../menus/file_menu.js";
import * as menu from "../menus/menu.js";
import * as region from "../menus/region.js";
import * as settingsMenu from "../menus/settings.js";
import * as themeMod from "../menus/theme.js";
import { generatingModalStub, loadGame, settleFlow } from "../test_support.mjs";

/** @typedef {import("../types").GameApi} GameApi */
/** @typedef {import("../types").FlowStep} FlowStep */

const SCENARIOS_URL = new URL("../../test/fixtures/parity_scenarios.json", import.meta.url);
const NATIVE_TRANSCRIPTS_URL = new URL("../../../.zig-cache/parity/native.json", import.meta.url);
const SCENARIOS = JSON.parse(readFileSync(SCENARIOS_URL, "utf8"));
assert.ok(
  existsSync(NATIVE_TRANSCRIPTS_URL),
  "native parity transcripts missing: the glue step runs the native tests first (zig build glue)",
);
const NATIVE = JSON.parse(readFileSync(NATIVE_TRANSCRIPTS_URL, "utf8"));
const NATIVE_BY_NAME = new Map(NATIVE.scenarios.map((t) => [t.name, t]));

const NATIVE_ENTRY = "native";
const WEB = "web";
const ANDROID = "android";
const PLATFORMS = [WEB, ANDROID];
const PROMPT_TYPES = ["information", "warning", "error"];
const DIFFICULTY_NAMES = { 1: "easy", 2: "medium", 3: "hard" };
const DIFFICULTY_WIRE = { easy: 1, medium: 2, hard: 3 };
const LOG_LEVEL_NAMES = ["debug", "info", "warn", "err", "fatal"];
const DEFAULT_SAVE_NAME = "sudoku.sud";
/** The engine's own default; the test game otherwise starts dark. */
const NATIVE_DEFAULT_THEME = "system";
/** The file an `import` step's text is read from. */
const IMPORT_NAME = "puzzle.txt";
/** Bytes of a file that is no saved game; the native run writes the same. */
const CORRUPT_TEXT = "this is not a saved game";
const CANCEL = Symbol("cancel");
const ABORT_ERROR = "AbortError";
const FAILED_REASON = "parity: the fake failed this on purpose";
const STEP_FLOW_FAILED = "flow_failed";

const CURRENT_FILE = "./current-file";
const CURRENT_FILE_EXISTS = "./current-file-exists";
const SETTINGS = "./settings.json";
const FILENAME_HEADER = "X-Sudoku-Filename";
const RESTORE_COPY_HEADER = "X-Sudoku-Restore-Copy";
const DELETE_FILE_HEADER = "X-Sudoku-Delete-File";

/** Native Paste takes its line with the command, so core issues no `paste_puzzle` step there. */
const NOT_ON_NATIVE_STEPS = new Set([stepRunner.STEP_PASTE_PUZZLE]);

const baseName = (path) => (typeof path === "string" ? path.split("/").pop() : path);

/** Drop null and undefined fields: the native transcript leaves them out. */
function compact(value) {
  if (Array.isArray(value)) return value.map(compact);
  if (value && typeof value === "object") {
    const out = {};
    for (const [k, v] of Object.entries(value)) if (v !== null && v !== undefined) out[k] = compact(v);
    return out;
  }
  return value;
}

/** One step core issued, in the native transcript's terms. */
function describeStep(step) {
  const event = { step: step.step };
  switch (step.step) {
    case stepRunner.STEP_PROMPT_MESSAGE:
      Object.assign(event, { type: step.type, title: step.title, text: step.text, buttons: step.buttons, dismiss: step.dismiss });
      break;
    case stepRunner.STEP_SAVE:
    case stepRunner.STEP_AUTOSAVE:
      Object.assign(event, { name: baseName(step.name), replace: step.replace });
      break;
    case stepRunner.STEP_SAVE_AS:
      event.replace = step.replace;
      break;
    case stepRunner.STEP_FLUSH:
    case stepRunner.STEP_EXPORT_PUZZLE:
      event.name = baseName(step.name);
      break;
    case stepRunner.STEP_SHOW_GAME:
      Object.assign(event, { status: step.text || null, file: baseName(step.file ?? null), loaded: step.loaded ? true : null });
      break;
    case stepRunner.STEP_GENERATE_GAME:
      event.difficulty = DIFFICULTY_NAMES[step.difficulty];
      break;
    case stepRunner.STEP_FORGET_CURRENT_FILE:
      event.delete = step.delete;
      break;
    case stepRunner.STEP_SHOW_STATUS:
      event.text = step.text;
      break;
    default:
      if (step.ok === false) Object.assign(event, { step: STEP_FLOW_FAILED, error: step.error });
  }
  return event;
}

/** The answer the platform gave, in the native transcript's terms. */
function describeAnswer(input) {
  switch (input.input) {
    case "default_target":
      return { name: baseName(input.name) };
    case "pressed":
      return { pressed: input.index };
    case "wrote":
      if (input.ok) return { wrote: "ok", name: baseName(input.name) };
      return { wrote: input.exists ? "exists" : input.cancelled ? "cancelled" : input.taken ? "taken" : "failed" };
    case "read":
      return { read: input.ok ? "file" : input.cancelled ? "cancelled" : "failed" };
    case "generated":
      return { generated: input.ok ? "line" : input.cancelled ? "cancelled" : "failed" };
    case "persisted":
    case "copied":
      return { outcome: input.ok ? "ok" : "failed" };
    default:
      return null;
  }
}

/** Wrap the game's flow calls so every step core issues, and the answer it gets, is recorded. */
function recordSteps(game) {
  const recorder = { events: [], recording: true };
  const issued = (step) => {
    if (recorder.recording) recorder.events.push(describeStep(step));
    return step;
  };
  const answered = (answer) => {
    if (!recorder.recording) return;
    const last = recorder.events.at(-1);
    if (last && answer) last.answer = answer;
  };
  const flowStart = game.flowStart.bind(game);
  const commandStart = game.commandStart.bind(game);
  const flowNext = game.flowNext.bind(game);
  const flowRead = game.flowRead.bind(game);
  const flowFail = game.flowFail.bind(game);
  game.flowStart = (start) => issued(flowStart(start));
  game.commandStart = (action) => issued(commandStart(action));
  game.flowNext = (input) => {
    answered(describeAnswer(input));
    return issued(flowNext(input));
  };
  game.flowRead = (bytes, name) => {
    answered({ read: "file" });
    return issued(flowRead(bytes, name));
  };
  game.flowFail = () => {
    answered({ flow_failed: true });
    return issued(flowFail());
  };
  return recorder;
}

/** Bytes of a saved game: `puzzle_line` with the player's `moves` on top. */
async function savedGame(file) {
  if (file.corrupt) return new TextEncoder().encode(CORRUPT_TEXT);
  const game = await loadGame();
  await stepRunner.runCommand(game, { action: "new", difficulty: "easy" }, {
    generateGame: async () => ({ ok: true, line: file.puzzle_line }),
    showGame() {},
    resolveDefaultTarget: () => DEFAULT_SAVE_NAME,
    autosave: async () => ({ ok: true }),
  });
  for (const m of file.moves ?? []) assert.equal(game.exec({ action: "fill", row: m.row, col: m.col, digit: m.digit }).ok, true);
  const saved = game.toSaveFormat();
  assert.equal(saved.ok, true);
  return saved.bytes;
}

const toBytes = (data) => (typeof data === "string" ? new TextEncoder().encode(data) : new Uint8Array(data));

/**
 * The player's folder, the host and the pickers one run shares. Every platform writes and reads the
 * same folder, so "the file is there" means the same thing on each.
 */
async function makeWorld(scenario) {
  const w = scenario.world ?? {};
  const world = {
    /** @type {Map<string, Uint8Array>} */
    files: new Map(),
    /** @type {Map<string, Uint8Array>} */
    restoreCopies: new Map(),
    /** Player files written, in order. */
    written: [],
    failWrites: new Set(w.fail_writes ?? []),
    failReads: new Set(w.fail_reads ?? []),
    taken: new Set(w.taken ?? []),
    generate: w.generate ?? null,
    settingsFail: w.settings_fail === true,
    settings: null,
    /** The host's current file, restored at startup. */
    current: null,
    /** What the next picker returns: a name, `CANCEL`, or null for the scenario's pick, else the name it suggests. */
    nextPick: null,
    pick: w.pick ?? null,
    clipboardText: "",
    pasteFails: false,
    copyFails: false,
    /** Android: the file the bridge holds bound; the bridge keeps it across launches and never lets go. */
    bound: null,
  };
  for (const file of scenario.files ?? []) world.files.set(file.name, await savedGame(file));
  if (scenario.current_file) {
    if (!scenario.current_file.missing) {
      world.files.set(scenario.current_file.name, await savedGame(scenario.current_file));
      world.bound = scenario.current_file.name;
    }
    world.current = scenario.current_file.name;
  }
  world.takePick = (suggested) => {
    const pick = world.nextPick ?? world.pick ?? suggested;
    world.nextPick = null;
    return pick;
  };
  world.writeFile = (name, bytes) => {
    if (world.failWrites.has(name)) return { ok: false, error: FAILED_REASON };
    world.files.set(name, bytes);
    world.written.push(name);
    return { ok: true, name };
  };
  world.fetchFn = async (url, init = {}) => {
    const headers = init.headers ?? {};
    const name = headers[FILENAME_HEADER];
    if (url === CURRENT_FILE_EXISTS) return { ok: true, json: async () => ({ exists: world.files.has(name) }) };
    if (url === CURRENT_FILE && init.method === "POST") {
      const bytes = toBytes(init.body);
      if (headers[RESTORE_COPY_HEADER] === "true") {
        world.restoreCopies.set(name, bytes);
        return { ok: true, status: 204 };
      }
      return world.writeFile(name, bytes).ok ? { ok: true, status: 204 } : { ok: false, status: 500 };
    }
    if (url === CURRENT_FILE && init.method === "DELETE") {
      if (headers[DELETE_FILE_HEADER] === "true") world.files.delete(world.current);
      world.current = null;
      return { ok: true, status: 204 };
    }
    if (url === CURRENT_FILE) {
      const bytes = world.restoreCopies.get(world.current) ?? world.files.get(world.current);
      if (!bytes) return { ok: false, status: 404 };
      return { ok: true, arrayBuffer: async () => bytes.slice().buffer };
    }
    if (url === SETTINGS && init.method === "POST") {
      if (world.settingsFail) return { ok: false, status: 500 };
      world.settings = JSON.parse(init.body);
      return { ok: true, status: 204 };
    }
    throw new Error(`unexpected host request: ${init.method ?? "GET"} ${url}`);
  };
  return world;
}

const abort = () => Object.assign(new Error("picker closed"), { name: ABORT_ERROR });

/** A browser file handle onto the world's folder. */
function fileHandle(world, name) {
  return {
    kind: "file",
    name,
    createWritable: async () => {
      if (world.failWrites.has(name)) throw new Error(FAILED_REASON);
      let data = new Uint8Array();
      return {
        write: async (bytes) => {
          data = toBytes(bytes);
        },
        close: async () => {
          world.writeFile(name, data);
        },
      };
    },
    getFile: async () => {
      if (world.failReads.has(name)) throw new Error(FAILED_REASON);
      const bytes = world.files.get(name);
      return { name, arrayBuffer: async () => bytes.slice().buffer };
    },
  };
}

/** The browser window the web steps use: file pickers onto the world's folder, and page hide for the flush. */
function browserWindow(world) {
  const listeners = {};
  const win = {
    showSaveFilePicker: async ({ suggestedName } = {}) => {
      const pick = world.takePick(suggestedName);
      if (pick === CANCEL) throw abort();
      return fileHandle(world, pick);
    },
    showOpenFilePicker: async () => {
      const pick = world.takePick(null);
      if (pick === CANCEL) throw abort();
      return [fileHandle(world, pick)];
    },
    addEventListener(type, fn) {
      listeners[type] = fn;
    },
    removeEventListener() {},
    dispatch(type) {
      listeners[type]?.();
    },
  };
  return win;
}

/** The Java file bridge's behaviour (`MainActivity.AndroidFileBridge`) over the world's folder. */
function androidBridge(world) {
  const base64 = (b64) => Uint8Array.from(Buffer.from(b64, "base64"));
  const write = (name, b64, { bind }) => {
    if (world.taken.has(name)) return { ok: false, reason: "taken", name };
    const out = world.writeFile(name, base64(b64));
    if (out.ok && bind) world.bound = name;
    return out;
  };
  const createPicked = (b64, suggested, { bind }) => {
    const pick = world.takePick(suggested);
    if (pick === CANCEL) return { ok: false, cancelled: true };
    return write(pick, b64, { bind });
  };
  const readPicked = ({ bind }) => {
    const pick = world.takePick(null);
    if (pick === CANCEL) return { ok: false, cancelled: true };
    if (world.failReads.has(pick)) return { ok: false, error: FAILED_REASON };
    if (bind) world.bound = pick;
    return { ok: true, base64: Buffer.from(world.files.get(pick)).toString("base64"), name: pick };
  };
  return {
    currentSudokuFileName: () => world.bound ?? "",
    save: (b64, name) => (world.bound ? write(world.bound, b64, { bind: true }) : createPicked(b64, name, { bind: true })),
    saveAs: (b64, name) => createPicked(b64, name, { bind: true }),
    autosave: (b64, name) => {
      if (world.bound) return write(world.bound, b64, { bind: true });
      if (world.taken.has(name)) return { ok: false, reason: "taken", name };
      return write(name, b64, { bind: true });
    },
    defaultFileExists: (name) => world.files.has(name) && !world.taken.has(name),
    reclaimFile: (b64) => {
      const pick = world.takePick([...world.taken][0]);
      if (pick === CANCEL) return { ok: false, cancelled: true };
      world.taken.delete(pick);
      return write(pick, b64, { bind: true });
    },
    exportPuzzle: (b64, name) => createPicked(b64, name, { bind: false }),
    open: () => readPicked({ bind: true }),
    importPuzzle: () => readPicked({ bind: false }),
  };
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
    async change() {
      await this.handlers.change?.();
    },
  };
}

const makeMenuItem = () => ({
  ...makeBtn(),
  setAttribute() {},
  classList: { toggle() {}, add() {}, remove() {}, contains: () => false },
});

const themeRoot = () => ({
  documentElement: { dataset: {} },
  defaultView: { matchMedia: () => ({ matches: false, addEventListener() {} }) },
});

const makeBoard = () => ({ children: [], replaceChildren(...nodes) { this.children = nodes; } });
const createElement = (tag) => ({
  tag,
  classList: { add() {}, remove() {} },
  style: {},
  textContent: "",
  dataset: {},
  setAttribute() {},
  select() {},
});

/** A generating dialog the player continues as soon as the puzzle is ready. */
function autoContinueModal() {
  return { ...generatingModalStub(), waitForContinue: async () => {} };
}

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
 * One launch of the shell on `platform`: a fresh game and session, the startup flow, and the menus
 * wired to that platform's step handlers. A relaunch calls this again on the same world.
 */
async function launch(platform, cfg, world, ui) {
  const game = await loadGame(cfg);
  game.generatePuzzle = ({ difficulty }) => {
    if (world.generate === "cancelled") return { ok: false, error: "cancelled" };
    if (world.generate === "failed") return { ok: false, error: FAILED_REASON };
    return { ok: true, line: NATIVE.generated_lines[DIFFICULTY_NAMES[difficulty]] };
  };
  const recorder = recordSteps(game);
  const boot = {
    state: game.getState(),
    legend: game.getLegend(),
    config: game.getConfig(),
    default_save_filename: world.current ?? DEFAULT_SAVE_NAME,
    startup_save_path: world.current ? CURRENT_FILE : null,
  };
  const session = sessionMod.createWebSessionFromStartup(boot);
  const win = browserWindow(world);
  const doc = {
    defaultView: win,
    createElement,
    body: { appendChild() {}, removeChild() {} },
    execCommand: () => !world.copyFails,
  };
  const clipboard = {
    readText: async () => {
      if (world.pasteFails) throw new Error(FAILED_REASON);
      return world.clipboardText;
    },
    writeText: async () => {
      if (world.copyFails) throw new Error(FAILED_REASON);
    },
  };
  const options = {
    fetchFn: world.fetchFn,
    statusEl: ui.statusEl,
    promptDialog: ui.promptDialog,
    generatingModal: autoContinueModal(),
    win,
    doc,
    clipboard,
  };
  const steps = platform === WEB ? webSteps.webSteps(game, session, options) : androidSteps.androidSteps(game, session, androidBridge(world), options);
  await startupMod.runStartupFlow(game, boot, steps);

  const controls = {
    new: makeBtn(),
    open: makeBtn(),
    import: makeBtn(),
    save: makeBtn(),
    saveAs: makeBtn(),
    export: makeBtn(),
    autoSave: makeBtn(),
    viewRegion: makeMenuItem(),
    viewLight: makeMenuItem(),
    viewDark: makeMenuItem(),
    viewSystem: makeMenuItem(),
  };
  const difficultyButtons = Object.keys(DIFFICULTY_WIRE).map((difficulty) => ({ el: makeBtn(), difficulty }));
  region.wireRegionMenu(controls, game, session, ui.boardEl, () => null, { steps });
  themeMod.wireThemeMenu(controls, game, session, { root: themeRoot(), steps });
  fileMenu.wireFileMenu(controls, game, ui.boardEl, { select() {}, deselect() {} }, ui.statusEl, session, { sync() {} }, {
    createElement,
    difficultyDialog: { el: { hidden: true }, buttons: difficultyButtons },
    steps,
  });
  const modal = {
    el: { hidden: true },
    checkbox: makeBtn(),
    difficultySelect: { ...makeBtn(), value: "" },
    logLevelSelect: { ...makeBtn(), value: "" },
    autoRestoreCheckbox: makeBtn(),
    autoNewCheckbox: makeBtn(),
    autoSaveCheckbox: makeBtn(),
    dismissEl: makeBtn(),
  };
  const settingsBtn = makeBtn();
  settingsMenu.wireSettingsMenu(settingsBtn, game, session, modal, { steps });
  autosave.wireFlushOnClose(game, steps, { win });
  return { platform, game, session, steps, controls, difficultyButtons, modal, settingsBtn, win, recorder };
}

/** Carry out one scenario step through the shell's own entry points. */
async function runStep(run, world, ui, step) {
  const { game, session, steps, controls, modal, settingsBtn } = run;
  const edit = (action, selected = null) =>
    menu.handleEditAction(action, game, ui.boardEl, { getSelection: () => selected, select() {}, deselect() {} }, session, createElement, { steps }).done;
  const setting = async (el, value) => {
    await settingsBtn.click();
    if (value !== undefined) el.value = value;
    await el.change();
  };
  if (step.undo) return edit("undo");
  if (step.redo) return edit("redo");
  if (step.hint) return edit("hint");
  if (step.hint_at) return edit("hint", step.hint_at);
  if (step.solve) return edit("solve");
  if (step.paste !== undefined) {
    world.clipboardText = step.paste;
    return menu.handlePastePuzzle(game, session, steps).done;
  }
  if (step.paste_fails) {
    world.pasteFails = true;
    return menu.handlePastePuzzle(game, session, steps).done;
  }
  if (step.copy || step.copy_fails) {
    world.copyFails = step.copy_fails === true;
    return menu.handleCopyPuzzle(game, session, steps);
  }
  if (step.open) {
    world.files.set(step.open.name, await savedGame(step.open));
    world.nextPick = step.open.name;
    return controls.open.click();
  }
  if (step.open_cancel) {
    world.nextPick = CANCEL;
    return controls.open.click();
  }
  if (step.import !== undefined) {
    world.files.set(IMPORT_NAME, new TextEncoder().encode(step.import));
    world.nextPick = IMPORT_NAME;
    return controls.import.click();
  }
  if (step.import_cancel) {
    world.nextPick = CANCEL;
    return controls.import.click();
  }
  if (step.save) return controls.save.click();
  if (step.save_as !== undefined || step.save_as_cancel) {
    world.nextPick = step.save_as_cancel ? CANCEL : step.save_as;
    return controls.saveAs.click();
  }
  if (step.new) {
    await controls.new.click();
    return run.difficultyButtons.find((b) => b.difficulty === step.new).el.click();
  }
  if (step.export) return controls.export.click();
  if (step.export_cancel) {
    world.nextPick = CANCEL;
    return controls.export.click();
  }
  if (step.toggle_auto_save) return controls.autoSave.click();
  if (step.toggle_region) {
    controls.viewRegion.click();
    return settleFlow();
  }
  if (step.set_theme) {
    ({ light: controls.viewLight, dark: controls.viewDark, system: controls.viewSystem })[step.set_theme].click();
    return settleFlow();
  }
  if (step.toggle_warn_solvability) return setting(modal.checkbox);
  if (step.set_difficulty) return setting(modal.difficultySelect, step.set_difficulty);
  if (step.set_log_level) return setting(modal.logLevelSelect, step.set_log_level);
  if (step.toggle_auto_restore) return setting(modal.autoRestoreCheckbox);
  if (step.toggle_auto_new) return setting(modal.autoNewCheckbox);
  if (step.close) {
    if (run.platform === WEB) run.win.dispatch("pagehide");
    else run.win[autosave.FLUSH_ON_CLOSE_HOOK]();
    return settleFlow();
  }
  const move = step.fill ?? step.clear ?? (step.fill_first_empty ? firstEmptyLegalFill(game.getState()) : null);
  if (!move) throw new Error(`step not carried out on ${run.platform}: ${JSON.stringify(step)}`);
  const selection = { getSelection: () => ({ row: move.row, col: move.col }), select() {} };
  const key = step.clear ? "Delete" : String(move.digit);
  const outcome = board.handlePlayKey(game, ui.boardEl, selection, key, createElement, "", { steps });
  assert.equal(outcome.handled, true);
  return outcome.done;
}

/** The game once the steps are done, in the native transcript's terms. */
function finalState(run, ui) {
  const { game, session } = run;
  const line = game.toPuzzle();
  assert.equal(line.ok, true);
  const legend = game.getLegend();
  const config = game.getConfig();
  return compact({
    cells: new TextDecoder().decode(line.bytes),
    givens: game.getState().cells.map((c) => (c.given ? "1" : "0")).join(""),
    undo: legend.undo,
    redo: legend.redo,
    file: baseName(session.boundFilename),
    status: ui.statusEl.textContent || null,
    config: {
      difficulty: DIFFICULTY_NAMES[config.difficulty],
      log_level: LOG_LEVEL_NAMES[config.log_level],
      theme: config.theme,
      show_region: config.show_region,
      warn_solvability: config.warn_solvability,
      auto_restore: config.auto_restore,
      auto_new: config.auto_new,
      auto_save: config.auto_save,
    },
  });
}

/** The scenario's own expectations, checked as the native run checks them. */
function checkExpect(expect, events, world, run) {
  const prompts = events.filter((e) => e.step === stepRunner.STEP_PROMPT_MESSAGE);
  if (expect.questions !== undefined) assert.equal(prompts.filter((p) => p.buttons.length > 1).length, expect.questions, "questions asked");
  if (expect.errors !== undefined) assert.equal(prompts.filter((p) => p.buttons.length === 1).length, expect.errors, "errors shown");
  if (expect.written) assert.deepEqual(world.written, expect.written, "files written");
  for (const [key, want] of Object.entries(expect.settings ?? {})) assert.equal(world.settings?.[key], want, `stored ${key}`);
  const legend = run.game.getLegend();
  if (expect.legend?.undo !== undefined) assert.equal(legend.undo, expect.legend.undo, "legend undo");
  if (expect.legend?.redo !== undefined) assert.equal(legend.redo, expect.legend.redo, "legend redo");
  const cells = run.game.getState().cells;
  for (const p of expect.probes ?? []) {
    const c = cells[p.row * 9 + p.col];
    assert.equal(c.value, p.value, `probe ${p.row},${p.col} value`);
    assert.equal(c.given, p.given, `probe ${p.row},${p.col} given`);
  }
}

const isSolved = (state) => state.cells.every((c) => c.value !== 0 && !c.conflict);

/** Run `scenario` on `platform`; returns its transcript. */
async function runScenario(scenario, platform) {
  const cfg = { theme: NATIVE_DEFAULT_THEME, ...scenario.config };
  if (typeof cfg.difficulty === "string") cfg.difficulty = DIFFICULTY_WIRE[cfg.difficulty];
  const world = await makeWorld(scenario);
  const answers = [...(scenario.answers ?? [])];
  const ui = {
    statusEl: { textContent: "", className: "" },
    promptDialog: {
      show: async (step) => {
        if (step.buttons.length === 1) return step.default;
        return (answers.shift() ?? true) ? step.default : (step.dismiss ?? 0);
      },
      dismiss() {},
    },
    boardEl: makeBoard(),
  };
  const prevFetch = globalThis.fetch;
  globalThis.fetch = world.fetchFn;
  try {
    let run = await launch(platform, cfg, world, ui);
    const events = run.recorder.events;
    if (scenario.expect?.solved_after_startup !== undefined) {
      assert.equal(isSolved(run.game.getState()), scenario.expect.solved_after_startup, "solved after startup");
    }
    if (scenario.puzzle_line) {
      run.recorder.recording = false;
      const generatePuzzle = run.game.generatePuzzle;
      run.game.generatePuzzle = () => ({ ok: true, line: scenario.puzzle_line });
      await stepRunner.runCommand(run.game, { action: "new", difficulty: "easy" }, run.steps);
      run.game.generatePuzzle = generatePuzzle;
      run.recorder.recording = true;
      world.written.length = 0;
    }
    for (const step of scenario.steps ?? []) {
      if (step.relaunch) {
        assert.ok(world.written.length > 0, "relaunch needs a written file");
        world.current = world.written.at(-1);
        run = await launch(platform, run.game.getConfig(), world, ui);
        events.push(...run.recorder.events);
        run.recorder.events = events;
        continue;
      }
      await runStep(run, world, ui, step);
    }
    checkExpect(scenario.expect ?? {}, events, world, run);
    return { name: scenario.name, events: compact(events), final: finalState(run, ui) };
  } finally {
    globalThis.fetch = prevFetch;
  }
}

const runsOn = (scenario, entry) => !scenario.not_on?.[entry] && scenario.skip?.entry !== entry;

/** Step kinds each front end received, and the prompt types any of them showed. */
const kindsSeen = { [NATIVE_ENTRY]: new Set(), [WEB]: new Set(), [ANDROID]: new Set() };
const promptTypesSeen = new Set();
const noteKinds = (entry, transcript) => {
  for (const e of transcript.events) {
    kindsSeen[entry].add(e.step);
    if (e.type) promptTypesSeen.add(e.type);
  }
};
NATIVE.scenarios.forEach((t) => noteKinds(NATIVE_ENTRY, t));

/** Where a transcript first departs from the reference: an event index, else the end state. */
function firstDifference(got, reference) {
  const at = got.events.findIndex((e, i) => JSON.stringify(e) !== JSON.stringify(reference.events[i]));
  if (at >= 0) return { event: at, got: got.events[at], want: reference.events[at] };
  if (got.events.length !== reference.events.length) {
    const n = Math.min(got.events.length, reference.events.length);
    return { event: n, got: got.events[n] ?? null, want: reference.events[n] ?? null };
  }
  const fields = Object.keys({ ...got.final, ...reference.final }).filter(
    (k) => JSON.stringify(got.final[k]) !== JSON.stringify(reference.final[k]),
  );
  return { final: Object.fromEntries(fields.map((k) => [k, { got: got.final[k], want: reference.final[k] }])) };
}

/** The terminal types Save As's file with the command, so core asks it for no default target first. */
const pickerTargetBeforeSaveAs = (events, i) =>
  events[i].step === stepRunner.STEP_RESOLVE_DEFAULT_TARGET && events[i + 1]?.step === stepRunner.STEP_SAVE_AS;
const withoutNativeOnlyGaps = (t) => ({
  ...t,
  events: t.events.filter((e, i, all) => !NOT_ON_NATIVE_STEPS.has(e.step) && !pickerTargetBeforeSaveAs(all, i)),
});
const failures = [];

assert.ok(SCENARIOS.scenarios.length > 0);
for (const scenario of SCENARIOS.scenarios) {
  for (const [entry, reason] of Object.entries(scenario.not_on ?? {})) {
    assert.ok([NATIVE_ENTRY, WEB, ANDROID].includes(entry), `${scenario.name}: not_on names unknown front end ${entry}`);
    assert.ok(typeof reason === "string" && reason.length > 0, `${scenario.name}: not_on ${entry} gives no reason`);
  }
  const native = runsOn(scenario, NATIVE_ENTRY) ? NATIVE_BY_NAME.get(scenario.name) : null;
  if (runsOn(scenario, NATIVE_ENTRY)) assert.ok(native, `${scenario.name}: no native transcript; rerun the native tests`);
  const ran = {};
  for (const platform of PLATFORMS) {
    if (!runsOn(scenario, platform)) continue;
    try {
      ran[platform] = await runScenario(scenario, platform);
      noteKinds(platform, ran[platform]);
    } catch (err) {
      failures.push(`${scenario.name} on ${platform}: ${err.message}`);
    }
  }
  const label = native ? NATIVE_ENTRY : WEB;
  const reference = native ?? ran[WEB];
  for (const [platform, transcript] of Object.entries(ran)) {
    if (!reference || reference === transcript) continue;
    const got = native ? withoutNativeOnlyGaps(transcript) : transcript;
    if (JSON.stringify(got) === JSON.stringify(reference)) continue;
    failures.push(`${scenario.name} on ${platform} differs from ${label}: ${JSON.stringify(firstDifference(got, reference))}`);
  }
}
assert.deepEqual(failures, [], `parity: ${failures.length} front-end differences:\n${failures.join("\n")}`);

for (const entry of [NATIVE_ENTRY, ...PLATFORMS]) {
  const notReceived = SCENARIOS.steps_not_received?.[entry] ?? {};
  for (const kind of NATIVE.step_kinds) {
    const reason = notReceived[kind];
    if (reason === undefined) assert.ok(kindsSeen[entry].has(kind), `parity: no scenario issues the ${kind} step on ${entry}`);
    else {
      assert.ok(typeof reason === "string" && reason.length > 0, `parity: steps_not_received ${entry}.${kind} gives no reason`);
      assert.ok(!kindsSeen[entry].has(kind), `parity: ${entry} receives ${kind}, which steps_not_received says it never does`);
    }
  }
}
for (const type of PROMPT_TYPES) assert.ok(promptTypesSeen.has(type), `parity: no scenario shows a ${type} prompt`);
