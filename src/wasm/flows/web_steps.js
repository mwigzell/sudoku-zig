// web_steps.js — the browser's handler for every core step: the bound file handle or a picker
// writes the player's file, and the host keeps the restore copy (or is the file, for autosave).

import * as files from "../files.js";
import * as hostApi from "../host_api.js";
import * as steps from "./steps.js";

/** @typedef {import("../types").GameApi} GameApi */
/** @typedef {import("../types").WebSession} WebSession */
/** @typedef {import("../types").StepsOptions} StepsOptions */
/** @typedef {import("../types").FlowHandlers} FlowHandlers */
/** @typedef {import("../types").GameWrite} GameWrite */
/** @typedef {import("../types").WriteResult} WriteResult */

/** Logged if core asks the browser to reclaim a file: only Android's autosave answers `taken`. */
const NO_RECLAIM_REASON = "reclaim_file: browser writes never answer taken";

/**
 * @param {GameApi} game
 * @param {WebSession} session
 * @param {StepsOptions} [options]
 * @returns {FlowHandlers}
 */
export function webSteps(game, session, options = {}) {
  const ctx = steps.stepContext(game, session, options);
  const shared = steps.sharedSteps(ctx);
  /** The file `open` picked; its handle is bound once core shows that game loaded. */
  let opened = null;

  /**
   * Write the bound file; a handle that fails is dropped so the next save picks again.
   * @returns {Promise<WriteResult>}
   */
  const writeBound = async (bytes) => {
    const handle = session.fileHandle;
    try {
      await files.writeHandle(handle, bytes);
      return { ok: true, name: handle.name };
    } catch (err) {
      session.fileHandle = null;
      return { ok: false, error: err?.message ?? String(err) };
    }
  };
  /**
   * Write a file the player picks, suggesting `name`; a picked handle becomes the bound file.
   * @returns {Promise<WriteResult>}
   */
  const writePicked = async (bytes, name) => {
    const saved = await files.persistBytes(bytes, session, name, { win: ctx.win, download: ctx.download });
    if (!saved.ok) return saved;
    if (saved.handle) session.fileHandle = saved.handle;
    return { ok: true, name: saved.filename };
  };
  /** @param {GameWrite} target */
  const saveAs = (target) => steps.writeGame(ctx, (bytes) => writePicked(bytes, target.name), target.name, { restoreCopy: true });

  return {
    ...shared,
    /** The bound file, else a picker; a bound file that fails to write falls back to the picker. */
    save: (target) => {
      if (!session.fileHandle) return saveAs(target);
      if (!target.replace) return steps.EXISTS;
      const writeBoundOrPick = async (bytes) => {
        const wrote = await writeBound(bytes);
        return wrote.ok ? wrote : writePicked(bytes, target.name);
      };
      return steps.writeGame(ctx, writeBoundOrPick, target.name, { restoreCopy: true });
    },
    saveAs,
    /** The bound file, else the host's file under `name`; never a picker. */
    autosave: async (target) => {
      if (session.fileHandle) {
        if (!target.replace) return steps.EXISTS;
        return steps.writeGame(ctx, writeBound, target.name, { restoreCopy: true });
      }
      if (!target.replace && (await hostApi.hostCurrentFileExists(target.name, ctx.fetchFn))) return steps.EXISTS;
      return steps.writeGame(ctx, null, target.name, { restoreCopy: false });
    },
    /** The host copy only: a closing page cannot wait for the bound file. */
    flush: (name) =>
      steps.writeGame(ctx, null, name, { restoreCopy: session.fileHandle != null, fetchFn: steps.keepaliveFetch(ctx.fetchFn) }),
    reclaimFile: () => ({ ok: false, error: NO_RECLAIM_REASON }),
    open: async () => {
      const picked = await ctx.pick(session);
      opened = picked.ok ? { name: picked.name, handle: picked.handle ?? null } : null;
      return picked;
    },
    importPuzzle: () => ctx.pick(session, { types: files.puzzleTextPickerTypes, accept: files.PUZZLE_TEXT_ACCEPT }),
    /** A loaded game is bound to the handle `open` picked for it; any other load drops the binding. */
    showGame: (step) => {
      if (step.loaded) {
        session.fileHandle = opened != null && opened.name === step.file ? opened.handle : null;
        opened = null;
      }
      return shared.showGame(step);
    },
  };
}
