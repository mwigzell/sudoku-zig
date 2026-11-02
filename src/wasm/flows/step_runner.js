// step_runner.js — carries out core flow steps on the web: core (wasm) decides
// what happens next; handlers only do the platform work and report back.

import * as clientLog from "../client_log.js";

/** @typedef {import("../types").GameApi} GameApi */
/** @typedef {import("../types").FlowStart} FlowStart */
/** @typedef {import("../types").FlowStep} FlowStep */
/** @typedef {import("../types").FlowHandlers} FlowHandlers */
/** @typedef {import("../types").FlowOutcome} FlowOutcome */
/** @typedef {import("../types").ExecAction} ExecAction */

export const STEP_RESOLVE_DEFAULT_TARGET = "resolve_default_target";
export const STEP_CHECK_TARGET = "check_target";
export const STEP_ASK = "ask";
export const STEP_WRITE = "write";
export const STEP_READ_FILE = "read_file";
export const STEP_PICK_OPEN = "pick_open";
export const STEP_READ_CLIPBOARD = "read_clipboard";
export const STEP_SHOW_GAME = "show_game";
export const STEP_GENERATE = "generate";
export const STEP_FORGET_CURRENT_FILE = "forget_current_file";
export const STEP_PERSIST_SETTINGS = "persist_settings";
export const STEP_PICK_EXISTING = "pick_existing";
export const STEP_PICK_NEW = "pick_new";
export const STEP_COPY_LINE = "copy_line";
export const STEP_SHOW_STATUS = "show_status";
export const STEP_SHOW_ERROR = "show_error";
export const STEP_DONE = "done";

/** `write` / `check_target` kinds: what core writes and why. */
export const WRITE_SAVE = "save";
export const WRITE_SAVE_AS = "save_as";
export const WRITE_AUTO_SAVE = "auto_save";
export const WRITE_EXPORT_LINE = "export_line";

export const FLOW_AUTOSAVE_FLUSH = "autosave_flush";
export const FLOW_STARTUP = "startup";

/** Input names core's `flowNext` reads (`boundary.zig` `parseFlowInput`). */
const INPUT_DEFAULT_TARGET = "default_target";
const INPUT_TARGET_CHECKED = "target_checked";
const INPUT_ANSWERED = "answered";
const INPUT_WROTE = "wrote";
const INPUT_GENERATED = "generated";
const INPUT_PERSISTED = "persisted";
const INPUT_COPIED = "copied";
const INPUT_FILE_READ = "file_read";
const INPUT_PICKED = "picked";
const INPUT_ACK = "ack";

const FLOW_LANE = Symbol("flowLane");
const UNKNOWN_STEP_PREFIX = "unknown flow step: ";
/** Logged when a handler reports failure without saying why; core words what the user sees. */
const NO_REASON = "no reason given";

/**
 * A failed `input` for core; the reason is logged here because core cannot log on wasm.
 * @param {string} input
 * @param {{ error?: string }} [result]
 */
function failedInput(input, result) {
  const error = result?.error ?? NO_REASON;
  clientLog.clientLog("flow", "info", "step_failed", { input, error });
  return { input, ok: false, error };
}

/**
 * Normalize a handler's write outcome to the wasm `wrote` input.
 * @param {import("../types").WriteResult} result
 * @param {string | null} name the target core named, reported when the platform names none
 */
function wroteInput(result, name) {
  if (result?.ok === true) return { input: INPUT_WROTE, ok: true, name: result.name ?? name };
  if (result?.cancelled === true) return { input: INPUT_WROTE, ok: false, cancelled: true };
  if (result?.taken) return { input: INPUT_WROTE, ok: false, taken: true, name: result.taken.name, dir: result.taken.dir };
  return failedInput(INPUT_WROTE, result);
}

/**
 * Normalize a handler's generate outcome to the wasm `generated` input.
 * @param {{ ok?: boolean, line?: string, cancelled?: boolean, error?: string }} result
 */
function generatedInput(result) {
  if (result?.ok === true && typeof result.line === "string") return { input: INPUT_GENERATED, ok: true, line: result.line };
  if (result?.cancelled === true) return { input: INPUT_GENERATED, ok: false, cancelled: true };
  return failedInput(INPUT_GENERATED, result);
}

/**
 * Normalize a handler's settings write outcome to the wasm `persisted` input.
 * @param {{ ok?: boolean, error?: string }} result
 */
function persistedInput(result) {
  return outcomeInput(INPUT_PERSISTED, result);
}

/**
 * Normalize an ok-or-error outcome to the wasm `input` named `input`.
 * @param {string} input
 * @param {{ ok?: boolean, error?: string }} result
 */
function outcomeInput(input, result) {
  if (result?.ok === true) return { input, ok: true };
  return failedInput(input, result);
}

/**
 * The file a `check_target` or `write` step names, and the write it is for.
 * @param {{ name: string, kind: import("../types").WriteKind }} step
 * @returns {import("../types").FlowTarget}
 */
function targetOf(step) {
  return { name: step.name, kind: step.kind };
}

/**
 * Run a handler, turning a throw into a failed result.
 * @template T
 * @param {() => T | Promise<T>} fn
 * @returns {Promise<T | { ok: false, error: string }>}
 */
async function settle(fn) {
  try {
    return await fn();
  } catch (err) {
    return { ok: false, error: err?.message ?? String(err) };
  }
}

/**
 * Run one flow to its end. Flows on the same game run one at a time (wasm holds one flow).
 * @param {GameApi} game
 * @param {FlowStart} start
 * @param {FlowHandlers} handlers
 * @returns {Promise<FlowOutcome>}
 */
export function runFlow(game, start, handlers) {
  return enqueueFlow(game, () => game.flowStart(start), handlers);
}

/**
 * Run one player command end to end: core applies it, then drives every follow-up as steps.
 * @param {GameApi} game
 * @param {ExecAction} action
 * @param {FlowHandlers} handlers
 * @returns {Promise<FlowOutcome>}
 */
export function runCommand(game, action, handlers) {
  return enqueueFlow(game, () => game.commandStart(action), handlers);
}

/**
 * @param {GameApi} game
 * @param {() => FlowStep} begin
 * @param {FlowHandlers} handlers
 * @returns {Promise<FlowOutcome>}
 */
function enqueueFlow(game, begin, handlers) {
  const previous = game[FLOW_LANE] ?? Promise.resolve();
  const run = previous.catch(() => {}).then(() => driveFlow(begin, game, handlers));
  game[FLOW_LANE] = run;
  return run;
}

/**
 * @param {() => FlowStep} begin
 * @param {GameApi} game
 * @param {FlowHandlers} handlers
 * @returns {Promise<FlowOutcome>}
 */
async function driveFlow(begin, game, handlers) {
  try {
    return await stepThrough(game, begin(), handlers);
  } catch (err) {
    return failFlow(game, handlers, err?.message ?? String(err));
  }
}

/**
 * The web side could not carry the flow on: log why, and let core end it with its own sentence.
 * @returns {Promise<FlowOutcome>}
 */
function failFlow(game, handlers, reason) {
  clientLog.clientLog("flow", "err", "flow_failed", { error: reason });
  return stepThrough(game, game.flowFail(), handlers);
}

/**
 * @param {GameApi} game
 * @param {FlowStep} first
 * @param {FlowHandlers} handlers
 * @returns {Promise<FlowOutcome>}
 */
async function stepThrough(game, first, handlers) {
  let step = first;
  while (true) {
    if (step?.ok === false) return failFlow(game, handlers, step.error ?? NO_REASON);
    switch (step.step) {
      case STEP_RESOLVE_DEFAULT_TARGET:
        step = game.flowNext({ input: INPUT_DEFAULT_TARGET, name: await handlers.resolveDefaultTarget() });
        break;
      case STEP_CHECK_TARGET:
        step = game.flowNext({ input: INPUT_TARGET_CHECKED, exists: (await handlers.checkTarget(targetOf(step))) === true });
        break;
      case STEP_ASK:
        step = game.flowNext({ input: INPUT_ANSWERED, yes: (await handlers.ask(step)) === true });
        break;
      case STEP_WRITE: {
        const target = targetOf(step);
        step = game.flowNext(wroteInput(await settle(() => handlers.write(target)), target.name));
        break;
      }
      case STEP_PICK_EXISTING:
        step = game.flowNext(wroteInput(await settle(() => handlers.pickExisting()), null));
        break;
      case STEP_PICK_NEW: {
        const name = step.name;
        step = game.flowNext(wroteInput(await settle(() => handlers.pickNew(name)), name));
        break;
      }
      case STEP_COPY_LINE:
        step = game.flowNext(outcomeInput(INPUT_COPIED, await settle(() => handlers.copyLine())));
        break;
      case STEP_READ_FILE: {
        const path = step.path;
        const read = await settle(() => handlers.readFile(path));
        step = read?.ok === true
          ? game.flowFileRead(read.bytes)
          : game.flowNext(failedInput(INPUT_FILE_READ, read));
        break;
      }
      case STEP_PICK_OPEN: {
        const picked = await settle(() => handlers.pickOpen(step));
        if (picked?.ok === true) step = game.flowPicked(picked.bytes, picked.name ?? null);
        else if (picked?.cancelled === true) step = game.flowNext({ input: INPUT_PICKED, ok: false, cancelled: true });
        else step = game.flowNext(failedInput(INPUT_PICKED, picked));
        break;
      }
      case STEP_READ_CLIPBOARD: {
        const read = await settle(() => handlers.readClipboard());
        step = read?.ok === true
          ? game.flowFileRead(new TextEncoder().encode(read.text))
          : game.flowNext(failedInput(INPUT_FILE_READ, read));
        break;
      }
      case STEP_SHOW_GAME:
        await handlers.showGame(step);
        step = game.flowNext({ input: INPUT_ACK });
        break;
      case STEP_GENERATE: {
        const difficulty = step.difficulty;
        step = game.flowNext(generatedInput(await settle(() => handlers.generate(difficulty))));
        break;
      }
      case STEP_FORGET_CURRENT_FILE: {
        const forget = { path: step.path, delete: step.delete === true };
        await settle(() => handlers.forgetCurrentFile(forget));
        step = game.flowNext({ input: INPUT_ACK });
        break;
      }
      case STEP_PERSIST_SETTINGS: {
        const settings = step.settings;
        step = game.flowNext(persistedInput(await settle(() => handlers.persistSettings(settings))));
        break;
      }
      case STEP_SHOW_STATUS:
        handlers.showStatus?.(step.text);
        return { kind: STEP_SHOW_STATUS, text: step.text };
      case STEP_SHOW_ERROR:
        handlers.showError?.(step.text);
        return { kind: STEP_SHOW_ERROR, text: step.text };
      case STEP_DONE:
        return { kind: STEP_DONE };
      default:
        return failFlow(game, handlers, `${UNKNOWN_STEP_PREFIX}${step.step}`);
    }
  }
}

/**
 * Web two-button dialog for a core `ask` step.
 * @param {FlowStep} step
 * @param {Window & typeof globalThis} [win]
 * @returns {Promise<boolean>}
 */
export function askWithDialog(step, win = globalThis) {
  const choose = win?.__sudokuChoose;
  if (typeof choose !== "function") return Promise.resolve(false);
  return choose(step.text, { title: step.title, okLabel: step.ok_label, cancelLabel: step.cancel_label });
}
