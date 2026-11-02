// command_flow.js — platform work for core's command flow: show the game, persist settings, generate, autosave.

import * as autosave from "./autosave.js";
import * as generate from "../gen/generate.js";
import * as hostApi from "../host_api.js";
import * as sessionMod from "./session.js";
import * as statusBar from "../status_bar.js";
import * as stepRunner from "./step_runner.js";

/** @typedef {import("../types").GameApi} GameApi */
/** @typedef {import("../types").FlowHandlers} FlowHandlers */
/** @typedef {import("../types").WebSession} WebSession */
/** @typedef {import("../types").GeneratingModal} GeneratingModal */
/** @typedef {import("../types").GenWorker} GenWorker */

/**
 * Platform work for a core command flow: take the shown game into the session, persist
 * settings, autosave. Core decides which of these a command needs.
 * @param {GameApi} game
 * @param {WebSession} session
 * @param {{ fetchFn?: typeof fetch, win?: Window & typeof globalThis, statusEl?: HTMLElement | null, onError?: (failed: { ok: false, error: string }) => void, generatingModal?: GeneratingModal, genWorker?: GenWorker }} [options]
 * @returns {FlowHandlers}
 */
export function commandHandlers(
  game,
  session,
  { fetchFn = globalThis.fetch, win = globalThis, statusEl = null, onError, generatingModal, genWorker } = {},
) {
  return {
    ...autosave.autosaveHandlers(game, session, { fetchFn, win, onError }),
    persistSettings: (settings) => hostApi.postHostSettings(settings, fetchFn),
    generate: (difficulty) => generate.generateWithModal(game, generatingModal, { difficulty, genWorker }),
    showGame: (step) => {
      session.boundFilename = step.file ?? null;
      sessionMod.syncCurrentFileLabels(session);
      sessionMod.applySessionOutcomeStatus(session, statusEl, {
        state: step.state,
        legend: step.legend,
        config: step.config,
        msg: step.text ?? null,
      });
    },
    showStatus: (text) => {
      if (statusEl) statusBar.showStatusText(statusEl, text);
    },
  };
}

/**
 * Run `action` through core; `onShown` redraws once the session holds the game core showed.
 * @param {GameApi} game
 * @param {import("../types").ExecAction} action
 * @param {FlowHandlers} handlers
 * @param {(step: import("../types").FlowStep) => void} [onShown]
 */
export function runSessionCommand(game, action, handlers, onShown) {
  return stepRunner.runCommand(game, action, {
    ...handlers,
    showGame: async (step) => {
      await handlers.showGame?.(step);
      onShown?.(step);
    },
  });
}
