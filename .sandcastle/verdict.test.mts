// verdict.test.mts — the step verdict the loop reads, and the rule that decides whether
// the next step may start.

import test from "node:test";
import assert from "node:assert/strict";
import { decide, readVerdict } from "./verdict.mts";

/** A step verdict a reviewer may write when the step held up. */
const PASSING = {
  step: 2,
  test_added: "src/core/engine/pencil.zig: marks survive a fill",
  verify_exit: 0,
  standards: "clean",
  on_track: true,
  concerns: ["the next step must not move the mask arithmetic"],
  red_on_revert: "the new test fails when the mark clear is reverted",
  ac_at_risk: [],
  drift: false,
};

/** The same verdict with one field changed, so each stop rule is exercised alone. */
const changed = (field: string, value: unknown) => ({ ...PASSING, [field]: value });
const stopOf = (verdict: unknown) => decide(verdict as typeof PASSING, 2);

test("a step that held up is ticked, and only the step it names", () => {
  assert.deepEqual(decide(PASSING, 2), { kind: "tick", step: 2 });
});

test("a verdict read from disk is the verdict the loop decides on", () => {
  const read = readVerdict(JSON.stringify(PASSING));
  assert.ok("verdict" in read);
  assert.deepEqual(decide(read.verdict, 2), { kind: "tick", step: 2 });
});

test("a step judged off track stops the run before the next step starts", () => {
  assert.deepEqual(stopOf(changed("on_track", false)), { kind: "stop", reason: "the step is not on track" });
});

test("a red verify stops the run and quotes the exit code", () => {
  assert.deepEqual(stopOf(changed("verify_exit", 1)), { kind: "stop", reason: "zig build verify exited 1" });
});

test("a standards violation stops the run", () => {
  assert.deepEqual(stopOf(changed("standards", "public symbol without a doc comment")), {
    kind: "stop",
    reason: "standards: public symbol without a doc comment",
  });
});

test("a named acceptance criterion at risk stops the run", () => {
  assert.deepEqual(stopOf(changed("ac_at_risk", ["AC 3", "AC 6"])), {
    kind: "stop",
    reason: "acceptance criteria at risk: AC 3, AC 6",
  });
});

test("drift stops the run", () => {
  assert.deepEqual(stopOf(changed("drift", true)), { kind: "stop", reason: "the branch has drifted from the issue" });
});

test("a step with no red-on-revert evidence is unproven, so it stops the run", () => {
  assert.deepEqual(stopOf(changed("red_on_revert", "")), {
    kind: "stop",
    reason: "no red-on-revert evidence for the test the step added",
  });
});

test("a step that added no test is unproven, so it stops the run", () => {
  assert.deepEqual(stopOf(changed("test_added", "")), { kind: "stop", reason: "the step added no test" });
});

test("a verdict naming another step is not trusted", () => {
  // The step the loop ran, named once so the expected reason carries no second literal.
  const ranStep = 3;
  assert.deepEqual(decide(PASSING, ranStep), {
    kind: "stop",
    reason: `the verdict names step ${PASSING.step}, not step ${ranStep}`,
  });
});

test("a verdict that cannot be read is a problem, not a pass", () => {
  assert.deepEqual(readVerdict("{ not json"), { problem: "the verdict file is not valid JSON" });
  const incomplete = readVerdict(JSON.stringify({ step: 2 }));
  assert.ok("problem" in incomplete, "a verdict missing its evidence is not read as a pass");
  assert.match(incomplete.problem, /has no .* field/, incomplete.problem);
  assert.deepEqual(
    readVerdict(JSON.stringify(changed("verify_exit", "0"))),
    { problem: "the verdict's verify_exit is not a number" },
  );
});
