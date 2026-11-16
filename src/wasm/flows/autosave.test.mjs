// autosave.test.mjs — autosave platform work: host copy, bound files, ordering and the page-hide flush.

import assert from "node:assert/strict";
import * as autosave from "./autosave.js";
import * as stepRunner from "./step_runner.js";
import * as webSteps from "./web_steps.js";
import { noPromptDialog, promptDialogStub, hostFetch, moveWithAutosave, postedCurrentFile, settleFlow, withCoreFlow, coreText } from "../test_support.mjs";

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
  const game = await withCoreFlow({ toSaveFormat: () => ({ ok: true, bytes: new Uint8Array([5, 6, 7]) }) }, { autoSave: true, opened: "autosave.sud" });
  const session = { config: { auto_save: true }, boundFilename: "autosave.sud" };
  autosave.wireFlushOnClose(game, webSteps.webSteps(game, session, { fetchFn: host.fetchFn }), { win });
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
  const game = await withCoreFlow({ toSaveFormat: () => ({ ok: true, bytes: new Uint8Array([1]) }) }, { autoSave: true, newGame: true });
  autosave.wireFlushOnClose(game, webSteps.webSteps(game, { config: { auto_save: true } }, { fetchFn: host.fetchFn }), { win });
  win.listeners.get("pagehide")?.();
  await settleFlow();
  assert.equal(host.calls.length, 0);
}

// Pagehide with auto-save off writes nothing even when continuing a file.
{
  const win = makePageHideWin();
  let called = false;
  const game = await withCoreFlow({
    toSaveFormat() {
      called = true;
      return { ok: true, bytes: new Uint8Array([1]) };
    },
  }, { opened: "autosave.sud" });
  const session = { config: { auto_save: false }, boundFilename: "autosave.sud" };
  autosave.wireFlushOnClose(game, webSteps.webSteps(game, session, { fetchFn: async () => ({ ok: true, status: 204 }) }), { win });
  win.listeners.get("pagehide")?.();
  await settleFlow();
  assert.equal(called, false);
}

{
  // First autosave with nothing on disk writes the host default file and binds its name.
  const game = await withCoreFlow({ toSaveFormat: () => ({ ok: true, bytes: new Uint8Array([1, 2, 3]) }) }, { autoSave: true });
  const session = { config: { auto_save: true }, default_save_filename: "sudoku.sud", boundFilename: null };
  const host = hostFetch({ exists: false });
  const outcome = await moveWithAutosave(game, session, { fetchFn: host.fetchFn });
  assert.equal(outcome.kind, "done");
  assert.equal(session.boundFilename, "sudoku.sud");
  assert.equal(postedCurrentFile(host.calls)?.init?.headers?.["X-Sudoku-Restore-Copy"], undefined, "host file is the user's file");
}

{
  // Commands outside the core trigger list write nothing.
  const game = await withCoreFlow({ toSaveFormat: () => ({ ok: true, bytes: new Uint8Array([1]) }) }, { autoSave: true });
  const host = hostFetch();
  const session = { default_save_filename: "sudoku.sud" };
  const persisted = [];
  const outcome = await stepRunner.runCommand(game, { action: "set_config", field: "show_region", value: true }, {
    ...webSteps.webSteps(game, session, { fetchFn: host.fetchFn }),
    showGame() {},
    persistConfig: (config) => {
      persisted.push(config.show_region);
      return { ok: true };
    },
  });
  assert.equal(outcome.kind, "done");
  assert.deepEqual(persisted, [true], "the change ran and persisted its Config");
  assert.equal(host.calls.length, 0);
}

/** Session continuing `bound.sud` through a file handle that records into `writes`; `failure` makes the write throw. */
async function boundAutosaveSetup(writes, failure = null) {
  const game = await withCoreFlow({ toSaveFormat: () => ({ ok: true, bytes: new Uint8Array([4, 2]) }) }, { autoSave: true, opened: "bound.sud" });
  const fileHandle = {
    name: "bound.sud",
    async createWritable() {
      if (failure) throw failure;
      return {
        async write(bytes) {
          writes.push({ lane: "bound", bytes: [...bytes] });
        },
        async close() {},
      };
    },
  };
  const session = { config: { auto_save: true }, boundFilename: "bound.sud", fileHandle };
  const fetchFn = async (url, init) => {
    if (url === "./current-file") {
      writes.push({ lane: "host", bytes: [...new Uint8Array(init.body)], restoreCopy: init.headers["X-Sudoku-Restore-Copy"], keepalive: init.keepalive === true });
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
  await moveWithAutosave(game, session, { fetchFn, promptDialog: noPromptDialog("continuation must not ask") });
  assert.deepEqual(writes, [
    { lane: "bound", bytes: [4, 2] },
    { lane: "host", bytes: [4, 2], restoreCopy: "true", keepalive: false },
  ]);
}

{
  // The page-hide flush on a bound file writes only the host restore copy, kept alive past the page.
  const writes = [];
  const { game, session, fetchFn } = await boundAutosaveSetup(writes);
  const win = makePageHideWin();
  autosave.wireFlushOnClose(game, webSteps.webSteps(game, session, { fetchFn }), { win });
  win.listeners.get("pagehide")?.();
  await settleFlow();
  assert.deepEqual(writes, [{ lane: "host", bytes: [4, 2], restoreCopy: "true", keepalive: true }]);
}

{
  // A failed bound write skips the host copy and shows core's sentence, not the write's reason.
  const writes = [];
  const { game, session, fetchFn } = await boundAutosaveSetup(writes, new Error("bound write failed"));
  const prompts = promptDialogStub();
  const outcome = await moveWithAutosave(game, session, { fetchFn, promptDialog: prompts });
  assert.equal(outcome.kind, "done");
  assert.deepEqual(writes, [], "host copy must not run when bound autosave fails");
  assert.equal(prompts.lastText, coreText.SAVE_FAILED_MSG);
  assert.equal(session.fileHandle, null, "the failing handle is dropped");
}

/** A status element that counts writes, so a test can tell one sentence from two. */
function countingStatus() {
  let text = "";
  const el = { className: "", writes: 0 };
  Object.defineProperty(el, "textContent", {
    get: () => text,
    set: (value) => {
      text = value;
      el.writes += 1;
    },
  });
  return el;
}

/** A host whose pointer write is refused; `reason` null answers 500 with the body alone. */
function refusingHost(reason, body) {
  return async (url) => {
    if (url === "./current-file-exists") return { ok: true, status: 200, json: async () => ({ exists: false }) };
    const headers = reason ? { get: (name) => (name === "X-Sudoku-Refusal" ? reason : null) } : undefined;
    return { ok: false, status: 500, headers, text: async () => body };
  };
}

{
  // A refused host pointer write follows bytes that landed: the page hands core the kind, and core's
  // written-not-current sentence is the only status the player sees.
  const game = await withCoreFlow({ toSaveFormat: () => ({ ok: true, bytes: new Uint8Array([3]) }) }, { autoSave: true, newGame: true });
  const status = countingStatus();
  const prompts = promptDialogStub();
  const session = { config: { auto_save: true }, default_save_filename: "sudoku.sud", boundFilename: null };
  const outcome = await moveWithAutosave(game, session, {
    fetchFn: refusingHost("settings_unwritable", coreText.WRITTEN_SETTINGS_WRITE_FAILED_MSG),
    statusEl: status,
    promptDialog: prompts,
  });

  assert.deepEqual(outcome, { kind: "show_status", text: coreText.WRITTEN_SETTINGS_WRITE_FAILED_MSG });
  assert.equal(status.writes, 1, "one status sentence, written once");
  assert.equal(status.textContent, coreText.WRITTEN_SETTINGS_WRITE_FAILED_MSG);
  assert.equal(prompts.shown.length, 0, "no failure sentence follows it");
}

{
  // A refusal the host named no kind for keeps the old answer: the host's body in the status line
  // and core's failure prompt, since nothing tells the page the bytes landed.
  const game = await withCoreFlow({ toSaveFormat: () => ({ ok: true, bytes: new Uint8Array([3]) }) }, { autoSave: true, newGame: true });
  const status = countingStatus();
  const prompts = promptDialogStub();
  const hostSaid = "The host wrote this and named no refusal.";
  const session = { config: { auto_save: true }, default_save_filename: "sudoku.sud", boundFilename: null };
  const outcome = await moveWithAutosave(game, session, { fetchFn: refusingHost(null, hostSaid), statusEl: status, promptDialog: prompts });

  assert.equal(status.textContent, hostSaid, "the host's own words are still shown");
  assert.equal(prompts.lastText, coreText.SAVE_FAILED_MSG);
  assert.equal(outcome.kind, "done");
}

{
  // An opened game continues its file: the first autosave writes without a replace question.
  const game = await withCoreFlow({ toSaveFormat: () => ({ ok: true, bytes: new Uint8Array([9]) }) }, { autoSave: true, opened: "autosave.sud" });
  const host = hostFetch({ exists: true });
  await moveWithAutosave(game, { config: { auto_save: true }, boundFilename: "autosave.sud" }, { fetchFn: host.fetchFn, promptDialog: noPromptDialog("continued file must not ask") });
  assert.equal(postedCurrentFile(host.calls)?.init?.headers?.["X-Sudoku-Filename"], "autosave.sud");
}

{
  // Overlapping autosaves run one at a time, so the latest snapshot lands last.
  const writes = [];
  let firstWriteResolve = null;
  let currentSnapshot = new Uint8Array([1]);
  const game = await withCoreFlow({ toSaveFormat: () => ({ ok: true, bytes: currentSnapshot }) }, { autoSave: true, opened: "autosave.sud" });
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
