// loop.test.mts — the host's step loop, driven with a fake sandbox and an in-memory
// tracker so every transition is checked without paying for an agent.

import test from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { readEvents } from "./events.mts";
import { ledgerPath, readLedger } from "./ledger.mts";
import { runSteps, type StepSandbox } from "./loop.mts";
import { readRunRecord } from "./run_record.mts";

type SandboxAlias = StepSandbox;
import { makePlan } from "./plan.mts";
import { PROJECT } from "./project.mts";

const TWO_STEPS = `## Steps

- [ ] **Step one:** the first piece.
- [ ] **Step two:** the second piece.

## Acceptance criteria

- [ ] Something at issue level.
`;

/** A reviewer's verdict for one step, declaring the gate it ran; `parity` is `on` unless the step sits in a window. */
const passingVerdict = (step: number, parity = "on") => ({
  step,
  parity,
  test_added: `a test for step ${step}`,
  verify_exit: 0,
  standards: "clean",
  on_track: true,
  concerns: [],
  red_on_revert: "the test fails when the production change is reverted",
  ac_at_risk: [] as string[],
  drift: false,
});

/** The standards the branch's own standards file carries: two rules, so the report must answer both. */
const BRANCH_AGENTS = `## ${PROJECT.standards.section}


1. **Document public surfaces.** Every public function needs a header comment.
2. **Nothing is silent**: every caught error is logged.
`;

/** A standards report that answers the branch's rules, so the run may pass. */
const passingStandards = () => ({
  rules: [
    { rule: "Document public surfaces.", verdict: "PASS", evidence: "src/sudoku.zig:12" },
    { rule: "Nothing is silent", verdict: "PASS", evidence: "src/host/host.zig:40" },
  ],
  shotgun: [] as Array<{ symbol: string; files: number }>,
});

/** A whole-branch matrix in which the issue's one criterion passes and the plain gate's parity line is quoted. */
const passingFinal = () => ({
  criteria: [{ criterion: "Something at issue level.", status: "PASS", evidence: "a test asserts it" }],
  parity_restored: true,
  parity_line: PROJECT.parity.sample,
  concerns: [],
});

/** An in-memory tracker: the loop's own writes are observable, and nothing leaves the test. */
function fakeTracker(body: string, options: { ignoreWrites?: boolean } = {}) {
  const tracker = {
    body,
    writes: [] as string[],
    read: () => ({ title: "fixture", body: tracker.body }),
    writeBody: (_issue: number, next: string) => {
      tracker.writes.push(next);
      if (options.ignoreWrites !== true) tracker.body = next;
    },
  };
  return tracker;
}

/**
 * A sandbox that answers each role: the implementer commits, the reviewer writes the next
 * queued verdict (or nothing, when the queue holds `null`).
 */
function fakeSandbox(
  worktree: string,
  verdicts: Array<ReturnType<typeof passingVerdict> | null>,
  final: object | null = passingFinal(),
  standards: object | null = passingStandards(),
  childMatrix: object | null = null,
  implementCommits = 1,
) {
  const queued = [...verdicts];
  /** What one `run()` call was given; the loop's own prompt arguments are what the tests check. */
  type RunOptions = { name?: string; promptFile?: string; promptArgs: Record<string, string | number | boolean> };
  const runs: RunOptions[] = [];
  const sandbox = {
    branch: "sandcastle/sequential-reviewer/1",
    worktreePath: worktree,
    runs,
    run: async (options: RunOptions) => {
      runs.push(options);
      if (options.promptFile?.includes("implement") === true) {
        const commits = Array.from({ length: implementCommits }, (_unused, index) => ({ sha: `abc${index + 1}` }));
        return { commits, iterations: [], stdout: "" };
      }
      // The whole-branch review is the run's last agent: it writes its own file, naming no step.
      if (options.promptFile?.includes("final") === true) {
        const final_file = join(worktree, PROJECT.paths.verdicts.criteria);
        if (final === null) rmSync(final_file, { force: true });
        else writeFileSync(final_file, JSON.stringify(final));
        const standards_file = join(worktree, PROJECT.paths.verdicts.standards);
        if (standards === null) rmSync(standards_file, { force: true });
        else writeFileSync(standards_file, JSON.stringify(standards));
        return { commits: [], iterations: [], stdout: "" };
      }
      // A child-issue step's reviewer also adjudicates the child's own criteria, in the same file
      // shape the whole-branch review uses for the parent's.
      if (childMatrix !== null) writeFileSync(join(worktree, PROJECT.paths.verdicts.criteria), JSON.stringify(childMatrix));
      const verdict = queued.shift();
      const file = join(worktree, PROJECT.paths.verdicts.step);
      if (verdict !== null && verdict !== undefined) writeFileSync(file, JSON.stringify(verdict));
      else rmSync(file, { force: true });
      return { commits: [], iterations: [], stdout: "" };
    },
  };
  return sandbox;
}

/** Each test gets its own worktree and run directory, removed however the test ends. */
function fixture() {
  const root = mkdtempSync(join(tmpdir(), "sandcastle-loop-"));
  const worktree = join(root, "worktree");
  mkdirSync(dirname(join(worktree, PROJECT.paths.verdicts.step)), { recursive: true });
  writeFileSync(join(worktree, PROJECT.standards.file), BRANCH_AGENTS);
  return { root, worktree, runsDir: join(root, "runs") };
}

const planFor = (body: string) =>
  makePlan(1, "fixture", body, { stamp: 1, targetBranch: "develop", labels: [PROJECT.tracker.readyLabel], project: PROJECT });

/** Run one git command in a fixture worktree, so the host's branch search has a branch to read. */
function git(cwd: string, ...args: string[]): void {
  execFileSync("git", args, { cwd, stdio: "ignore" });
}

test("each step gets an implementer and a reviewer run, and the host ticks it", async () => {
  const dirs = fixture();
  try {
    const tracker = fakeTracker(TWO_STEPS);
    const sandbox = fakeSandbox(dirs.worktree, [passingVerdict(1), passingVerdict(2)]);
    const code = await runSteps({
      plan: planFor(TWO_STEPS),
      sandbox: sandbox as unknown as StepSandbox,
      tracker,
      agent: {} as never,
      runsDir: dirs.runsDir,
      project: PROJECT,
    });

    assert.equal(code, 0, "a run whose steps all stand exits green once the whole branch passes");
    assert.equal(sandbox.runs.length, 5, "two steps, two runs each, then the whole-branch review");
    assert.match(String(sandbox.runs[4]?.promptFile), /final-review-prompt/, "the last agent reads the whole branch");
    assert.ok(existsSync(join(dirs.runsDir, "verdict-acs.json")), "the whole-branch verdict is kept");
    assert.match(tracker.body, /- \[x\] \*\*Step one:\*\*/, "step one was ticked on the issue");
    assert.match(tracker.body, /- \[x\] \*\*Step two:\*\*/, "step two was ticked on the issue");
    // A step's PASS ticks the step only; the criterion waits for the whole-branch review, which ticks it.
    assert.match(tracker.body, /- \[x\] Something at issue level\./, "the passing criterion is ticked by the final pass");
    assert.ok(existsSync(join(dirs.runsDir, "step-1-verdict.json")), "the first verdict is kept");
    assert.ok(existsSync(join(dirs.runsDir, "step-2-verdict.json")), "the second verdict is kept");
    const ledger = readLedger(ledgerPath(dirs.runsDir));
    assert.deepEqual(
      ledger?.ticks.map((tick) => tick.position),
      [1, 2],
      "the ticks the host wrote are recorded in the order they landed, so a drop can take them back",
    );
    assert.deepEqual(
      ledger?.criteria.map((tick) => tick.position),
      [1],
      "a criterion the final pass proved is recorded too, so a drop takes it back as well",
    );

    // The run's log is the record of what happened, in the order it happened.
    const events = readEvents(dirs.runsDir);
    assert.deepEqual(
      [...new Set(events.map((entry) => entry.kind))],
      ["run", "step", "agent-start", "agent-end", "verdict", "tick", "criterion", "end"],
      "every transition the loop makes is one line, and no kind is missing",
    );
    assert.equal(events[0]?.kind, "run", "the log opens with the run");
    assert.equal(events.at(-1)?.kind, "end", "and closes with its own end, so finished is never a guess");
    assert.equal(
      events.filter((entry) => entry.kind === "agent-start").length,
      5,
      "an agent start per role per step, plus the whole-branch review",
    );
  } finally {
    rmSync(dirs.root, { recursive: true, force: true });
  }
});

test("a run keeps one branch, one commit per step, and pushes nothing", async () => {
  const dirs = fixture();
  try {
    const tracker = fakeTracker(TWO_STEPS);
    const sandbox = fakeSandbox(dirs.worktree, [passingVerdict(1), passingVerdict(2)]);
    const code = await runSteps({
      plan: planFor(TWO_STEPS),
      sandbox: sandbox as unknown as StepSandbox,
      tracker,
      agent: {} as never,
      runsDir: dirs.runsDir,
      project: PROJECT,
    });

    assert.equal(code, 0, "both steps stand, so the run finishes green");
    const implementers = sandbox.runs.filter((run) => run.promptFile?.includes("implement") === true);
    assert.deepEqual(
      implementers.map((run) => run.promptArgs.STEP),
      [1, 2],
      "one implementer per step, so the branch holds one commit per step",
    );
    const record = readRunRecord(dirs.runsDir);
    assert.equal(record?.branch, sandbox.branch, "every step commits to the run's one branch");
    assert.equal(record?.targetBranch, "develop", "and the record names the branch it was cut from");
    // Nothing in the harness may push: the run leaves its branch for a human to accept or drop.
    for (const file of readdirSync(dirname(new URL(import.meta.url).pathname)).filter((name) => name.endsWith(".mts"))) {
      assert.doesNotMatch(readFileSync(join(dirname(new URL(import.meta.url).pathname), file), "utf8"), /git\s+push/u, `${file} must not push`);
    }
  } finally {
    rmSync(dirs.root, { recursive: true, force: true });
  }
});

test("a step that commits twice is a stop, not two commits on the branch", async () => {
  const dirs = fixture();
  try {
    const tracker = fakeTracker(TWO_STEPS);
    const sandbox = fakeSandbox(dirs.worktree, [passingVerdict(1), passingVerdict(2)], passingFinal(), passingStandards(), null, 2);
    const code = await runSteps({
      plan: planFor(TWO_STEPS),
      sandbox: sandbox as unknown as StepSandbox,
      tracker,
      agent: {} as never,
      runsDir: dirs.runsDir,
      project: PROJECT,
    });

    assert.equal(code, 1, "the run stops rather than letting a step land twice");
    assert.doesNotMatch(tracker.body, /- \[x\] \*\*Step one:\*\*/, "the step is not ticked when its commit count is wrong");
  } finally {
    rmSync(dirs.root, { recursive: true, force: true });
  }
});

test("a branch whose criteria the whole-branch review cannot prove stops the run", async () => {
  const dirs = fixture();
  try {
    const tracker = fakeTracker(TWO_STEPS);
    const unproven = {
      criteria: [
        { criterion: "Something at issue level.", status: "FAIL", evidence: "" },
        { criterion: "Another criterion.", status: "PASS", evidence: "a test asserts it" },
      ],
      concerns: ["the second criterion rests on a test that runs only on the web path"],
    };
    const sandbox = fakeSandbox(dirs.worktree, [passingVerdict(1), passingVerdict(2)], unproven);

    const code = await runSteps({
      plan: planFor(TWO_STEPS),
      sandbox: sandbox as unknown as StepSandbox,
      tracker,
      agent: {} as never,
      runsDir: dirs.runsDir,
      project: PROJECT,
    });

    assert.equal(code, 1, "an unproven criterion leaves the run for a human");
    assert.ok(existsSync(join(dirs.runsDir, "verdict-acs.json")), "the matrix is kept for the reader");
  } finally {
    rmSync(dirs.root, { recursive: true, force: true });
  }
});

test("a whole-branch review that writes no verdict stops the run", async () => {
  const dirs = fixture();
  try {
    const sandbox = fakeSandbox(dirs.worktree, [passingVerdict(1), passingVerdict(2)], null);

    const code = await runSteps({
      plan: planFor(TWO_STEPS),
      sandbox: sandbox as unknown as StepSandbox,
      tracker: fakeTracker(TWO_STEPS),
      agent: {} as never,
      runsDir: dirs.runsDir,
      project: PROJECT,
    });

    assert.equal(code, 1, "a missing verdict is never a pass");
  } finally {
    rmSync(dirs.root, { recursive: true, force: true });
  }
});

/** A sandbox that commits for the implementer and writes no verdict, leaving files as they are. */
function silentReviewerSandbox(worktree: string) {
  return {
    branch: "sandcastle/sequential-reviewer/1",
    worktreePath: worktree,
    run: async (options: { promptFile?: string }) => ({
      commits: options.promptFile?.includes("implement") === true ? [{ sha: "abc1" }] : [],
      iterations: [],
      stdout: "",
    }),
  };
}

test("a verdict left in the worktree is cleared, so a silent reviewer cannot pass on it", async () => {
  const dirs = fixture();
  try {
    // A resumed run reuses the worktree; both files are what an earlier attempt could have left.
    writeFileSync(join(dirs.worktree, PROJECT.paths.verdicts.step), JSON.stringify(passingVerdict(1)));
    writeFileSync(join(dirs.worktree, PROJECT.paths.verdicts.criteria), JSON.stringify(passingFinal()));

    const code = await runSteps({
      plan: planFor(TWO_STEPS),
      sandbox: silentReviewerSandbox(dirs.worktree) as unknown as StepSandbox,
      tracker: fakeTracker(TWO_STEPS),
      agent: {} as never,
      runsDir: dirs.runsDir,
      project: PROJECT,
    });

    assert.equal(code, 1, "the stale files are not this step's evidence");
  } finally {
    rmSync(dirs.root, { recursive: true, force: true });
  }
});

test("a step that is not on track stops the run: nothing is ticked and no later step starts", async () => {
  const dirs = fixture();
  try {
    const tracker = fakeTracker(TWO_STEPS);
    const sandbox = fakeSandbox(dirs.worktree, [{ ...passingVerdict(1), on_track: false }, passingVerdict(2)]);
    const code = await runSteps({
      plan: planFor(TWO_STEPS),
      sandbox: sandbox as unknown as StepSandbox,
      tracker,
      agent: {} as never,
      runsDir: dirs.runsDir,
      project: PROJECT,
    });

    assert.equal(code, 1, "a stopped run exits red");
    assert.equal(tracker.writes.length, 0, "the failed step stays unticked");
    assert.equal(sandbox.runs.length, 2, "the second step never starts");
  } finally {
    rmSync(dirs.root, { recursive: true, force: true });
  }
});

test("an implementer that commits nothing is a stop, not an empty pass", async () => {
  const dirs = fixture();
  try {
    const tracker = fakeTracker(TWO_STEPS);
    const sandbox = {
      branch: "sandcastle/sequential-reviewer/1",
      worktreePath: dirs.worktree,
      runs: [] as unknown[],
      run: async (options: { promptFile?: string }) => {
        sandbox.runs.push(options);
        return { commits: [], iterations: [], stdout: "" };
      },
    };
    const code = await runSteps({
      plan: planFor(TWO_STEPS),
      sandbox: sandbox as unknown as StepSandbox,
      tracker,
      agent: {} as never,
      runsDir: dirs.runsDir,
      project: PROJECT,
    });

    assert.equal(code, 1);
    assert.equal(sandbox.runs.length, 1, "the reviewer is not asked to judge a step nobody did");
    assert.equal(tracker.writes.length, 0);
  } finally {
    rmSync(dirs.root, { recursive: true, force: true });
  }
});

test("a reviewer that writes no verdict stops the run rather than ticking on trust", async () => {
  const dirs = fixture();
  try {
    const tracker = fakeTracker(TWO_STEPS);
    const sandbox = fakeSandbox(dirs.worktree, [null]);
    const code = await runSteps({
      plan: planFor(TWO_STEPS),
      sandbox: sandbox as unknown as StepSandbox,
      tracker,
      agent: {} as never,
      runsDir: dirs.runsDir,
      project: PROJECT,
    });

    assert.equal(code, 1);
    assert.equal(tracker.writes.length, 0);
  } finally {
    rmSync(dirs.root, { recursive: true, force: true });
  }
});

test("a tick that does not take on the issue stops the run instead of repeating the step", async () => {
  const dirs = fixture();
  try {
    const tracker = fakeTracker(TWO_STEPS, { ignoreWrites: true });
    const sandbox = fakeSandbox(dirs.worktree, [passingVerdict(1), passingVerdict(1), passingVerdict(1)]);
    const code = await runSteps({
      plan: planFor(TWO_STEPS),
      sandbox: sandbox as unknown as StepSandbox,
      tracker,
      agent: {} as never,
      runsDir: dirs.runsDir,
      project: PROJECT,
    });

    assert.equal(code, 1, "a step whose tick does not land is not retried");
    assert.equal(sandbox.runs.length, 2, "the loop stops after the step it could not tick");
  } finally {
    rmSync(dirs.root, { recursive: true, force: true });
  }
});

test("the loop never passes sandcastle's reserved prompt arguments", async () => {
  const dirs = fixture();
  try {
    const sandbox = fakeSandbox(dirs.worktree, [passingVerdict(1), passingVerdict(2)]);
    await runSteps({
      plan: planFor(TWO_STEPS),
      sandbox: sandbox as unknown as StepSandbox,
      tracker: fakeTracker(TWO_STEPS),
      agent: {} as never,
      runsDir: dirs.runsDir,
      project: PROJECT,
    });

    // Sandcastle fills these itself and refuses a run that overrides them, so a step that
    // names one takes the whole run down before an agent ever starts.
    assert.equal(sandbox.runs.length, 5, "both roles ran for both steps, then the whole-branch review");
    for (const passed of sandbox.runs) {
      assert.equal("SOURCE_BRANCH" in passed.promptArgs, false, "SOURCE_BRANCH is sandcastle's to fill");
      assert.equal("TARGET_BRANCH" in passed.promptArgs, false, "TARGET_BRANCH is sandcastle's to fill");
      assert.equal(passed.promptArgs.BASE_BRANCH, "develop", "the review diffs against the run's own base");
    }
  } finally {
    rmSync(dirs.root, { recursive: true, force: true });
  }
});

test("a standards report that leaves a rule unjudged stops the run", async () => {
  const dirs = fixture();
  try {
    const tracker = fakeTracker(TWO_STEPS);
    const partial = { rules: [passingStandards().rules[0]!], shotgun: [] };
    const sandbox = fakeSandbox(dirs.worktree, [passingVerdict(1), passingVerdict(2)], passingFinal(), partial);

    const code = await runSteps({
      plan: planFor(TWO_STEPS),
      sandbox: sandbox as unknown as SandboxAlias,
      tracker,
      agent: {} as never,
      runsDir: dirs.runsDir,
      project: PROJECT,
    });

    assert.equal(code, 1, "a report against yesterday's standards list is not acceptable");
    assert.equal(tracker.writes.length, 2, "the two steps that passed stay ticked; no criterion is");
  } finally {
    rmSync(dirs.root, { recursive: true, force: true });
  }
});

test("a standards violation stops the branch for accept or drop, exactly as a failing step does", async () => {
  const dirs = fixture();
  try {
    const tracker = fakeTracker(TWO_STEPS);
    const violated = {
      rules: [
        passingStandards().rules[0]!,
        { rule: "Nothing is silent", verdict: "VIOLATION", evidence: "src/native/serve.zig:88 catches and says nothing" },
      ],
      shotgun: [],
    };
    const sandbox = fakeSandbox(dirs.worktree, [passingVerdict(1), passingVerdict(2)], passingFinal(), violated);

    const code = await runSteps({
      plan: planFor(TWO_STEPS),
      sandbox: sandbox as unknown as SandboxAlias,
      tracker,
      agent: {} as never,
      runsDir: dirs.runsDir,
      project: PROJECT,
    });

    assert.equal(code, 1);
    assert.equal(tracker.writes.length, 2, "the issue is left with its two steps ticked and no criterion ticked");
    assert.ok(existsSync(join(dirs.runsDir, "verdict-standards.json")), "the report is kept beside the matrix");
  } finally {
    rmSync(dirs.root, { recursive: true, force: true });
  }
});

test("a whole-branch review that writes no standards report stops the run", async () => {
  const dirs = fixture();
  try {
    const tracker = fakeTracker(TWO_STEPS);
    const sandbox = fakeSandbox(dirs.worktree, [passingVerdict(1), passingVerdict(2)], passingFinal(), null);

    const code = await runSteps({
      plan: planFor(TWO_STEPS),
      sandbox: sandbox as unknown as SandboxAlias,
      tracker,
      agent: {} as never,
      runsDir: dirs.runsDir,
      project: PROJECT,
    });

    assert.equal(code, 1, "the standards lens is mandatory, not optional");
  } finally {
    rmSync(dirs.root, { recursive: true, force: true });
  }
});

test("the shotgun count in the report is the host's, taken from the branch", async () => {
  const dirs = fixture();
  try {
    const tracker = fakeTracker(TWO_STEPS);
    mkdirSync(join(dirs.worktree, "src"), { recursive: true });
    writeFileSync(join(dirs.worktree, "src", "one.zig"), "fn carried() void {}\n");
    writeFileSync(join(dirs.worktree, "src", "two.zig"), "fn carried() void {}\n");
    // The host counts the branch's tracked files, so the fixture worktree is a repository.
    git(dirs.worktree, "init", "-q");
    git(dirs.worktree, "add", "src");
    const claimed = {
      ...passingStandards(),
      shotgun: [{ symbol: "carried", files: 99 }],
    };
    const sandbox = fakeSandbox(dirs.worktree, [passingVerdict(1), passingVerdict(2)], passingFinal(), claimed);

    const code = await runSteps({
      plan: planFor(TWO_STEPS),
      sandbox: sandbox as unknown as SandboxAlias,
      tracker,
      agent: {} as never,
      runsDir: dirs.runsDir,
      project: PROJECT,
    });

    assert.equal(code, 0);
    const counts = JSON.parse(readFileSync(join(dirs.runsDir, "shotgun.json"), "utf8")) as Array<{ files: number }>;
    assert.equal(counts[0]?.files, 2, "the two files that name the symbol, not the number the reviewer wrote");
  } finally {
    rmSync(dirs.root, { recursive: true, force: true });
  }
});

/** The parent issue of a shape-B run: its one step is a sub-issue, and it has no criteria of its own. */
const CHILD = 125;

const PARENT_BODY = `## Steps

- [ ] #${CHILD} the child's work
`;

/** A child issue: its own criteria are the ones its reviewer judges, and the host ticks there. */
const CHILD_BODY = `## Acceptance criteria

- [ ] The child's own criterion.
`;

/** Trackers by issue number, so a test can see which body a write landed on. */
function fakeIssues(initial: Record<number, string>) {
  const bodies = new Map(Object.entries(initial).map(([issue, body]) => [Number(issue), body]));
  const writes: Array<{ issue: number; body: string }> = [];
  return {
    bodies,
    writes,
    read: (issue: number) => ({ title: "fixture", body: bodies.get(issue) ?? "" }),
    writeBody: (issue: number, body: string) => {
      writes.push({ issue, body });
      bodies.set(issue, body);
    },
  };
}

test("a sub-issue step is judged by its own reviewer, and its criteria are ticked on the child", async () => {
  const dirs = fixture();
  try {
    const parent = planFor(PARENT_BODY);
    const tracker = fakeIssues({ [parent.issue]: PARENT_BODY, [CHILD]: CHILD_BODY });
    // The whole-branch verdict proves the gate ran whole even when every step was a sub-issue; the
    // child's own matrix is not a gate report, so it carries no parity field.
    const sandbox = fakeSandbox(
      dirs.worktree,
      [passingVerdict(1)],
      { criteria: [], parity_restored: true, parity_line: PROJECT.parity.sample, concerns: [] },
      passingStandards(),
      {
        criteria: [{ criterion: "The child's own criterion.", status: "PASS", evidence: "a test in the child's step asserts it" }],
        concerns: [],
      },
    );

    const code = await runSteps({
      plan: parent,
      sandbox: sandbox as unknown as SandboxAlias,
      tracker: tracker as never,
      agent: {} as never,
      runsDir: dirs.runsDir,
      project: PROJECT,
    });

    assert.equal(code, 0, `a child whose criteria pass leaves the run green: ${sandbox.runs.map((run) => run.name).join(",")}`);
    const review = sandbox.runs.find((run) => run.promptFile?.includes("review") === true);
    assert.equal(review?.promptArgs.CHILD_ISSUE, CHILD, "the reviewer is told which sub-issue it is judging");
    assert.ok(String(review?.promptArgs.CHILD_OUTPUT).includes(PROJECT.paths.verdicts.criteria), "and which file to write");
    assert.equal(
      sandbox.runs.some((run) => run.name === "final-review"),
      true,
      "the whole-branch review is not skipped because the steps were sub-issues",
    );
    assert.match(tracker.bodies.get(CHILD) ?? "", /- \[x\] The child's own criterion\./u, "the child's criterion is ticked on the child");
    assert.match(tracker.bodies.get(parent.issue) ?? "", new RegExp(`- \\[x\\] #${CHILD} the child's work`, "u"), "and the parent's step is ticked");

    const ledger = readLedger(ledgerPath(dirs.runsDir));
    assert.deepEqual(ledger?.criteria, [{ position: 1, at: ledger?.criteria[0]?.at, issue: CHILD }], "the ledger names the child, so a drop knows where to look");
  } finally {
    rmSync(dirs.root, { recursive: true, force: true });
  }
});

test("a parent with criteria of its own still has them judged, once, by the whole-branch review", async () => {
  const dirs = fixture();
  try {
    const parentBody = `${PARENT_BODY}\n## Acceptance criteria\n\n- [ ] The parent's own end-to-end criterion.\n`;
    const parent = planFor(parentBody);
    const tracker = fakeIssues({ [parent.issue]: parentBody, [CHILD]: CHILD_BODY });
    const sandbox = fakeSandbox(
      dirs.worktree,
      [passingVerdict(1)],
      {
        criteria: [{ criterion: "The parent's own end-to-end criterion.", status: "PASS", evidence: "an e2e test crosses both children" }],
        parity_restored: true,
        parity_line: PROJECT.parity.sample,
        concerns: [],
      },
      passingStandards(),
      {
        criteria: [{ criterion: "The child's own criterion.", status: "PASS", evidence: "the child's step test asserts it" }],
        concerns: [],
      },
    );

    const code = await runSteps({
      plan: parent,
      sandbox: sandbox as unknown as SandboxAlias,
      tracker: tracker as never,
      agent: {} as never,
      runsDir: dirs.runsDir,
      project: PROJECT,
    });

    assert.equal(code, 0);
    assert.match(tracker.bodies.get(parent.issue) ?? "", /- \[x\] The parent's own end-to-end criterion\./u);
    assert.match(tracker.bodies.get(CHILD) ?? "", /- \[x\] The child's own criterion\./u);
    const ledger = readLedger(ledgerPath(dirs.runsDir));
    assert.deepEqual(
      ledger?.criteria.map((tick) => tick.issue).sort(),
      [parent.issue, CHILD].sort(),
      "one criterion belongs to the child, one to the parent",
    );
  } finally {
    rmSync(dirs.root, { recursive: true, force: true });
  }
});

/** An issue whose first two steps migrate a cross-arm contract, and whose third is the integration gate. */
const WINDOW = 141;
const WINDOWED = `## Parity window
off for steps 1–2 (#${WINDOW})

## Steps

- [ ] **Step one:** the native arm.
- [ ] **Step two:** the web arm.
- [ ] **Step three:** the integration gate.

## Acceptance criteria

- [ ] Something at issue level.
`;

test("only the window's steps get the off gate, and the step after the window runs the plain gate", async () => {
  const dirs = fixture();
  try {
    const sandbox = fakeSandbox(dirs.worktree, [
      passingVerdict(1, `off (#${WINDOW})`),
      passingVerdict(2, `off (#${WINDOW})`),
      passingVerdict(3),
    ]);
    const plan = planFor(WINDOWED);
    assert.deepEqual(plan.parity?.steps, [1, 2], "the fixture declares a window over its first two steps");

    const code = await runSteps({
      plan,
      sandbox: sandbox as unknown as StepSandbox,
      tracker: fakeTracker(WINDOWED),
      agent: {} as never,
      runsDir: dirs.runsDir,
      project: PROJECT,
    });

    assert.equal(code, 0, "windowed verdicts that declare the gate they ran let the run finish");
    const implementers = sandbox.runs.filter((run) => run.promptFile === PROJECT.paths.prompts.implement);
    assert.deepEqual(
      implementers.map((run) => run.promptArgs.VERIFY),
      [PROJECT.verifyOff(WINDOW), PROJECT.verifyOff(WINDOW), PROJECT.verify],
      "the window's steps run the off command and the step after it runs the gate whole",
    );
    const reviewers = sandbox.runs.filter((run) => run.promptFile === PROJECT.paths.prompts.review);
    assert.deepEqual(
      reviewers.map((run) => run.promptArgs.PARITY),
      [`off (#${WINDOW})`, `off (#${WINDOW})`, "on"],
      "the reviewer is told the gate this step's verdict must declare",
    );
  } finally {
    rmSync(dirs.root, { recursive: true, force: true });
  }
});

/** A two-step issue whose window closes after the first, so step two is already the integration gate. */
const WINDOW_ONE = `## Parity window
off for steps 1 (#${WINDOW})

## Steps

- [ ] **Step one:** the migrating arm.
- [ ] **Step two:** the integration gate.
`;

test("a step outside the window that reports parity off stops the run", async () => {
  const dirs = fixture();
  try {
    const tracker = fakeTracker(WINDOW_ONE);
    const sandbox = fakeSandbox(dirs.worktree, [
      passingVerdict(1, `off (#${WINDOW})`),
      passingVerdict(2, `off (#${WINDOW})`),
    ]);
    const code = await runSteps({
      plan: planFor(WINDOW_ONE),
      sandbox: sandbox as unknown as StepSandbox,
      tracker,
      agent: {} as never,
      runsDir: dirs.runsDir,
      project: PROJECT,
    });

    assert.equal(code, 1, "the window ended, so a step that kept the hole open stops the run");
    assert.doesNotMatch(tracker.body, /- \[x\] \*\*Step two:\*\*/, "the step whose gate was wrong is not ticked");
  } finally {
    rmSync(dirs.root, { recursive: true, force: true });
  }
});

test("a step inside the window that reports parity on stops the run", async () => {
  const dirs = fixture();
  try {
    const tracker = fakeTracker(WINDOW_ONE);
    const sandbox = fakeSandbox(dirs.worktree, [passingVerdict(1), passingVerdict(2)]);
    const code = await runSteps({
      plan: planFor(WINDOW_ONE),
      sandbox: sandbox as unknown as StepSandbox,
      tracker,
      agent: {} as never,
      runsDir: dirs.runsDir,
      project: PROJECT,
    });

    assert.equal(code, 1, "a windowed step that ran the plain gate proves less than its green claims");
    assert.equal(sandbox.runs.length, 2, "the second step never starts");
    assert.doesNotMatch(tracker.body, /- \[x\]/, "no step is ticked on a gate the window did not allow");
  } finally {
    rmSync(dirs.root, { recursive: true, force: true });
  }
});

test("the whole-branch review runs the plain gate even over a window, and proves the window restored", async () => {
  const dirs = fixture();
  try {
    const sandbox = fakeSandbox(dirs.worktree, [
      passingVerdict(1, `off (#${WINDOW})`),
      passingVerdict(2, `off (#${WINDOW})`),
      passingVerdict(3),
    ]);
    const code = await runSteps({
      plan: planFor(WINDOWED),
      sandbox: sandbox as unknown as StepSandbox,
      tracker: fakeTracker(WINDOWED),
      agent: {} as never,
      runsDir: dirs.runsDir,
      project: PROJECT,
    });

    assert.equal(code, 0, "a window the review proves restored leaves the run green");
    const review = sandbox.runs.find((run) => run.name === "final-review");
    assert.equal(review?.promptArgs.VERIFY, PROJECT.verify, "the review is handed the gate whole, never the window's command");
    assert.equal(review?.promptArgs.PARITY_LINE, PROJECT.parity.sample, "and the parity line its verdict must quote");
  } finally {
    rmSync(dirs.root, { recursive: true, force: true });
  }
});

test("a declared window the whole-branch review does not prove restored stops the run", async () => {
  const dirs = fixture();
  try {
    const tracker = fakeTracker(WINDOWED);
    const sandbox = fakeSandbox(
      dirs.worktree,
      [passingVerdict(1, `off (#${WINDOW})`), passingVerdict(2, `off (#${WINDOW})`), passingVerdict(3)],
      {
        criteria: [{ criterion: "Something at issue level.", status: "PASS", evidence: "a test asserts it" }],
        parity_restored: false,
        parity_line: PROJECT.parity.sample,
        concerns: [],
      },
    );

    const code = await runSteps({
      plan: planFor(WINDOWED),
      sandbox: sandbox as unknown as StepSandbox,
      tracker,
      agent: {} as never,
      runsDir: dirs.runsDir,
      project: PROJECT,
    });

    assert.equal(code, 1, "a run that turned parity off is not finished until the review proves it back on");
    const stop = readEvents(dirs.runsDir).find((entry) => entry.kind === "stop");
    assert.match(String(stop?.message), new RegExp(`#${WINDOW}`, "u"), "the stop names the window that was left open");
    assert.doesNotMatch(tracker.body, /- \[x\] Something at issue level\./u, "no criterion is ticked on a gate claim the reviewer did not prove");
  } finally {
    rmSync(dirs.root, { recursive: true, force: true });
  }
});
