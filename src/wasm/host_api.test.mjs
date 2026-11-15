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
{
  const refused = await hostApi.persistCurrentFileBytes(
    new Uint8Array([5]),
    async () => ({ ok: false, status: 500, text: async () => "  refusal line from the host\n" }),
    "refused.sud",
  );
  assert.deepEqual(refused, { ok: false, error: "current-file persist failed: 500", hostSaid: "refusal line from the host" });
}

// A refusal with no body (a host fault, or a fake answering bare) adds no words for the player.
{
  const refused = await hostApi.persistCurrentFileBytes(new Uint8Array([6]), async () => ({ ok: false, status: 500 }), "refused.sud");
  assert.deepEqual(refused, { ok: false, error: "current-file persist failed: 500", hostSaid: "" });
}
