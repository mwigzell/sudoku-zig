// accept.test.mts — accepting a run closes the issue it was aimed at, and only when it can name it.

import test from "node:test";
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { closeAcceptedRun } from "./accept.mts";
import { writeRunRecord } from "./run_record.mts";
import { ledgerPath } from "./ledger.mts";

/** A closer that records what it was asked to close, so no test shells out to `gh`. */
function fakeCloser() {
  const closed: Array<{ issue: number; comment: string }> = [];
  return {
    closed,
    close: (issue: number, comment: string) => void closed.push({ issue, comment }),
  };
}

function fixture(): string {
  const root = mkdtempSync(join(tmpdir(), "sandcastle-accept-"));
  return join(root, "runs", "1");
}

test("accepting a run closes the issue its record names, and says which", () => {
  const runsDir = fixture();
  try {
    writeRunRecord(runsDir, {
      issue: 116,
      branch: "sandcastle/sequential-reviewer/1",
      targetBranch: "develop",
      startedAt: "2026-11-13T10:00:00.000Z",
    });
    const closer = fakeCloser();

    const result = closeAcceptedRun(runsDir, "sandcastle/sequential-reviewer/1", "develop", closer);

    assert.deepEqual(result, { closed: 116 });
    assert.deepEqual(closer.closed, [
      { issue: 116, comment: "Accepted sandcastle/sequential-reviewer/1 into develop." },
    ]);
  } finally {
    rmSync(join(runsDir, "..", ".."), { recursive: true, force: true });
  }
});

test("a run directory from before run records falls back to the issue its ledger names", () => {
  const runsDir = fixture();
  try {
    mkdirSync(runsDir, { recursive: true });
    writeFileSync(ledgerPath(runsDir), JSON.stringify({ issue: 42, ticks: [{ position: 1, at: "a" }] }));

    assert.deepEqual(closeAcceptedRun(runsDir, "sandcastle/x/1", "develop", fakeCloser()), { closed: 42 });
  } finally {
    rmSync(join(runsDir, "..", ".."), { recursive: true, force: true });
  }
});

test("a run that leaves neither record nor ledger closes nothing and says why", () => {
  const runsDir = fixture();
  try {
    const closer = fakeCloser();

    const result = closeAcceptedRun(runsDir, "sandcastle/x/1", "develop", closer);

    assert.ok("problem" in result);
    assert.match(result.problem, /no run record or ledger in .* so there is no issue to close/);
    assert.deepEqual(closer.closed, [], "guessing an issue number would close the wrong issue");
  } finally {
    rmSync(join(runsDir, "..", ".."), { recursive: true, force: true });
  }
});
