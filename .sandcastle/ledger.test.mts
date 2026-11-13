// ledger.test.mts — the host's record of the ticks a run wrote, so a drop can take them back.

import test from "node:test";
import assert from "node:assert/strict";
import { ledgerPath, readLedger, recordCriterion, recordTick, untickRecorded, untickRun, writeLedger } from "./ledger.mts";
import { tickCriterion, tickStep } from "./plan.mts";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

/** A run's steps as the tracker holds them: two ticked, two to do. */
const BODY = `## Steps

- [x] **Step one:** landed.
- [ ] **Step two:** to do.
- [ ] **Step three:** to do.

## Front ends

- **Native:** in scope.
`;

test("the ledger records each tick on the issue it belongs to, in the order they landed", () => {
  const empty = { issue: 116, ticks: [], criteria: [] };
  const one = recordTick(empty, 2, "t1");
  const two = recordTick(one, 3, "2026-11-13T10:05:00.000Z");

  assert.deepEqual(two.ticks, [
    { position: 2, at: "t1" },
    { position: 3, at: "2026-11-13T10:05:00.000Z" },
  ]);
  assert.equal(empty.ticks.length, 0, "recording returns a new ledger and leaves the old one alone");
});

test("a ledger survives a write and a read", () => {
  const dir = mkdtempSync(join(tmpdir(), "sandcastle-ledger-"));
  try {
    const file = ledgerPath(dir);
    const ledger = recordTick({ issue: 116, ticks: [], criteria: [] }, 2, "t1");
    writeLedger(file, ledger);

    assert.deepEqual(readLedger(file), ledger);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("a run that ticked nothing has no ledger to read", () => {
  assert.equal(readLedger(join(tmpdir(), "sandcastle-absent-ticks.json")), null);
});

test("a drop takes back exactly the ticks the run recorded, byte for byte", () => {
  const afterTicks = tickStep(tickStep(BODY, 2), 3);
  const ledger = recordTick(recordTick({ issue: 116, ticks: [], criteria: [] }, 2, "a"), 3, "b");

  assert.equal(untickRecorded(afterTicks, ledger), BODY);
});

test("a drop rewrites the issue through the tracker and names the steps it took back", () => {
  const afterTicks = tickStep(tickStep(BODY, 2), 3);
  const written: string[] = [];
  const tracker = {
    read: () => ({ title: "an issue", body: afterTicks }),
    writeBody: (_issue: number, body: string) => void written.push(body),
  };
  const ledger = recordTick(recordTick({ issue: 116, ticks: [], criteria: [] }, 2, "a"), 3, "b");

  assert.deepEqual(untickRun(ledger, tracker), [2, 3]);
  assert.deepEqual(written, [BODY], "the issue is put back to the body the run started from");
});

test("a run that ticked nothing writes nothing on a drop", () => {
  let wrote = false;
  const tracker = {
    read: () => ({ title: "an issue", body: BODY }),
    writeBody: () => void (wrote = true),
  };

  assert.deepEqual(untickRun({ issue: 116, ticks: [], criteria: [] }, tracker), []);
  assert.equal(wrote, false);
});

/** A run's issue as the tracker holds it: two steps, and criteria the whole-branch review judges. */
const CRITERIA_BODY = `## Steps

- [x] **Step one:** landed.

## Acceptance criteria

- [ ] No core file imports a native adapter.
- [x] The legend line is unchanged.

## Front ends

- **Native:** in scope.
`;

test("a criterion ticked by the whole-branch review is recorded and taken back on a drop", () => {
  const body = CRITERIA_BODY;
  const ticked = tickCriterion(body, 1)!;
  const ledger = recordCriterion({ issue: 116, ticks: [], criteria: [] }, 1, "t3");

  assert.deepEqual(ledger.criteria, [{ position: 1, at: "t3" }]);
  assert.equal(ledger.ticks.length, 0, "a criterion is not a step");
  assert.equal(untickRecorded(ticked, ledger), body, "the drop puts the criterion back");
});

test("a ledger written before criteria were recorded still reads", () => {
  const dir = mkdtempSync(join(tmpdir(), "sandcastle-ledger-"));
  try {
    const file = ledgerPath(dir);
    writeFileSync(file, JSON.stringify({ issue: 116, ticks: [{ position: 2, at: "a" }] }));
    assert.deepEqual(readLedger(file), { issue: 116, ticks: [{ position: 2, at: "a" }], criteria: [] });
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
