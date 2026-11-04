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
export const STEP_PROMPT_MESSAGE = "prompt_message";
export const STEP_SAVE = "save";
export const STEP_SAVE_AS = "save_as";
export const STEP_AUTOSAVE = "autosave";
export const STEP_FLUSH = "flush";
export const STEP_EXPORT_PUZZLE = "export_puzzle";
export const STEP_RECLAIM_FILE = "reclaim_file";
export const STEP_COPY_PUZZLE = "copy_puzzle";
export const STEP_PASTE_PUZZLE = "paste_puzzle";
export const STEP_RESTORE = "restore";
export const STEP_OPEN = "open";
export const STEP_IMPORT_PUZZLE = "import_puzzle";
export const STEP_SHOW_GAME = "show_game";
export const STEP_GENERATE_GAME = "generate_game";
export const STEP_FORGET_CURRENT_FILE = "forget_current_file";
export const STEP_PERSIST_SETTINGS = "persist_settings";
export const STEP_SHOW_STATUS = "show_status";
export const STEP_DONE = "done";

export const FLOW_AUTOSAVE_FLUSH = "autosave_flush";
export const FLOW_STARTUP = "startup";

/** Input names core's `flowNext` reads (`boundary.zig` `parseFlowInput`). */
const INPUT_DEFAULT_TARGET = "default_target";
const INPUT_PRESSED = "pressed";
const INPUT_WROTE = "wrote";
const INPUT_READ = "read";
const INPUT_GENERATED = "generated";
const INPUT_PERSISTED = "persisted";
const INPUT_COPIED = "copied";
const INPUT_ACK = "ack";

/** Game write steps and the handler that carries each out. */
const GAME_WRITE_HANDLERS = {
  [STEP_SAVE]: "save",
  [STEP_SAVE_AS]: "saveAs",
  [STEP_AUTOSAVE]: "autosave",
};
/** Reading steps and the handler that carries each out; the path is the one core named, if any. */
const READ_HANDLERS = {
  [STEP_RESTORE]: "restore",
  [STEP_OPEN]: "open",
  [STEP_IMPORT_PUZZLE]: "importPuzzle",
  [STEP_PASTE_PUZZLE]: "pastePuzzle",
};

const FLOW_LANE = Symbol("flowLane");
const UNKNOWN_STEP_PREFIX = "unknown flow step: ";
/** Logged when a handler reports failure without saying why; core words what the user sees. */
const NO_REASON = "no reason given";

/**
 * A failed `input` for core; core logs the reason.
 * @param {string} input
 * @param {{ error?: string }} [result]
 */
function failedInput(input, result) {
  return { input, ok: false, error: result?.error ?? NO_REASON };
}

/**
 * Normalize a handler's write outcome to the wasm `wrote` input.
 * @param {import("../types").WriteResult} result
 * @param {string | null} name the target core named, reported when the platform names none
 */
function wroteInput(result, name) {
  if (result?.ok === true) return { input: INPUT_WROTE, ok: true, name: result.name ?? name };
  if (result?.exists === true) return { input: INPUT_WROTE, ok: false, exists: true };
  if (result?.cancelled === true) return { input: INPUT_WROTE, ok: false, cancelled: true };
  if (result?.taken) return { input: INPUT_WROTE, ok: false, taken: true, name: result.taken.name };
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
 * Answer a reading step: bytes go to core through `flowRead`.
 * @param {GameApi} game
 * @param {import("../types").PickResult} result
 * @returns {FlowStep}
 */
function readAnswer(game, result) {
  if (result?.ok === true) return game.flowRead(result.bytes, result.name ?? null);
  if (result?.cancelled === true) return game.flowNext({ input: INPUT_READ, ok: false, cancelled: true });
  return game.flowNext(failedInput(INPUT_READ, result));
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
 * `onShown` redraws once the session holds the game core showed.
 * @param {GameApi} game
 * @param {FlowStart} start
 * @param {FlowHandlers} handlers
 * @param {(step: FlowStep) => void} [onShown]
 * @returns {Promise<FlowOutcome>}
 */
export function runFlow(game, start, handlers, onShown) {
  return enqueueFlow(game, () => game.flowStart(start), withShown(handlers, onShown));
}

/**
 * Run one player command end to end: core applies it, then drives every follow-up as steps.
 * @param {GameApi} game
 * @param {ExecAction} action
 * @param {FlowHandlers} handlers
 * @param {(step: FlowStep) => void} [onShown]
 * @returns {Promise<FlowOutcome>}
 */
export function runCommand(game, action, handlers, onShown) {
  return enqueueFlow(game, () => game.commandStart(action), withShown(handlers, onShown));
}

/**
 * @param {FlowHandlers} handlers
 * @param {(step: FlowStep) => void} [onShown]
 * @returns {FlowHandlers}
 */
function withShown(handlers, onShown) {
  if (!onShown) return handlers;
  return {
    ...handlers,
    showGame: async (step) => {
      await handlers.showGame?.(step);
      onShown(step);
    },
  };
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
      case STEP_PROMPT_MESSAGE:
        step = game.flowNext({ input: INPUT_PRESSED, index: await handlers.promptMessage(step) });
        break;
      case STEP_SAVE:
      case STEP_SAVE_AS:
      case STEP_AUTOSAVE: {
        const target = { name: step.name, replace: step.replace === true };
        const handler = GAME_WRITE_HANDLERS[step.step];
        step = game.flowNext(wroteInput(await settle(() => handlers[handler](target)), target.name));
        break;
      }
      case STEP_FLUSH: {
        const name = step.name;
        step = game.flowNext(wroteInput(await settle(() => handlers.flush(name)), name));
        break;
      }
      case STEP_EXPORT_PUZZLE: {
        const name = step.name;
        step = game.flowNext(wroteInput(await settle(() => handlers.exportPuzzle(name)), name));
        break;
      }
      case STEP_RECLAIM_FILE:
        step = game.flowNext(wroteInput(await settle(() => handlers.reclaimFile()), null));
        break;
      case STEP_COPY_PUZZLE:
        step = game.flowNext(outcomeInput(INPUT_COPIED, await settle(() => handlers.copyPuzzle())));
        break;
      case STEP_RESTORE:
      case STEP_OPEN:
      case STEP_IMPORT_PUZZLE:
      case STEP_PASTE_PUZZLE: {
        const path = step.path ?? null;
        const handler = READ_HANDLERS[step.step];
        step = readAnswer(game, await settle(() => handlers[handler](path)));
        break;
      }
      case STEP_SHOW_GAME:
        await handlers.showGame(step);
        step = game.flowNext({ input: INPUT_ACK });
        break;
      case STEP_GENERATE_GAME: {
        const difficulty = step.difficulty;
        step = game.flowNext(generatedInput(await settle(() => handlers.generateGame(difficulty))));
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
      case STEP_DONE:
        return { kind: STEP_DONE };
      default:
        return failFlow(game, handlers, `${UNKNOWN_STEP_PREFIX}${step.step}`);
    }
  }
}
