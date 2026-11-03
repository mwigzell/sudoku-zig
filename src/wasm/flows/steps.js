// steps.js — the step handlers web and Android share, and the helpers their own sets build on.

import * as clipboardMod from "../clipboard.js";
import * as errorModalMod from "../dialogs/error_modal.js";
import * as files from "../files.js";
import * as generate from "../gen/generate.js";
import * as hostApi from "../host_api.js";
import * as sessionMod from "./session.js";
import * as statusBar from "../status_bar.js";
import * as stepRunner from "./step_runner.js";

/** @typedef {import("../types").GameApi} GameApi */
/** @typedef {import("../types").WebSession} WebSession */
/** @typedef {import("../types").StepsOptions} StepsOptions */
/** @typedef {import("../types").StepContext} StepContext */
/** @typedef {import("../types").FlowHandlers} FlowHandlers */
/** @typedef {import("../types").WriteResult} WriteResult */

/** What a fixed-file write answers, without writing, when the file is there and replacing is not allowed. */
export const EXISTS = Object.freeze({ ok: false, exists: true });

/**
 * The game, session and platform hooks every handler works with; unset hooks take the browser's.
 * @param {GameApi} game
 * @param {WebSession} session
 * @param {StepsOptions} [options]
 * @returns {StepContext}
 */
export function stepContext(game, session, options = {}) {
  const win = options.win ?? globalThis;
  const doc = options.doc ?? win.document;
  return {
    game,
    session,
    win,
    doc,
    fetchFn: options.fetchFn ?? ((url, init) => globalThis.fetch(url, init)),
    statusEl: options.statusEl ?? null,
    errorModal: options.errorModal ?? null,
    generatingModal: options.generatingModal,
    genWorker: options.genWorker,
    clipboard: options.clipboard ?? win.navigator?.clipboard,
    download: options.download ?? ((bytes, name) => files.downloadBytes(bytes, name, doc)),
    pick: options.pick ?? ((s, opts) => files.pickBytes(doc, s, opts)),
    exportText: options.exportText ?? files.persistPuzzleText,
  };
}

/** `fetchFn` for writes that must outlive a closing page. */
export function keepaliveFetch(fetchFn) {
  return (url, init = {}) => fetchFn(url, { ...init, keepalive: true });
}

/**
 * Fetch the saved game, let `writeUserFile` (when given) write the player's file, then keep the
 * host copy; the written file becomes the session's file. Without `writeUserFile` the host copy
 * is the player's file.
 * @param {StepContext} ctx
 * @param {((bytes: Uint8Array) => Promise<WriteResult>) | null} writeUserFile
 * @param {string} name the file core named, kept when the platform names none
 * @param {{ restoreCopy: boolean, fetchFn?: typeof fetch }} options
 * @returns {Promise<WriteResult>}
 */
export async function writeGame(ctx, writeUserFile, name, { restoreCopy, fetchFn = ctx.fetchFn }) {
  const serialized = ctx.game.toSaveFormat();
  if (!serialized.ok) return serialized;
  let written = name;
  if (writeUserFile) {
    const saved = await writeUserFile(serialized.bytes);
    if (!saved?.ok) return saved ?? { ok: false };
    if (typeof saved.name === "string" && saved.name.length > 0) written = saved.name;
  }
  const hosted = await hostApi.persistCurrentFileBytes(serialized.bytes, fetchFn, written, { restoreCopy });
  if (!hosted.ok) return hosted;
  ctx.session.boundFilename = written;
  sessionMod.syncCurrentFileLabels(ctx.session);
  return { ok: true, name: written };
}

/**
 * Handlers that do the same on web and Android.
 * @param {StepContext} ctx
 * @returns {FlowHandlers}
 */
export function sharedSteps(ctx) {
  const { game, session, win, doc, fetchFn, statusEl, errorModal, generatingModal, genWorker, clipboard, download, exportText } = ctx;
  return {
    resolveDefaultTarget: () => session.default_save_filename,
    ask: (step) => stepRunner.askWithDialog(step, win),
    exportPuzzle: async (name) => {
      const exported = game.toPuzzle();
      if (!exported.ok) return exported;
      const saved = await exportText(exported.bytes, session, name, { win, download });
      return saved.ok ? { ok: true, name: saved.filename } : saved;
    },
    copyPuzzle: () => clipboardMod.startCopyPuzzleOnClick(game, { clipboard, doc }),
    pastePuzzle: async () => {
      const read = await clipboardMod.readClipboardText({ clipboard });
      return read.ok ? { ok: true, bytes: new TextEncoder().encode(read.text) } : read;
    },
    restore: (path) => hostApi.restore(path, fetchFn),
    showGame: (step) => {
      session.boundFilename = step.file ?? null;
      sessionMod.applySessionOutcomeStatus(session, statusEl, {
        state: step.state,
        legend: step.legend,
        config: step.config,
        msg: step.text ?? null,
      });
    },
    generateGame: (difficulty) => generate.generateWithModal(game, generatingModal, { difficulty, genWorker }),
    forgetCurrentFile: (forget) => hostApi.forgetCurrentFile(forget.delete, fetchFn),
    persistSettings: (settings) => hostApi.persistSettings(settings, fetchFn),
    showStatus: (text) => {
      sessionMod.syncCurrentFileLabels(session);
      if (statusEl) statusBar.showStatusText(statusEl, text);
    },
    showError: (text) => {
      if (errorModal) errorModalMod.showErrorModal(errorModal, text);
    },
  };
}
