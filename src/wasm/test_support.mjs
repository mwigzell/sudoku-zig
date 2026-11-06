// test_support.mjs — node test helpers: real wasm games, the core flow for fake games, and stubs shared by test files.

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import * as glue from "./artifacts/glue.js";
import * as webSteps from "./flows/web_steps.js";
import * as generating from "./dialogs/generating.js";
import * as stepRunner from "./flows/step_runner.js";

const here = dirname(fileURLToPath(import.meta.url));
const wasmBytes = readFileSync(join(here, "artifacts/artifact.wasm"));

const textGame = await glue.loadArtifact(wasmBytes);
/** Core's generating dialog text, read from the real artifact. */
export const genText = textGame.getGenText();
/** Core's dialog and status text by constant name, read from the real artifact. */
export const coreText = textGame.getCoreText();

/** Fill a core `*_FMT` text's `{s}`/`{c}`/`{d}` placeholders in order. */
export function fillText(fmt, ...args) {
  let i = 0;
  return fmt.replace(/\{[scd]\}/g, () => String(args[i++]));
}

/** A real wasm game bootstrapped like the host does; `config` overrides the defaults. */
export async function loadGame(config = {}) {
  const game = await glue.loadArtifact(wasmBytes);
  const boot = game.bootstrapHostConfig({
    difficulty: 1,
    logLevel: 1,
    theme: "dark",
    show_region: false,
    warn_solvability: false,
    auto_restore: false,
    auto_new: false,
    auto_save: false,
    show_marks: true,
    ...config,
  });
  if (!boot.ok) throw new Error(`game bootstrap failed: ${boot.error}`);
  return game;
}

/** Fresh wasm instance bootstrapped with `autoSave`, for flow exports only. */
export function loadCoreFlow({ autoSave = false } = {}) {
  return loadGame({ auto_save: autoSave });
}

/**
 * Attach real `flowStart` / `flowNext` to a fake game once; returns the game.
 * `opened` opens a file under that name in the core first; `newGame` starts a New game there.
 */
export async function withCoreFlow(game, { opened = null, newGame = false, ...options } = {}) {
  if (typeof game.flowStart === "function") return game;
  const core = await loadCoreFlow(options);
  if (opened) openAs(core, opened);
  if (newGame) startNewGame(core);
  game.flowStart = (start) => core.flowStart(start);
  game.commandStart = (action) => core.commandStart(action);
  game.flowNext = (input) => core.flowNext(input);
  game.flowFail = (reason) => core.flowFail(reason);
  return game;
}

/** A valid one-line puzzle for loads in tests. */
export const PUZZLE_LINE = "530070000600195000098000060800060003400803001700020006060000280000419005000080079";

/**
 * Run a load command on a real wasm game, answering its gather step with `answer(step)`.
 * An autosave the load triggers is answered as a write onto a new file that worked.
 */
function loadNow(game, action, answer) {
  let step = answer(game.commandStart(action));
  let shown = null;
  while (step.step !== "done" && step.step !== "show_status" && step.step !== "prompt_message") {
    if (step.step === "show_game") shown = step;
    const input = {
      show_game: { input: "ack" },
      resolve_default_target: { input: "default_target", name: "sudoku.sud" },
      autosave: { input: "wrote", ok: true, name: step.name },
    }[step.step];
    if (!input) break;
    step = game.flowNext(input);
  }
  if (step.step !== "done") throw new Error(`${action.action} ended with ${JSON.stringify(step)}`);
  return shown;
}

/** Start a New game from `line` on a real wasm game, as File -> New does once generation finishes. */
export function startNewGame(game, line = PUZZLE_LINE, difficulty = "easy") {
  return loadNow(game, { action: "new", difficulty }, () => game.flowNext({ input: "generated", ok: true, line }));
}

/** Open saved-game `bytes` picked as `name` on a real wasm game; returns the `show_game` step. */
export function openBytes(game, bytes, name = null) {
  return loadNow(game, { action: "open" }, () => game.flowRead(bytes, name));
}

/** Open the game's own bytes under `name` on a real wasm game, as File -> Open does. */
export function openAs(game, name) {
  const saved = game.toSaveFormat();
  if (!saved.ok) throw new Error(`toSaveFormat failed: ${saved.error}`);
  return openBytes(game, saved.bytes, name);
}

/** Fetch fake answering `/current-file-exists` with `exists` and recording every call. */
export function hostFetch({ exists = false, calls = [] } = {}) {
  const fetchFn = async (url, init = {}) => {
    calls.push({ url, init });
    if (url === "./current-file-exists") return { ok: true, status: 200, json: async () => ({ exists }) };
    return { ok: true, status: 204, json: async () => ({}) };
  };
  return { fetchFn, calls };
}

/** The host write in recorded fetch calls, if any. */
export function postedCurrentFile(calls) {
  return calls.find((call) => call.url === "./current-file");
}

/** Let a flow started without `await` run its async steps to the end. */
export async function settleFlow() {
  for (let i = 0; i < 8; i += 1) await new Promise((resolve) => setTimeout(resolve, 0));
}

/** Generating dialog wired to stub elements; `progressRowsEl` turns on the progress rows. */
export function generatingModalStub({ progressRowsEl } = {}) {
  const el = { hidden: true };
  const continueBtn = makeContinueBtn();
  const cancelBtn = makeContinueBtn();
  return generating.wireGeneratingModal({
    genText,
    el,
    continueBtn,
    cancelBtn,
    spinnerEl: { hidden: true },
    msgEl: { textContent: "" },
    progressRowsEl,
    createElement: progressRowsEl ? () => makeRowEl() : undefined,
  });
}

/** Wait until the dialog has painted (two animation frames, or one macrotask under node). */
export async function flushDialogPaint() {
  if (typeof requestAnimationFrame === "function") {
    await new Promise((resolve) => {
      requestAnimationFrame(() => requestAnimationFrame(resolve));
    });
    return;
  }
  await new Promise((resolve) => setImmediate(resolve));
}

export const FILL_MOVE = { action: "fill", row: 0, col: 2, digit: 4 };

/**
 * Prompt dialog stub: records each prompt core shows and answers with `answer` (dismiss, else the default).
 * @param {(step: import("./types").PromptStep) => number} [answer]
 */
export function promptDialogStub(answer = (step) => step.dismiss ?? step.default) {
  /** @type {import("./types").PromptStep[]} */
  const shown = [];
  return {
    shown,
    show: async (step) => {
      shown.push(step);
      return answer(step);
    },
    dismiss() {},
    get lastText() {
      return shown.at(-1)?.text ?? null;
    },
  };
}

/** A prompt dialog that fails the test if core asks anything. */
export function noPromptDialog(why) {
  return promptDialogStub(() => assert.fail(why));
}

/**
 * One move through the core command flow with `steps` (the browser's by default); core decides what is written.
 * @param {import("./types").StepsOptions & { steps?: import("./types").FlowHandlers }} [options]
 */
export function moveWithAutosave(game, session, { steps, ...options } = {}, move = FILL_MOVE) {
  const handlers = steps ?? webSteps.webSteps(game, session, options);
  return stepRunner.runCommand(game, move, { ...handlers, showGame() {} });
}

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
