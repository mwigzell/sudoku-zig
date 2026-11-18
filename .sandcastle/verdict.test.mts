// verdict.test.mts — the step verdict the loop reads, and the rule that decides whether
// the next step may start.

import test from "node:test";
import assert from "node:assert/strict";
import { PROJECT } from "./project.mts";
import { decide, decideFinal, parityMismatch, readFinalVerdict, readVerdict, tickedCriteria, type FinalVerdict } from "./verdict.mts";

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
  parity: "on",
  drift: false,
};

/** The same verdict with one field changed, so each stop rule is exercised alone. */
const changed = (field: string, value: unknown) => ({ ...PASSING, [field]: value });
const stopOf = (verdict: unknown) => decide(verdict as typeof PASSING, 2, PROJECT);

test("a step that held up is ticked, and only the step it names", () => {
  assert.deepEqual(decide(PASSING, 2, PROJECT), { kind: "tick", step: 2 });
});

test("a verdict read from disk is the verdict the loop decides on", () => {
  const read = readVerdict(JSON.stringify(PASSING));
  assert.ok("verdict" in read);
  assert.deepEqual(decide(read.verdict, 2, PROJECT), { kind: "tick", step: 2 });
});

test("a step judged off track stops the run before the next step starts", () => {
  assert.deepEqual(stopOf(changed("on_track", false)), { kind: "stop", reason: "the step is not on track" });
});

test("a red verify stops the run and quotes the exit code, naming the project's gate", () => {
  assert.deepEqual(stopOf(changed("verify_exit", 1)), { kind: "stop", reason: `${PROJECT.verify} exited 1` });

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
  assert.deepEqual(decide(PASSING, ranStep, PROJECT), {
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

/** A window's issue, as test data: the verdict only needs the number to declare its gate. */
const WINDOW = 141;
/** The declaration a reviewer inside the window writes. */
const OFF = `off (#${WINDOW})`;

test("a step outside the parity window that declares the check off stops the run", () => {
  const reason = parityMismatch({ ...PASSING, parity: OFF }, "on");
  assert.match(String(reason), /outside the parity window/u, "the stop must say the step is past the window");
});

test("a step inside the parity window that declares parity on stops the run", () => {
  const reason = parityMismatch({ ...PASSING, parity: "on" }, OFF);
  assert.match(String(reason), /inside the parity window/u, "the stop must say the step is in the window");
});

test("a verdict whose parity is the gate the step was given passes the guard", () => {
  assert.equal(parityMismatch({ ...PASSING, parity: "on" }, "on"), null);
  assert.equal(parityMismatch({ ...PASSING, parity: OFF }, OFF), null);
});

test("a verdict must declare a parity the host can read", () => {
  assert.deepEqual(readVerdict(JSON.stringify(changed("parity", "maybe"))), {
    problem: "the verdict's parity is not `on` or `off (#N)`",
  });
  const { parity: _omitted, ...withoutParity } = PASSING;
  assert.ok("problem" in readVerdict(JSON.stringify(withoutParity)), "a verdict with no parity is a problem, not a pass");
});

/** A whole-branch verdict in which every acceptance criterion is proven. */
const FINAL_PASSING = {
  criteria: [
    { criterion: "the legend line reaches the terminal", status: "PASS", evidence: "shell e2e test asserts the footer text" },
    { criterion: "no core file imports a native adapter", status: "PASS", evidence: "src/test/layering.zig walks src/core" },
  ],
  standards: "clean",
  concerns: [],
};

test("a final pass proves every acceptance criterion and is the only way out of the run", () => {
  const read = readFinalVerdict(JSON.stringify(FINAL_PASSING));
  assert.ok("verdict" in read, JSON.stringify(read));
  assert.deepEqual(decideFinal(read.verdict), { kind: "pass" });
});

test("a criterion nobody proved stops the run, and the stop names it", () => {
  const verdict = {
    ...FINAL_PASSING,
    criteria: [
      ...FINAL_PASSING.criteria,
      { criterion: "the invariant holds for every core file", status: "FAIL", evidence: "" },
    ],
  };
  const decision = decideFinal(verdict as FinalVerdict);

  assert.equal(decision.kind, "stop");
  assert.match(decision.reason, /unproven: the invariant holds for every core file/);
});

test("a criteria list with no evidence is a problem, never an empty pass", () => {
  const evidence_free = {
    ...FINAL_PASSING,
    criteria: [{ criterion: "something", status: "PASS", evidence: "" }],
  };
  const decision = decideFinal(evidence_free as FinalVerdict);

  assert.equal(decision.kind, "stop");
  assert.match(decision.reason, /no evidence: something/);
});

test("a final verdict that cannot be read is a problem, not a pass", () => {
  assert.deepEqual(readFinalVerdict("{ not json"), { problem: "the verdict file is not valid JSON" });
  const incomplete = readFinalVerdict(JSON.stringify({ concerns: [] }));
  assert.ok("problem" in incomplete, "a verdict missing its criteria is not a pass");
  assert.deepEqual(
    readFinalVerdict(JSON.stringify({ ...FINAL_PASSING, criteria: [{ criterion: "x", status: "maybe", evidence: "y" }] })),
    { problem: "the verdict's criteria[0].status is not PASS or FAIL" },
  );
});

test("a passing verdict names criteria the issue has, one for one", () => {
  const criteria = [
    { position: 1, text: "the legend line reaches the terminal", ticked: false },
    { position: 2, text: "no core file imports a native adapter", ticked: false },
  ];
  const verdict = FINAL_PASSING as FinalVerdict;

  assert.deepEqual(tickedCriteria(verdict, criteria), { positions: [1, 2] });
});

test("a criterion the issue does not word that way is a problem, not a tick", () => {
  const criteria = [{ position: 1, text: "the legend line reaches the terminal", ticked: false }];
  const read = tickedCriteria(FINAL_PASSING as FinalVerdict, criteria);

  assert.ok("problem" in read, JSON.stringify(read));
  assert.match(read.problem, /names a criterion the issue does not have: no core file imports a native adapter/);
});

test("a criterion the reviewer left out of its matrix is a problem: none of them may be skipped", () => {
  const criteria = [
    { position: 1, text: "the legend line reaches the terminal", ticked: false },
    { position: 2, text: "no core file imports a native adapter", ticked: false },
    { position: 3, text: "an extra criterion nobody judged", ticked: false },
  ];
  const read = tickedCriteria(FINAL_PASSING as FinalVerdict, criteria);

  assert.ok("problem" in read);
  assert.match(read.problem, /left unjudged: an extra criterion nobody judged/);
});

test("only criteria the reviewer proved are ticked", () => {
  const criteria = [
    { position: 1, text: "the legend line reaches the terminal", ticked: false },
    { position: 2, text: "no core file imports a native adapter", ticked: true },
  ];
  const verdict = {
    ...FINAL_PASSING,
    criteria: [
      FINAL_PASSING.criteria[0],
      { criterion: "no core file imports a native adapter", status: "FAIL", evidence: "" },
    ],
  } as FinalVerdict;

  assert.deepEqual(tickedCriteria(verdict, criteria), { positions: [1] }, "a proven criterion already ticked is not rewritten");
});
