// plan.test.mts — the host's read of `## Steps`, checked against the shapes real issues use.

import test from "node:test";
import assert from "node:assert/strict";
import { agentRuns, formatPlan, makePlan, maxSteps, nextStep, parseSteps, runBranch, tickStep } from "./plan.mts";

/** A numbered step list, as several issues write them: not tickable, so refused. */
const NUMBERED = `## Problem

Nothing.

## Steps

Each step leaves \`zig build verify\` green, committed, then stop for review.

1. **The file:** \`config.json\`, read and written generically.
   Continuation of step one.
2. **Config leaves the engine:** platforms hold Config beside the engine.

## Front ends

- **Native:** in scope.
`;

/** `### Step N:` headings with bullets, as other issues write them: also not tickable. */
const HEADINGS = `## Steps

### Step one: layout harness, red

- New \`shell_fit.test.mjs\`.

### Step two: make the shell fit, green

- \`page.html\` only.

## Acceptance criteria

- [ ] The shell fits.
`;

const CHECKBOXES = `## Steps

- [x] **Step one:** done and ticked.
- [ ] **Step two:** to do.
- [ ] **Step three:** later.

## Acceptance criteria

- [ ] An acceptance criterion is never counted as a step.
`;

/** The issue the fixtures are aimed at; the plan prints it back, so the number is test data, not a citation. */
const ISSUE = 118;

const planFor = (body: string) => makePlan(ISSUE, "One vehicle for Config", body, { stamp: 42, targetBranch: "develop" });

test("checkbox steps are read in order, and an acceptance criterion below them is not a step", () => {
  const steps = parseSteps(CHECKBOXES);
  assert.deepEqual(
    steps.map((step) => [step.position, step.ticked, step.title]),
    [
      [1, true, "**Step one:** done and ticked."],
      [2, false, "**Step two:** to do."],
      [3, false, "**Step three:** later."],
    ],
  );
  assert.equal(nextStep(steps)?.position, 2, "the first unticked step is next");
});

test("a numbered step list is refused, not rewritten", () => {
  const plan = planFor(NUMBERED);
  assert.deepEqual(plan.steps, []);
  assert.deepEqual(plan.refusal, { kind: "not-checkboxes", shape: "a numbered list" });
});

test("step headings are refused too", () => {
  const plan = planFor(HEADINGS);
  assert.deepEqual(plan.steps, []);
  assert.deepEqual(plan.refusal, { kind: "not-checkboxes", shape: "`### Step` headings" });
});

test("an issue with no ## Steps section has nothing to step", () => {
  const plan = planFor("# Sandcastle: one run per issue\n\n## Problem\n\nNothing.\n");
  assert.deepEqual(plan.steps, []);
  assert.deepEqual(plan.refusal, { kind: "no-steps-section" });
});

test("the iteration bound is one per step plus the final review; agent runs are two per step plus one", () => {
  assert.equal(maxSteps(3), 4);
  assert.equal(agentRuns(3), 7);
  assert.equal(runBranch(1794513707076), "sandcastle/sequential-reviewer/1794513707076");
});

test("the plan names the branch, the bound and the next step, and says no agent runs", () => {
  const text = formatPlan(planFor(CHECKBOXES)).join("\n");

  assert.ok(text.startsWith(`issue:     #${ISSUE} One vehicle for Config`), text);
  assert.match(text, /steps:\s+3 \(1 done, next 2\)/);
  assert.match(text, /next:\s+2\. \*\*Step two:\*\* to do\./);
  assert.match(text, /branch:\s+sandcastle\/sequential-reviewer\/42 \(cut from develop\)/);
  assert.match(text, /MAX_STEPS: 3 \(2 steps left \+ 1 final review, one iteration each\), up to 5 agent runs/);
  assert.match(text, /no agent is invoked/);
});

test("a refused issue prints the reason and no branch", () => {
  const text = formatPlan(planFor(NUMBERED)).join("\n");

  assert.match(text, /steps:\s+none — the `## Steps` section writes its steps as a numbered list/);
  assert.match(text, /the host ticks only `- \[ \]` checkboxes/);
  assert.doesNotMatch(text, /branch:/, "an issue that cannot be stepped has no branch to name");
});

test("an issue with no ## Steps section prints that nothing can be stepped", () => {
  const text = formatPlan(planFor("## Problem\n\nNothing.\n")).join("\n");
  assert.match(text, /steps:\s+none — the issue body has no `## Steps` section/);
  assert.doesNotMatch(text, /branch:/);
});

test("a plan for an issue whose steps are all ticked says none are left", () => {
  const body = `## Steps

- [x] **Step one:** done.
`;
  const text = formatPlan(planFor(body)).join("\n");
  assert.match(text, /steps:\s+1 \(1 done, next none\)/);
  assert.match(text, /next:\s+none left/);
});

/** A resumed run pays only for the steps the issue body has not ticked; done steps are history. */
test("a resumed plan bounds the unticked steps only, not the whole step list", () => {
  const body = `## Steps

- [x] **Step one:** landed.
- [x] **Step two:** landed.
- [ ] **Step three:** to do.
- [ ] **Step four:** to do.
`;
  const plan = planFor(body);

  assert.equal(plan.maxSteps, 3, "two steps left plus the final review");
  assert.equal(plan.agentRuns, 5, "two implementer and two reviewer runs, plus the final review");
  assert.match(formatPlan(plan).join("\n"), /MAX_STEPS: 3 \(2 steps left \+ 1 final review.+\)/);
});

test("a plan with nothing left to do bounds the final review alone", () => {
  const body = `## Steps

- [x] **Step one:** done.
`;
  const plan = planFor(body);

  assert.equal(plan.maxSteps, 1);
  assert.equal(plan.agentRuns, 1);
});

test("ticking a step marks only that step, leaving the rest of the body byte for byte", () => {
  const ticked = tickStep(CHECKBOXES, 2);
  assert.equal(
    ticked,
    CHECKBOXES.replace("- [ ] **Step two:** to do.", "- [x] **Step two:** to do."),
  );
  assert.equal(tickStep(CHECKBOXES, 2), ticked, "ticking a ticked step changes nothing");
});

test("a step position that is not a checkbox step has no tick to write", () => {
  assert.equal(tickStep(CHECKBOXES, 9), null);
  assert.equal(tickStep(NUMBERED, 1), null, "a numbered step cannot be ticked without rewriting it");
});
