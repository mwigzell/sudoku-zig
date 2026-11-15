// host_api.test.mjs — host HTTP calls: current-file writes and the exists check.

import assert from "node:assert/strict";
import * as hostApi from "./host_api.js";
import { hostFetch } from "./test_support.mjs";

{
  const calls = [];
  const game = {
    toSaveFormat() {
      return { ok: true, bytes: new Uint8Array([1, 2]) };
    },
  };
  const out = await hostApi.persistCurrentFileBytes(
    game.toSaveFormat().bytes,
    async (url, init) => {
      calls.push({ url, init });
      return { ok: true, status: 204 };
    },
    "named-save.sud",
  );
  assert.equal(out.ok, true);
  assert.equal(calls[0].url, "./current-file");
  assert.equal(calls[0].init.headers["X-Sudoku-Filename"], "named-save.sud");
}

{
  const calls = [];
  const out = await hostApi.persistCurrentFileBytes(
    new Uint8Array([3]),
    async (url, init) => {
      calls.push({ url, init });
      return { ok: true, status: 204 };
    },
    "picked.sud",
    { restoreCopy: true },
  );
  assert.equal(out.ok, true);
  assert.equal(calls[0].init.headers["X-Sudoku-Restore-Copy"], "true", "restore copy stays out of the visible folder");
}

{
  const host = hostFetch({ exists: true });
  assert.equal(await hostApi.hostCurrentFileExists("sudoku.sud", host.fetchFn), true);
  assert.equal(host.calls[0].url, "./current-file-exists");
  assert.equal(host.calls[0].init.headers["X-Sudoku-Filename"], "sudoku.sud");
  await assert.rejects(
    hostApi.hostCurrentFileExists("sudoku.sud", async () => ({ ok: false, status: 500 })),
    /current-file check failed: 500/,
  );
}

// A refused write hands the page the host's own words from the body, trimmed; the status stays the reason.
// A refusal the host named also carries the kind core words, on the same answer.
{
  const headers = { get: (name) => (name === "X-Sudoku-Refusal" ? "settings_unreadable" : null) };
  const refused = await hostApi.persistCurrentFileBytes(
    new Uint8Array([5]),
    async () => ({ ok: false, status: 500, headers, text: async () => "  refusal line from the host\n" }),
    "refused.sud",
  );
  assert.deepEqual(refused, {
    ok: false,
    error: "current-file persist failed: 500",
    hostSaid: "refusal line from the host",
    reason: "settings_unreadable",
  });
}

// A refusal with no body or no named kind (a host fault, or a fake answering bare) adds no words and
// carries no reason, so the page keeps its old answer.
{
  const refused = await hostApi.persistCurrentFileBytes(new Uint8Array([6]), async () => ({ ok: false, status: 500 }), "refused.sud");
  assert.deepEqual(refused, { ok: false, error: "current-file persist failed: 500", hostSaid: "", reason: null });
}

// A refused forget names which settings repair applies in the host's header, so core words the status;
// a body alone (or a bare 500) carries no reason and core only logs it.
{
  const headers = { get: (name) => (name === "X-Sudoku-Refusal" ? "settings_unwritable" : null) };
  const refused = await hostApi.forgetCurrentFile(true, async () => ({ ok: false, status: 500, headers }));
  assert.deepEqual(refused, { ok: false, error: "current-file forget failed: 500", reason: "settings_unwritable" });
}

{
  const refused = await hostApi.forgetCurrentFile(true, async () => ({ ok: false, status: 500 }));
  assert.deepEqual(refused, { ok: false, error: "current-file forget failed: 500", reason: null }, "a refusal with no reason names none");
}

{
  const calls = [];
  const forgot = await hostApi.forgetCurrentFile(true, async (url, init) => {
    calls.push({ url, init });
    return { ok: true, status: 204 };
  });
  assert.deepEqual(forgot, { ok: true });
  assert.equal(calls[0].url, "./current-file");
  assert.equal(calls[0].init.method, "DELETE");
  assert.equal(calls[0].init.headers["X-Sudoku-Delete-File"], "true");
}

// The header's value reaches the caller exactly as the host sent it: the page keeps no list of kinds,
// so judging one is core's job, not this module's.
{
  const headers = { get: (name) => (name === "X-Sudoku-Refusal" ? "store_said_no" : null) };
  const refused = await hostApi.forgetCurrentFile(true, async () => ({ ok: false, status: 500, headers }));
  assert.equal(refused.reason, "store_said_no", "an unheard kind still reaches core verbatim");
  const refusedWrite = await hostApi.persistCurrentFileBytes(new Uint8Array([6]), async () => ({ ok: false, status: 500, headers }), "refused.sud");
  assert.equal(refusedWrite.reason, "store_said_no", "the write arm carries it the same way");
}
