// drop.test.mts — what a drop took back, and that it says so per issue and per kind.

import test from "node:test";
import assert from "node:assert/strict";
import { dropReport } from "./drop.mts";
import { emptyLedger, recordCriterion, recordTick, untickRun } from "./ledger.mts";

/** The issue the run was aimed at, and one of its sub-issues. */
const PARENT = 138;
const CHILD = 139;

/** The parent as the run left it: two steps and its own criterion ticked. */
const PARENT_BODY = `## Steps

- [x] **One:** landed.
- [x] **Two:** landed.

## Acceptance criteria

- [x] The harness reports what it took back.

## Front ends
`;

/** The child's body: its acceptance criteria are the marks its reviewer judged. */
const CHILD_BODY = `## Acceptance criteria

- [x] The child's own criterion.
`;

test("a drop reports step ticks and criterion ticks separately, grouped by issue", () => {
  const ledger = recordCriterion(
    recordCriterion(recordTick(recordTick(emptyLedger(PARENT), 1, "t1"), 2, "t2"), 1, "t3"),
    1,
    "t4",
    CHILD,
  );

  assert.deepEqual(dropReport(ledger, [
    { issue: PARENT, steps: [1, 2], criteria: [1] },
    { issue: CHILD, steps: [], criteria: [1] },
  ]), [
    `[drop] took back on #${PARENT}: steps 1, 2; criteria 1`,
    `[drop] took back on #${CHILD}: criteria 1`,
  ]);
});

test("a drop that took nothing back says so instead of naming an empty list", () => {
  assert.deepEqual(dropReport(emptyLedger(PARENT), []), [`[drop] the run ticked nothing on #${PARENT}`]);
});

test("a drop puts each kind back on the issue it was written on", () => {
  const parent = fakeTracker(PARENT_BODY);
  const child = fakeTracker(CHILD_BODY);
  const ledger = recordCriterion(
    recordCriterion(recordTick(recordTick(emptyLedger(PARENT), 1, "t1"), 2, "t2"), 1, "t3"),
    1,
    "t4",
    CHILD,
  );

  const unticked = untickRun(ledger, (issue) => (issue === CHILD ? child : parent));

  assert.deepEqual(unticked, [
    { issue: PARENT, steps: [1, 2], criteria: [1] },
    { issue: CHILD, steps: [], criteria: [1] },
  ]);
  assert.doesNotMatch(parent.body, /- \[x\]/u, "the parent's steps and criterion are all put back");
  assert.match(child.body, /- \[ \] The child's own criterion\./u);
});

/** A tracker over one body, so a test can see which issue each write landed on. */
type FakeTracker = {
  body: string;
  writes: string[];
  read: () => { title: string; body: string };
  writeBody: (issue: number, next: string) => void;
};

function fakeTracker(body: string): FakeTracker {
  const tracker: FakeTracker = {
    body,
    writes: [],
    read: () => ({ title: "fixture", body: tracker.body }),
    writeBody: (_issue: number, next: string) => {
      tracker.writes.push(next);
      tracker.body = next;
    },
  };
  return tracker;
}
