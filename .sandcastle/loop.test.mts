// loop.test.mts — the host's step loop, driven with a fake sandbox and an in-memory
// tracker so every transition is checked without paying for an agent.

import test from "node:test";
import assert from "node:assert/strict";
import { existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ledgerPath, readLedger } from "./ledger.mts";
import { runSteps, type StepSandbox } from "./loop.mts";
import { makePlan } from "./plan.mts";

const TWO_STEPS = `## Steps

- [ ] **Step one:** the first piece.
- [ ] **Step two:** the second piece.

## Acceptance criteria

- [ ] Something at issue level.
`;

/** A reviewer's verdict for one step, passing unless the test says otherwise. */
const passingVerdict = (step: number) => ({
  step,
  test_added: `a test for step ${step}`,
  verify_exit: 0,
  standards: "clean",
  on_track: true,
  concerns: [],
  red_on_revert: "the test fails when the production change is reverted",
  ac_at_risk: [] as string[],
  drift: false,
});

/** A whole-branch verdict in which the issue's one criterion is proven, so the run may pass. */
const passingFinal = () => ({
  criteria: [{ criterion: "Something at issue level.", status: "proven", evidence: "a test asserts it" }],
  standards: "clean",
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
        return { commits: [{ sha: "abc123" }], iterations: [], stdout: "" };
      }
      // The whole-branch review is the run's last agent: it writes its own file, naming no step.
      if (options.promptFile?.includes("final") === true) {
        const final_file = join(worktree, ".sandcastle", "final-verdict.json");
        if (final === null) rmSync(final_file, { force: true });
        else writeFileSync(final_file, JSON.stringify(final));
        return { commits: [], iterations: [], stdout: "" };
      }
      const verdict = queued.shift();
      const file = join(worktree, ".sandcastle", "verdict.json");
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
  mkdirSync(join(worktree, ".sandcastle"), { recursive: true });
  return { root, worktree, runsDir: join(root, "runs") };
}

const planFor = (body: string) => makePlan(1, "fixture", body, { stamp: 1, targetBranch: "develop" });

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
    });

    assert.equal(code, 0, "a run whose steps all stand exits green once the whole branch passes");
    assert.equal(sandbox.runs.length, 5, "two steps, two runs each, then the whole-branch review");
    assert.match(String(sandbox.runs[4]?.promptFile), /final-review-prompt/, "the last agent reads the whole branch");
    assert.ok(existsSync(join(dirs.runsDir, "final-verdict.json")), "the whole-branch verdict is kept");
    assert.match(tracker.body, /- \[x\] \*\*Step one:\*\*/, "step one was ticked on the issue");
    assert.match(tracker.body, /- \[x\] \*\*Step two:\*\*/, "step two was ticked on the issue");
    // A step's PASS ticks the step only; the criterion waits for the whole-branch review, which ticks it.
    assert.match(tracker.body, /- \[x\] Something at issue level\./, "the proven criterion is ticked by the final pass");
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
        { criterion: "Something at issue level.", status: "unproven", evidence: "" },
        { criterion: "Another criterion.", status: "proven", evidence: "a test asserts it" },
      ],
      standards: "clean",
      concerns: ["the second criterion rests on a test that runs only on the web path"],
    };
    const sandbox = fakeSandbox(dirs.worktree, [passingVerdict(1), passingVerdict(2)], unproven);

    const code = await runSteps({
      plan: planFor(TWO_STEPS),
      sandbox: sandbox as unknown as StepSandbox,
      tracker,
      agent: {} as never,
      runsDir: dirs.runsDir,
    });

    assert.equal(code, 1, "an unproven criterion leaves the run for a human");
    assert.ok(existsSync(join(dirs.runsDir, "final-verdict.json")), "the matrix is kept for the reader");
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
    });

    assert.equal(code, 1, "a missing verdict is never a pass");
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
