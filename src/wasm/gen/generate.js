// generate.js — answers core's `generate` step: a puzzle line from the worker or the main thread, behind the generating dialog.

import * as generating from "../dialogs/generating.js";
import * as genClient from "./gen_client.js";
import * as genProgressRows from "./gen_progress_rows.js";

/** @typedef {import("../types").GameApi} GameApi */

/** Merge the dialog row sink and the plain text sink for core's progress lines. */
function mergeGenProgressHandlers(onProgressWire, onGenProgress) {
  if (!onProgressWire && !onGenProgress) return undefined;
  return (phase, text) => {
    onProgressWire?.(phase, text);
    onGenProgress?.(text);
  };
}

/** Resolve effective difficulty/log level for generation from call options or live engine config. */
function genWireFromEngine(game, options) {
  const cfg = game.getConfig();
  return {
    difficulty: options.difficulty ?? cfg.difficulty,
    logLevel: options.logLevel ?? cfg.log_level,
  };
}

/** Generate a puzzle line in a Web Worker; modal + optional Cancel. Core applies the line. */
/** @param {GameApi} game */
export async function generateWithWorker(game, modal, { difficulty, logLevel, genWorker, onGenProgress, onProgressWire } = {}) {
  const wire = genWireFromEngine(game, { difficulty, logLevel });
  const onProgress = mergeGenProgressHandlers(onProgressWire, onGenProgress);
  return generating.runWithGeneratingDialog(modal, async (cancelRef) => {
    const { promise, cancel } = genClient.startGenInWorker({
      workerUrl: genWorker.workerUrl,
      wasmBytes: genWorker.wasmBytes,
      difficulty: wire.difficulty,
      logLevel: wire.logLevel,
      onProgress,
      WorkerCtor: genWorker.WorkerCtor,
      fetchFn: genWorker.fetchFn,
    });
    cancelRef.fn = cancel;
    return promise;
  });
}

/** Generate a puzzle line on the main thread (modal spinner; blocks the page). */
/** @param {GameApi} game */
async function generateOnMainThread(game, modal, { difficulty, logLevel, onGenProgress, onProgressWire } = {}) {
  const wire = genWireFromEngine(game, { difficulty, logLevel });
  const onProgress = mergeGenProgressHandlers(onProgressWire, onGenProgress);
  return generating.runWithGeneratingDialog(modal, async (cancelRef) => {
    cancelRef.fn = () => game.requestGenAbort?.();
    game.setGenProgressListener?.(onProgress ?? null);
    try {
      const gen = game.generatePuzzle({ difficulty: wire.difficulty, logLevel: wire.logLevel });
      if (!gen.ok && gen.error === "cancelled") return { ok: false, cancelled: true };
      return gen;
    } finally {
      game.setGenProgressListener?.(null);
    }
  });
}

function shouldFallbackFromWorker(result) {
  if (result.ok || result.cancelled) return false;
  const err = result.error ?? "";
  // Only when Workers are missing — main-thread generation blocks the page (Cancel cannot run).
  return err === "workers unavailable";
}

/**
 * Answer a `generate` step: prefer the worker, fall back to the main thread.
 * @param {GameApi} game
 * @returns {Promise<import("../types").GenerateResult>}
 */
export async function generateWithModal(game, modal, options = {}) {
  const { genWorker, onGenProgress } = options;
  const wire = genWireFromEngine(game, options);
  const rowSink =
    typeof modal?.renderProgressRows === "function" ? genProgressRows.createGenProgressModalSink(modal) : null;
  const onProgressWire = rowSink ? (phase, text) => rowSink.push(phase, text) : undefined;
  const gen = { difficulty: wire.difficulty, logLevel: wire.logLevel, onGenProgress, onProgressWire };
  if (genWorker && genClient.canUseGenWorker()) {
    const workerResult = await generateWithWorker(game, modal, { ...gen, genWorker });
    if (!shouldFallbackFromWorker(workerResult)) return workerResult;
  }
  return generateOnMainThread(game, modal, gen);
}
