import assert from "node:assert/strict";
import test from "node:test";

import { decideResume } from "./resume.mts";

/** Two issue numbers: the run a test finds standing, and the one a new aim carries. */
const STANDING = 131;
const AIMED_AT = 133;

const run = (stamp: number, issue: number | null) => ({ stamp, branch: `sandcastle/sequential-reviewer/${stamp}`, issue });

test("no unaccepted run means a fresh start", () => {
  assert.deepEqual(decideResume([], AIMED_AT), { kind: "fresh" });
});

test("the same issue continues its stopped run: same stamp, same branch, ticks kept", () => {
  const decision = decideResume([run(1794714377388, AIMED_AT)], AIMED_AT);

  assert.deepEqual(decision, {
    kind: "resume",
    stamp: 1794714377388,
    branch: "sandcastle/sequential-reviewer/1794714377388",
  });
});

test("a run aimed at another issue stops, and names both issues", () => {
  const decision = decideResume([run(1, STANDING)], AIMED_AT);

  assert.ok(decision.kind === "stop");
  assert.match(decision.reason, new RegExp(`was aimed at #${STANDING}`, "u"));
  assert.match(decision.reason, new RegExp(`aiming a run at #${AIMED_AT}`, "u"));
});

test("a run with no recorded aim stops rather than being guessed at", () => {
  const decision = decideResume([run(1, null)], AIMED_AT);

  assert.ok(decision.kind === "stop");
  assert.match(decision.reason, /left no record of the issue it was aimed at/u);
});

test("two unaccepted runs stop, since one repository holds one at a time", () => {
  const decision = decideResume([run(1, STANDING), run(2, AIMED_AT)], AIMED_AT);

  assert.ok(decision.kind === "stop");
  assert.match(decision.reason, /more than one unaccepted run remains \(sandcastle\/sequential-reviewer\/1, sandcastle\/sequential-reviewer\/2\)/u);
});
