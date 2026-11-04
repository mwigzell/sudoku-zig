// android_steps.js — the Android WebView's handler for every core step: saved games and puzzle files
// go through the Java file bridge, which holds the bound file; the host keeps the restore copy.

import * as steps from "./steps.js";

/** @typedef {import("../types").GameApi} GameApi */
/** @typedef {import("../types").WebSession} WebSession */
/** @typedef {import("../types").StepsOptions} StepsOptions */
/** @typedef {import("../types").FlowHandlers} FlowHandlers */
/** @typedef {import("../types").GameWrite} GameWrite */
/** @typedef {import("../types").WriteResult} WriteResult */
/** @typedef {import("../types").PickResult} PickResult */
/** @typedef {import("../types").AndroidFileBridge} AndroidFileBridge */
/** @typedef {import("../types").AndroidBridgeResult} AndroidBridgeResult */

const BRIDGE_CANCELLED = "cancelled";
/** Bridge reason: this install may not write the file. */
const BRIDGE_TAKEN = "taken";
const INVALID_PAYLOAD_REASON = "invalid Android file payload";

/** File bytes as the bridge's base64 text. */
function bytesToBase64(bytes) {
  const chars = [];
  for (const b of bytes) chars.push(String.fromCharCode(b));
  return btoa(chars.join(""));
}

/** The bridge's base64 text as bytes. */
function base64ToBytes(base64) {
  const text = atob(base64);
  const out = new Uint8Array(text.length);
  for (let i = 0; i < text.length; i += 1) out[i] = text.charCodeAt(i);
  return out;
}

/**
 * A bridge save result as a write result.
 * @param {AndroidBridgeResult} out
 * @param {string} name the name asked for, reported for a taken file the bridge names none for
 * @returns {WriteResult}
 */
function bridgeWrote(out, name) {
  if (out?.ok === true) return typeof out.name === "string" && out.name.length > 0 ? { ok: true, name: out.name } : { ok: true };
  if (out?.reason === BRIDGE_TAKEN) return { ok: false, taken: { name: out.name ?? name } };
  if (out?.cancelled === true || out?.reason === BRIDGE_CANCELLED) return { ok: false, cancelled: true };
  return { ok: false, error: out?.error };
}

/**
 * @param {GameApi} game
 * @param {WebSession} session
 * @param {AndroidFileBridge} bridge
 * @param {StepsOptions} [options]
 * @returns {FlowHandlers}
 */
export function androidSteps(game, session, bridge, options = {}) {
  const ctx = steps.stepContext(game, session, options);
  /** Whether the bridge holds a bound file, which is there to replace. */
  const bound = () => {
    const name = bridge.currentSudokuFileName?.();
    return typeof name === "string" && name.length > 0;
  };
  /**
   * Write the saved game through `call` and keep the restore copy.
   * @param {(base64: string) => AndroidBridgeResult | Promise<AndroidBridgeResult>} call
   * @param {string} name
   */
  const writeThroughBridge = (call, name) =>
    steps.writeGame(ctx, async (bytes) => bridgeWrote(await call(bytesToBase64(bytes)), name), name, { restoreCopy: true });
  /**
   * Read the file the bridge's picker returns.
   * @param {() => AndroidBridgeResult | Promise<AndroidBridgeResult>} pick
   * @returns {Promise<PickResult>}
   */
  const readThroughBridge = async (pick) => {
    const out = await pick();
    if (out?.ok !== true) {
      if (out?.cancelled === true || out?.reason === BRIDGE_CANCELLED) return { ok: false, cancelled: true };
      return { ok: false, error: out?.error };
    }
    if (typeof out.base64 !== "string" || typeof out.name !== "string") return { ok: false, error: INVALID_PAYLOAD_REASON };
    return { ok: true, bytes: base64ToBytes(out.base64), name: out.name };
  };

  return {
    ...steps.sharedSteps(ctx),
    /** @param {GameWrite} target */
    save: (target) => {
      if (!target.replace && bound()) return steps.EXISTS;
      return writeThroughBridge((b64) => bridge.save(b64, target.name), target.name);
    },
    /** @param {GameWrite} target */
    saveAs: (target) => writeThroughBridge((b64) => bridge.saveAs(b64, target.name), target.name),
    /** The bound file, else the default visible file; either may be one this install may not write (`taken`). */
    autosave: (target) => {
      if (!target.replace && bound()) return steps.EXISTS;
      return writeThroughBridge((b64) => bridge.autosave(b64, target.name), target.name);
    },
    /** The host copy only: a closing app cannot wait for the bridge. */
    flush: (name) => steps.writeGame(ctx, null, name, { restoreCopy: true, fetchFn: steps.keepaliveFetch(ctx.fetchFn) }),
    reclaimFile: () => writeThroughBridge((b64) => bridge.reclaimFile(b64), session.default_save_filename),
    /** @param {string} name */
    exportPuzzle: async (name) => {
      const exported = game.toPuzzle();
      if (!exported.ok) return exported;
      return bridgeWrote(await bridge.exportPuzzle(bytesToBase64(exported.bytes), name), name);
    },
    open: () => readThroughBridge(() => bridge.open()),
    importPuzzle: () => readThroughBridge(() => bridge.importPuzzle()),
  };
}
