// session_cost.test.mts — a run's tokens are read from the session file, because pi reports none.
//
// The harness used to log "the agent reported no token usage" for every role: sandcastle's pi
// provider reports a session id but no usage. The figures are on disk, so these tests pin the two
// things that make reading them honest — summing every assistant message, and saying so rather
// than claiming zero when there is nothing to read.

import test from "node:test";
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { readSessionCost, sessionFile, sumSessionUsage } from "./session_cost.mts";

/** One session line, as pi writes it: an assistant message carrying a usage block. */
function assistantLine(usage: Record<string, number>): string {
  return JSON.stringify({ type: "message", message: { role: "assistant", usage } });
}

test("a session's cost is every assistant message summed, not the last one", () => {
  const content = [
    assistantLine({ input: 100, output: 10, cacheRead: 1_000, cacheWrite: 5 }),
    assistantLine({ input: 200, output: 20, cacheRead: 2_000, cacheWrite: 0 }),
  ].join("\n");

  assert.deepEqual(sumSessionUsage(content), {
    inputTokens: 300,
    outputTokens: 30,
    cacheReadInputTokens: 3_000,
    cacheCreationInputTokens: 5,
  });
});

test("a session with no usage to read says so rather than reporting zero", () => {
  const noUsage = JSON.stringify({ type: "message", message: { role: "assistant" } });
  const userTurn = JSON.stringify({ type: "message", message: { role: "user" } });

  assert.equal(sumSessionUsage(""), null, "an empty session has no cost to report");
  assert.equal(sumSessionUsage([noUsage, userTurn].join("\n")), null, "usage on a user turn is not the model's cost");
});

test("a half-written last line and a non-JSON line are skipped, not fatal", () => {
  const content = ["not json at all", assistantLine({ input: 5, output: 1 }), '{"type":"message","mess'].join("\n");

  assert.deepEqual(sumSessionUsage(content), {
    inputTokens: 5,
    outputTokens: 1,
    cacheReadInputTokens: 0,
    cacheCreationInputTokens: 0,
  });
});

test("a session is found by the id the agent reported, one directory down", () => {
  const root = mkdtempSync(join(tmpdir(), "sessions-"));
  const project = join(root, "--home-mark-Dev-src-sudoku--");
  mkdirSync(project);
  const file = join(project, "2026-11-19T23-06-30-284Z_01a1f60f-c20a-7447-ade8-6a46fee65374.jsonl");
  writeFileSync(file, assistantLine({ input: 7, output: 3 }));

  assert.equal(sessionFile(root, "01a1f60f-c20a-7447-ade8-6a46fee65374"), file);
  assert.equal(sessionFile(root, "no-such-session"), null, "an unknown id finds no file");
  assert.equal(sessionFile(join(root, "absent"), "01a1f60f"), null, "a missing sessions dir is not an error");
  assert.deepEqual(readSessionCost(root, "01a1f60f-c20a-7447-ade8-6a46fee65374"), {
    inputTokens: 7,
    outputTokens: 3,
    cacheReadInputTokens: 0,
    cacheCreationInputTokens: 0,
  });
  assert.equal(readSessionCost(root, null), null, "a run with no session id has no cost to read");
});
