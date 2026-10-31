// step_runner.js — carries out core flow steps on the web: core (wasm) decides
// what happens next; handlers only do the platform work and report back.

/** @typedef {import("./types").GameApi} GameApi */
/** @typedef {import("./types").FlowStart} FlowStart */
/** @typedef {import("./types").FlowStep} FlowStep */
/** @typedef {import("./types").FlowHandlers} FlowHandlers */
/** @typedef {import("./types").FlowOutcome} FlowOutcome */

export const STEP_RESOLVE_DEFAULT_TARGET = "resolve_default_target";
export const STEP_CHECK_TARGET = "check_target";
export const STEP_ASK = "ask";
export const STEP_WRITE = "write";
export const STEP_READ_FILE = "read_file";
export const STEP_SHOW_GAME = "show_game";
export const STEP_GENERATE = "generate";
export const STEP_FORGET_CURRENT_FILE = "forget_current_file";
export const STEP_SHOW_STATUS = "show_status";
export const STEP_SHOW_ERROR = "show_error";
export const STEP_DONE = "done";

export const FLOW_SAVE = "save";
export const FLOW_SAVE_AS = "save_as";
export const FLOW_AUTOSAVE = "autosave";
export const FLOW_AUTOSAVE_FLUSH = "autosave_flush";
export const FLOW_STARTUP = "startup";

const FLOW_LANE = Symbol("flowLane");
const UNKNOWN_STEP_PREFIX = "unknown flow step: ";
const FLOW_FAILED_MSG = "flow failed";
export const SAVE_FAILED_MSG = "save failed";
const READ_FAILED_MSG = "read failed";
const GENERATE_FAILED_MSG = "generation failed";

/**
 * Normalize a handler's write outcome to the wasm `wrote` input.
 * @param {{ ok?: boolean, name?: string, cancelled?: boolean, error?: string }} result
 */
function wroteInput(result, name) {
  if (result?.ok === true) return { input: "wrote", ok: true, name: result.name ?? name };
  if (result?.cancelled === true) return { input: "wrote", ok: false, cancelled: true };
  return { input: "wrote", ok: false, error: result?.error ?? SAVE_FAILED_MSG };
}

/**
 * Normalize a handler's generate outcome to the wasm `generated` input.
 * @param {{ ok?: boolean, line?: string, cancelled?: boolean, error?: string }} result
 */
function generatedInput(result) {
  if (result?.ok === true && typeof result.line === "string") return { input: "generated", ok: true, line: result.line };
  if (result?.cancelled === true) return { input: "generated", ok: false, cancelled: true };
  return { input: "generated", ok: false, error: result?.error ?? GENERATE_FAILED_MSG };
}

/** Run a handler, turning a throw into a failed result. */
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
  const previous = game[FLOW_LANE] ?? Promise.resolve();
  const run = previous.catch(() => {}).then(() => driveFlow(game, start, handlers));
  game[FLOW_LANE] = run;
  return run;
}

/**
 * @param {GameApi} game
 * @param {FlowStart} start
 * @param {FlowHandlers} handlers
 * @returns {Promise<FlowOutcome>}
 */
async function driveFlow(game, start, handlers) {
  try {
    return await stepThrough(game, start, handlers);
  } catch (err) {
    return failFlow(handlers, err?.message ?? String(err));
  }
}

/** @returns {FlowOutcome} */
function failFlow(handlers, text) {
  handlers.showError?.(text);
  return { kind: STEP_SHOW_ERROR, text };
}

/**
 * @param {GameApi} game
 * @param {FlowStart} start
 * @param {FlowHandlers} handlers
 * @returns {Promise<FlowOutcome>}
 */
async function stepThrough(game, start, handlers) {
  /** @type {FlowStep} */
  let step = game.flowStart(start);
  while (true) {
    if (step?.ok === false) return failFlow(handlers, step.error ?? FLOW_FAILED_MSG);
    switch (step.step) {
      case STEP_RESOLVE_DEFAULT_TARGET:
        step = game.flowNext({ input: "default_target", name: await handlers.resolveDefaultTarget() });
        break;
      case STEP_CHECK_TARGET:
        step = game.flowNext({ input: "target_checked", exists: (await handlers.checkTarget(step.name)) === true });
        break;
      case STEP_ASK:
        step = game.flowNext({ input: "answered", yes: (await handlers.ask(step)) === true });
        break;
      case STEP_WRITE: {
        const name = step.name;
        step = game.flowNext(wroteInput(await settle(() => handlers.write(name)), name));
        break;
      }
      case STEP_READ_FILE: {
        const path = step.path;
        const read = await settle(() => handlers.readFile(path));
        step = read?.ok === true
          ? game.flowFileRead(read.bytes)
          : game.flowNext({ input: "file_read", ok: false, error: read?.error ?? READ_FAILED_MSG });
        break;
      }
      case STEP_SHOW_GAME:
        await handlers.showGame(step);
        step = game.flowNext({ input: "ack" });
        break;
      case STEP_GENERATE: {
        const difficulty = step.difficulty;
        step = game.flowNext(generatedInput(await settle(() => handlers.generate(difficulty))));
        break;
      }
      case STEP_FORGET_CURRENT_FILE: {
        const forget = { path: step.path, delete: step.delete === true };
        await settle(() => handlers.forgetCurrentFile(forget));
        step = game.flowNext({ input: "ack" });
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
        return failFlow(handlers, `${UNKNOWN_STEP_PREFIX}${step.step}`);
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
