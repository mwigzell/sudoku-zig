// run_record.test.mts — the record that lets a run be settled even when it never ticked a step.

import test from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { readRunRecord, runRecordPath, writeRunRecord } from "./run_record.mts";

const RECORD = {
  issue: 116,
  branch: "sandcastle/sequential-reviewer/1",
  targetBranch: "develop",
  startedAt: "t1",
};

test("a run's aim survives a write and a read, and makes its own directory", () => {
  const dir = mkdtempSync(join(tmpdir(), "sandcastle-run-"));
  try {
    const runsDir = join(dir, "runs", "1");
    writeRunRecord(runsDir, RECORD);

    assert.deepEqual(readRunRecord(runsDir), RECORD);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("a run directory with no record reads as none, so the caller can say so", () => {
  const dir = mkdtempSync(join(tmpdir(), "sandcastle-run-"));
  try {
    assert.equal(readRunRecord(dir), null);
    assert.equal(runRecordPath(dir).endsWith("run.json"), true);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
