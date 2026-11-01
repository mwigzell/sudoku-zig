// autosave.test.mjs — autosave platform work: host copy, bound files, ordering and the page-hide flush.

import assert from "node:assert/strict";
import * as autosave from "./autosave.js";
import { runCommand } from "./step_runner.js";
import { hostFetch, moveWithAutosave, postedCurrentFile, settleFlow, withCoreFlow } from "./test_support.mjs";

function makePageHideWin() {
  const listeners = new Map();
  return {
    listeners,
    addEventListener(name, fn) {
      listeners.set(name, fn);
    },
    removeEventListener(name, fn) {
      if (listeners.get(name) === fn) listeners.delete(name);
    },
  };
}

// Pagehide while continuing a file: one keepalive host write.
{
  const win = makePageHideWin();
  const host = hostFetch();
  const game = await withCoreFlow({ serialize: () => ({ ok: true, bytes: new Uint8Array([5, 6, 7]) }) }, { autoSave: true, opened: "autosave.sud" });
  const session = { config: { auto_save: true }, boundFilename: "autosave.sud" };
  autosave.wireFinalSnapshotOnPageHide(game, session, { win, fetchFn: host.fetchFn });
  win.listeners.get("pagehide")?.();
  await settleFlow();
  assert.equal(host.calls.length, 1);
  assert.equal(host.calls[0].url, "./current-file");
  assert.equal(host.calls[0].init.keepalive, true);
  assert.equal(host.calls[0].init.headers["X-Sudoku-Filename"], "autosave.sud");
}

// Pagehide on a detached game writes nothing: nobody is left to answer a replace question.
{
  const win = makePageHideWin();
  const host = hostFetch();
  const game = await withCoreFlow({ serialize: () => ({ ok: true, bytes: new Uint8Array([1]) }) }, { autoSave: true, newGame: true });
  autosave.wireFinalSnapshotOnPageHide(game, { config: { auto_save: true } }, { win, fetchFn: host.fetchFn });
  win.listeners.get("pagehide")?.();
  await settleFlow();
  assert.equal(host.calls.length, 0);
}

// Pagehide with auto-save off writes nothing even when continuing a file.
{
  const win = makePageHideWin();
  let called = false;
  const game = await withCoreFlow({
    serialize() {
      called = true;
      return { ok: true, bytes: new Uint8Array([1]) };
    },
  }, { opened: "autosave.sud" });
  autosave.wireFinalSnapshotOnPageHide(game, { config: { auto_save: false }, boundFilename: "autosave.sud" }, {
    win,
    fetchFn: async () => ({ ok: true, status: 204 }),
  });
  win.listeners.get("pagehide")?.();
  await settleFlow();
  assert.equal(called, false);
}

{
  // First autosave with nothing on disk writes the host default file and binds its name.
  const game = await withCoreFlow({ serialize: () => ({ ok: true, bytes: new Uint8Array([1, 2, 3]) }) }, { autoSave: true });
  const session = { config: { auto_save: true }, default_save_filename: "sudoku.sud", boundFilename: null };
  const host = hostFetch({ exists: false });
  const outcome = await moveWithAutosave(game, session, { fetchFn: host.fetchFn });
  assert.equal(outcome.kind, "done");
  assert.equal(session.boundFilename, "sudoku.sud");
  assert.equal(postedCurrentFile(host.calls)?.init?.headers?.["X-Sudoku-Restore-Copy"], undefined, "host file is the user's file");
}

{
  // Commands outside the core trigger list write nothing.
  const game = await withCoreFlow({ serialize: () => ({ ok: true, bytes: new Uint8Array([1]) }) }, { autoSave: true });
  const host = hostFetch();
  const session = { default_save_filename: "sudoku.sud" };
  const outcome = await runCommand(game, { action: "toggle_region" }, {
    ...autosave.autosaveHandlers(game, session, { fetchFn: host.fetchFn }),
    showGame() {},
    persistSettings: () => ({ ok: true }),
  });
  assert.equal(outcome.kind, "done");
  assert.equal(host.calls.length, 0);
}

/** Session continuing `bound.sud` through a bound writer that records into `writes`. */
async function boundAutosaveSetup(writes, boundResult = { ok: true }) {
  const game = await withCoreFlow({ serialize: () => ({ ok: true, bytes: new Uint8Array([4, 2]) }) }, { autoSave: true, opened: "bound.sud" });
  const session = {
    config: { auto_save: true },
    boundFilename: "bound.sud",
    boundTargetExists: () => true,
    boundSnapshotWriter: async (bytes) => {
      writes.push({ lane: "bound", bytes: [...bytes] });
      return boundResult;
    },
  };
  const fetchFn = async (url, init) => {
    if (url === "./current-file") {
      writes.push({ lane: "host", bytes: [...new Uint8Array(init.body)], restoreCopy: init.headers["X-Sudoku-Restore-Copy"] });
      return { ok: true, status: 204 };
    }
    throw new Error(`unexpected fetch url: ${url}`);
  };
  return { game, session, fetchFn };
}

{
  // Continuing a bound file: write it first, then the host restore copy; nobody is asked.
  const writes = [];
  const { game, session, fetchFn } = await boundAutosaveSetup(writes);
  const prevChoose = globalThis.__sudokuChoose;
  globalThis.__sudokuChoose = async () => assert.fail("continuation must not ask");
  await moveWithAutosave(game, session, { fetchFn });
  globalThis.__sudokuChoose = prevChoose;
  assert.deepEqual(writes, [
    { lane: "bound", bytes: [4, 2] },
    { lane: "host", bytes: [4, 2], restoreCopy: "true" },
  ]);
}

{
  // A failed bound write skips the host copy and surfaces the error.
  const writes = [];
  const { game, session, fetchFn } = await boundAutosaveSetup(writes, { ok: false, error: "bound write failed" });
  let surfaced = null;
  const outcome = await moveWithAutosave(game, session, {
    fetchFn,
    onError: (err) => {
      surfaced = err;
    },
  });
  assert.equal(outcome.kind, "show_error");
  assert.deepEqual(writes, [{ lane: "bound", bytes: [4, 2] }], "host copy must not run when bound autosave fails");
  assert.equal(surfaced?.error, "bound write failed");
}

{
  // An opened game continues its file: the first autosave writes without a replace question.
  const game = await withCoreFlow({ serialize: () => ({ ok: true, bytes: new Uint8Array([9]) }) }, { autoSave: true, opened: "autosave.sud" });
  const host = hostFetch({ exists: true });
  const prevChoose = globalThis.__sudokuChoose;
  globalThis.__sudokuChoose = async () => assert.fail("continued file must not ask");
  await moveWithAutosave(game, { config: { auto_save: true }, boundFilename: "autosave.sud" }, { fetchFn: host.fetchFn });
  globalThis.__sudokuChoose = prevChoose;
  assert.equal(postedCurrentFile(host.calls)?.init?.headers?.["X-Sudoku-Filename"], "autosave.sud");
}

{
  // Overlapping autosaves run one at a time, so the latest snapshot lands last.
  const writes = [];
  let firstWriteResolve = null;
  let currentSnapshot = new Uint8Array([1]);
  const game = await withCoreFlow({ serialize: () => ({ ok: true, bytes: currentSnapshot }) }, { autoSave: true, opened: "autosave.sud" });
  const session = { config: { auto_save: true }, boundFilename: "autosave.sud" };
  const fetchFn = async (url, init) => {
    if (url === "./current-file-exists") return { ok: true, json: async () => ({ exists: true }) };
    if (url === "./current-file") {
      const bodyBytes = new Uint8Array(init.body);
      if (firstWriteResolve == null) {
        return await new Promise((resolve) => {
          firstWriteResolve = () => {
            writes.push(bodyBytes);
            resolve({ ok: true, status: 204 });
          };
        });
      }
      writes.push(bodyBytes);
      return { ok: true, status: 204 };
    }
    throw new Error(`unexpected fetch url: ${url}`);
  };

  const first = moveWithAutosave(game, session, { fetchFn });
  await settleFlow();
  currentSnapshot = new Uint8Array([2]);
  const second = moveWithAutosave(game, session, { fetchFn }, { action: "fill", row: 0, col: 3, digit: 5 });
  await settleFlow();
  assert.equal(writes.length, 0, "second autosave waits for the first");
  firstWriteResolve?.();
  await Promise.all([first, second]);
  assert.deepEqual(writes.map((bytes) => [...bytes]), [[1], [2]], "latest autosave snapshot lands last");
}
