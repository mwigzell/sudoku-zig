// plan.test.mts — the host's read of `## Steps`, checked against the shapes real issues use.

import test from "node:test";
import assert from "node:assert/strict";
import {
  agentRuns,
  formatPlan,
  gateFor,
  makePlan,
  maxSteps,
  nextStep,
  parseSteps,
  readCriteria,
  readSteps,
  readinessRefusal,
  runBranch,
  tickCriterion,
  tickStep,
  untickCriterion,
  windowStateRefusal,
} from "./plan.mts";
import { PROJECT } from "./project.mts";
const READY_LABEL = PROJECT.tracker.readyLabel;

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

/** Every fixture is an issue triage has cleared: the label is the readiness contract, not test data. */
const planFor = (body: string, labels: string[] = [READY_LABEL]) =>
  makePlan(ISSUE, "One vehicle for Config", body, { stamp: 42, targetBranch: "develop", labels, project: PROJECT });

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

  assert.match(text, /refused:\s+the `## Steps` section writes its steps as a numbered list/);
  assert.match(text, /the host ticks only `- \[ \]` checkboxes/);
  assert.doesNotMatch(text, /branch:/, "an issue that cannot be stepped has no branch to name");
});

test("an issue with no ## Steps section prints that nothing can be stepped", () => {
  const text = formatPlan(planFor("## Problem\n\nNothing.\n")).join("\n");
  assert.match(text, /refused:\s+the issue body has no `## Steps` section/);
  assert.doesNotMatch(text, /branch:/);
});

/** The label, not the step shape, says whether an issue is a run's work: triage owns readiness. */
test("an issue without ready-for-agent is refused, naming the labels it does carry", () => {
  const labels = ["bug", "needs-info"];
  const plan = planFor(CHECKBOXES, labels);

  assert.deepEqual(plan.refusal, { kind: "not-ready", labels, readyLabel: READY_LABEL });
  assert.deepEqual(plan.steps, [], "a refused issue gives the loop nothing to step");
  assert.equal(plan.next, null);
});

test("the labels an issue carries are only a refusal while ready-for-agent is missing", () => {
  assert.equal(readinessRefusal([READY_LABEL], READY_LABEL), null);
  assert.equal(readinessRefusal([READY_LABEL, "bug"], READY_LABEL), null, "other labels ride along");
  assert.deepEqual(
    readinessRefusal([], READY_LABEL),
    { kind: "not-ready", labels: [], readyLabel: READY_LABEL },
    "no labels means not triaged",
  );
  assert.deepEqual(readinessRefusal(["ready-for-human"], READY_LABEL), {
    kind: "not-ready",
    labels: ["ready-for-human"],
    readyLabel: READY_LABEL,
  });

});

test("a refused issue prints the readiness reason, the labels it has, and no branch", () => {
  const text = formatPlan(planFor(CHECKBOXES, ["bug", "needs-info"])).join("\n");

  assert.match(text, /refused:\s+the issue does not carry `ready-for-agent` \(it has: bug, needs-info\)/);
  assert.match(text, /no agent is invoked/);
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

/** An issue body whose acceptance criteria are the four a run must adjudicate once, at the end. */
const CRITERIA_BODY = `## Steps

- [x] **Step one:** landed.

## Acceptance criteria

- [ ] No core file imports a native adapter.
- [x] The legend line is unchanged.
- [ ] A test fails if the import returns.

## Front ends

- **Native:** in scope.
`;

test("the acceptance criteria are read from their own heading, never as steps", () => {
  assert.deepEqual(
    readCriteria(CRITERIA_BODY).map((entry) => [entry.position, entry.ticked, entry.text]),
    [
      [1, false, "No core file imports a native adapter."],
      [2, true, "The legend line is unchanged."],
      [3, false, "A test fails if the import returns."],
    ],
  );
  assert.equal(readCriteria(CRITERIA_BODY).length, 3, "the front-ends list is not a criterion list");
});

test("an issue with no acceptance criteria heading has none to tick", () => {
  assert.deepEqual(readCriteria("## Steps\n\n- [ ] **Step one:** to do.\n"), []);
});

test("a criterion that wraps is one criterion, as the issue words it", () => {
  const body = [
    "## Acceptance criteria",
    "",
    "- [ ] A refused forget leaves the player's save file on disk and the pointer naming it, on",
    "      native and on the shared host.",
    "- [ ] The next criterion.",
  ].join("\n");

  assert.deepEqual(readCriteria(body).map((entry) => entry.text), [
    "A refused forget leaves the player's save file on disk and the pointer naming it, on native and on the shared host.",
    "The next criterion.",
  ]);
  assert.equal(readCriteria(body).length, 2, "the continuation is not a criterion of its own");
});

test("a criterion is ticked and unticked by position, leaving every other byte alone", () => {
  const ticked = tickCriterion(CRITERIA_BODY, 1);
  assert.equal(ticked, CRITERIA_BODY.replace("- [ ] No core file", "- [x] No core file"));
  assert.equal(untickCriterion(ticked, 1), CRITERIA_BODY, "unticking puts the bytes back");
  assert.equal(untickCriterion(ticked, 1)?.length, CRITERIA_BODY.length);
  assert.equal(tickCriterion(CRITERIA_BODY, 9), null, "a position that is not a criterion has no tick");
});

/** A parent whose steps are sub-issues: the checkbox names the child, so the child is the step. */
const CHILD_A = 125;
const CHILD_B = 124;
const PARENT_BODY = `## Steps

- [ ] #${CHILD_A} fill pencil marks
- [ ] #${CHILD_B} check pencil marks

## Acceptance criteria

- [ ] The parent's own end-to-end criterion.
`;

test("a step that names a child issue is that child, not a task the parent describes", () => {
  const { steps } = readSteps(PARENT_BODY);

  assert.deepEqual(
    steps.map((step) => step.child),
    [CHILD_A, CHILD_B],
    "each checkbox names the sub-issue it stands for",
  );
  assert.equal(steps[0]?.title, `#${CHILD_A} fill pencil marks`, "the author's words are kept as written");
});

test("a step that names no issue is the issue's own work, so the run is a single multi-step issue", () => {
  assert.deepEqual(
    readSteps(CHECKBOXES).steps.map((step) => step.child),
    [null, null, null],
  );
});

/**
 * An issue whose first four steps change a cross-arm contract, so it declares a parity window.
 * The shape is the one the harness manual pins: a step range and the issue it belongs to.
 */
const WINDOW_BODY = `## Parity window
off for steps 1–4 (#${ISSUE}) — \`zig build verify -Dparity=off -Dparity-off-issue=${ISSUE}\`
parity is back on at the window's edge; final acceptance is plain \`zig build verify\`

## Steps

- [ ] **Step one:** the seam.
- [ ] **Step two:** the gate option.
- [ ] **Step three:** the runners.
- [ ] **Step four:** the plan.
- [ ] **Step five:** the loop.
`;

/** A five-step issue whose `## Parity window` section holds exactly `lines`. */
function windowBody(...lines: string[]): string {
  const steps = Array.from({ length: 5 }, (_, at) => `- [ ] **Step ${at + 1}:** work.`);
  return [`## Parity window`, ...lines, "", "## Steps", "", ...steps, ""].join("\n");
}

test("a step-scoped parity window is read as the issue and the steps it covers", () => {
  assert.deepEqual(planFor(WINDOW_BODY).parity, { issue: ISSUE, steps: [1, 2, 3, 4] });
});

test("a window covering one step is a one-step range, not a malformed one", () => {
  const plan = planFor(windowBody(`off for steps 3 (#${ISSUE})`));
  assert.deepEqual(plan.parity, { issue: ISSUE, steps: [3] });
});

test("an issue that declares no window runs with parity on", () => {
  assert.equal(planFor(CHECKBOXES).parity, null);
});

/** This issue's own body shows the shape inside a fence; a documented example is not a declaration. */
test("a window shown in a fenced code block is documentation, not a declaration", () => {
  const body = `An issue whose arms move together writes:

\`\`\`
## Parity window
off for steps 1–2 (#${ISSUE})
\`\`\`

## Steps

- [ ] **Step one:** to do.
- [ ] **Step two:** to do.
`;
  assert.equal(planFor(body).parity, null);
});

test("a window marked closed is no window, so a later run cannot inherit it", () => {
  const plan = planFor(windowBody(`closed — parity came back on at the window's edge`));
  assert.equal(plan.parity, null);
  assert.equal(plan.refusal, null, "a closed window does not block the run");
});

test("a window range that runs backwards is refused", () => {
  const plan = planFor(windowBody(`off for steps 4–1 (#${ISSUE})`));
  assert.equal(plan.refusal?.kind, "parity-window-malformed");
  assert.deepEqual(plan.parity, null);
  assert.match(formatPlan(plan).join("\n"), /`## Parity window` cannot be read: .* runs backwards/u);
});

test("a window range written in words is refused, naming the line it could not read", () => {
  const plan = planFor(windowBody(`off for steps one–four (#${ISSUE})`));
  assert.equal(plan.refusal?.kind, "parity-window-malformed");
  assert.match(formatPlan(plan).join("\n"), /`off for steps one–four \(#\d+\)`/u);
});

test("a window section with no step range at all is refused", () => {
  const plan = planFor(windowBody(`parity is off for the front-end arms (#${ISSUE})`));
  assert.equal(plan.refusal?.kind, "parity-window-malformed");
});

test("a window naming a step the issue does not have is refused", () => {
  const plan = planFor(windowBody(`off for steps 1–9 (#${ISSUE})`));
  assert.deepEqual(plan.refusal, { kind: "parity-window-step", step: 9, steps: 5 });
  assert.match(formatPlan(plan).join("\n"), /the `## Parity window` names step/u);
});

test("a window that names no issue is refused: a window with no expiry has an owner instead", () => {
  const plan = planFor(windowBody("off for steps 1–2"));
  assert.deepEqual(plan.refusal, { kind: "parity-window-unnamed" });
  assert.match(formatPlan(plan).join("\n"), /names no issue/u);
});

/** The tracker's answer decides whether a declared window may be used; the parser only holds the number. */
test("a window on an issue the tracker does not report open is refused", () => {
  assert.equal(windowStateRefusal(ISSUE, true), null, "an open issue may carry a window");
  assert.deepEqual(windowStateRefusal(ISSUE, false), { kind: "parity-window-not-open", issue: ISSUE });
});

test("the plan prints the window so a reader sees which steps run without parity", () => {
  const text = formatPlan(planFor(WINDOW_BODY)).join("\n");
  assert.match(text, new RegExp(`window:\\s+parity off for steps 1–4 \\(#${ISSUE}\\)`, "u"));
  assert.doesNotMatch(formatPlan(planFor(CHECKBOXES)).join("\n"), /window:/u, "no window, no line");
});

test("only the window's steps get the off command; every later step runs the plain gate", () => {
  const plan = planFor(WINDOW_BODY);
  for (const step of plan.parity!.steps) {
    assert.deepEqual(gateFor(plan.parity, step, PROJECT), {
      command: PROJECT.verifyOff(ISSUE),
      parity: `off (#${ISSUE})`,
    });
  }
  assert.deepEqual(
    gateFor(plan.parity, 5, PROJECT),
    { command: PROJECT.verify, parity: "on" },
    "the step after the window is the integration gate",
  );
  assert.deepEqual(gateFor(null, 1, PROJECT), { command: PROJECT.verify, parity: "on" }, "no window, the whole gate");
});
