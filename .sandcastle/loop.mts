// loop.mts — the host's step loop: one step per iteration, an implementer and a reviewer
// per step, every commit on the one run branch. The host owns every tracker write; the
// sandboxed agents never touch the tracker and never push.

import { copyFileSync, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { execFileSync } from "node:child_process";
import type { AgentProvider, SandboxRunOptions } from "@ai-hero/sandcastle";
import { nextStep, readSteps, tickStep, type Plan } from "./plan.mts";
import { decide, readVerdict } from "./verdict.mts";

/** Where the reviewer writes its verdict inside the worktree; the host copies it out from there. */
const VERDICT_FILE = ".sandcastle/verdict.json";

/** Prompts are harness files, resolved against the repo root the harness runs from. */
const IMPLEMENT_PROMPT = "./.sandcastle/implement-prompt.md";
const REVIEW_PROMPT = "./.sandcastle/review-prompt.md";

/** One implementer and one reviewer run per step. */
export const STAGES_PER_STEP = 2;

/** What the loop is told before it starts: the run's issue, branch and sandbox. */
export interface StepLoopOptions {
  /** The run as read from the issue before the sandbox existed. */
  plan: Plan;
  /** The one sandbox every step of this run shares. */
  sandbox: StepSandbox;
  /** The host's tracker writes: a step tick, and the re-read that follows it. */
  tracker: Tracker;
  /** The agent both roles run as. */
  agent: AgentProvider;
  /** Directory this run's verdicts, log and tick record are kept in, so accept and drop still have them. */
  runsDir: string;
}

/**
 * The tracker writes a run may make. Injecting them keeps the loop testable and keeps the
 * sandboxed agents out of the tracker entirely: they never see this object.
 */
export interface Tracker {
  /** The issue as it stands now; the body the loop works from changes as steps are ticked. */
  read(issue: number): { title: string; body: string };
  /** Replace the issue's body — the only way a step gets its tick. */
  writeBody(issue: number, body: string): void;
}

/** The part of a sandbox the loop uses; the real `Sandbox` from sandcastle satisfies it. */
export interface StepSandbox {
  /** The one branch every step of this run commits to. */
  readonly branch: string;
  /** Host path of the worktree, where the reviewer leaves its verdict. */
  readonly worktreePath: string;
  /** Run one agent session and report the commits it made. */
  run(options: SandboxRunOptions): Promise<{ commits: readonly { sha: string }[] }>;
}

/**
 * The real tracker: `gh` as the host's logged-in user.
 *
 * A body file rather than `--body` keeps the argument list short and the shell out of the
 * write; the temporary file is removed whether or not `gh` succeeds.
 */
export function ghTracker(): Tracker {
  return {
    read: (issue) => {
      const raw = execFileSync("gh", ["issue", "view", String(issue), "--json", "title,body"], { encoding: "utf8" });
      return JSON.parse(raw) as { title: string; body: string };
    },
    writeBody: (issue, body) => {
      const file = join(tmpdir(), `sandcastle-issue-${issue}.md`);
      writeFileSync(file, body);
      try {
        execFileSync("gh", ["issue", "edit", String(issue), "--body-file", file], { encoding: "utf8" });
      } finally {
        rmSync(file, { force: true });
      }
    },
  };
}

/**
 * Run the issue's steps, one per iteration, until every step is ticked or a step stops the run.
 *
 * Each iteration starts a fresh agent session, so no step inherits the previous step's
 * context. A step that fails, proves nothing, drifts, or endangers an acceptance criterion
 * stops the loop with the branch left for accept or drop; nothing later may build on it.
 * Returns the process exit code: 0 when every step is ticked, 1 when the loop stopped.
 */
export async function runSteps(options: StepLoopOptions): Promise<number> {
  const { plan, sandbox, tracker, agent, runsDir } = options;
  mkdirSync(runsDir, { recursive: true });

  console.log(`[run] ${plan.branch} on step loop for the issue in ${runsDir}`);

  const stop = (reason: string): number => {
    console.log(`[stop] ${reason}`);
    return 1;
  };

  for (let iteration = 1; iteration <= plan.maxSteps; iteration++) {
    const issue = tracker.read(plan.issue);
    const { steps, refusal } = readSteps(issue.body);
    if (refusal !== null) return stop("the issue body no longer holds checkbox steps");

    const step = nextStep(steps);
    if (step === null) {
      // The steps are done; the whole-branch review that follows them is its own cycle.
      console.log(`[steps] every step is ticked; the final whole-branch review is not implemented yet`);
      return 0;
    }

    const stage = `step ${step.position}/${steps.length}`;
    // Sandcastle reserves SOURCE_BRANCH (the run branch, which the prompt reads directly) and
    // TARGET_BRANCH (the host's current branch, which the harness must not depend on). The run's
    // own base travels under its own name, so the review diff range is the branch it was cut from.
    const promptArgs = {
      ISSUE: plan.issue,
      STEP: step.position,
      STEPS_TOTAL: steps.length,
      STEP_TITLE: step.title,
      BASE_BRANCH: plan.targetBranch,
    };

    console.log(`[${stage}] implementer…`);
    const implement = await sandbox.run({
      name: `implementer-${stage.replace(" ", "-").replace("/", "of")}`,
      maxIterations: 1,
      agent,
      promptFile: IMPLEMENT_PROMPT,
      promptArgs,
    });
    if (implement.commits.length === 0) return stop(`the implementer committed nothing for ${stage}`);
    if (implement.commits.length > 1) {
      return stop(`the implementer made ${implement.commits.length} commits for ${stage}; a step is one commit`);
    }

    console.log(`[${stage}] reviewer…`);
    const review = await sandbox.run({
      name: `reviewer-${stage.replace(" ", "-").replace("/", "of")}`,
      maxIterations: 1,
      agent,
      promptFile: REVIEW_PROMPT,
      promptArgs,
    });
    if (review.commits.length > 0) return stop(`the reviewer committed to ${plan.branch}; a review may not write`);

    const verdictPath = join(sandbox.worktreePath, VERDICT_FILE);
    if (!existsSync(verdictPath)) return stop(`the reviewer wrote no ${VERDICT_FILE} for ${stage}`);
    const keptVerdict = join(runsDir, `step-${step.position}-verdict.json`);
    copyFileSync(verdictPath, keptVerdict);

    const read = readVerdict(readFileSync(keptVerdict, "utf8"));
    if ("problem" in read) return stop(read.problem);

    const decision = decide(read.verdict, step.position);
    if (decision.kind === "stop") return stop(decision.reason);

    // The tick is the host's write: the worker never edits the tracker, so a drop can undo
    // exactly the marks this run made.
    const ticked = tickStep(issue.body, decision.step);
    if (ticked === null) return stop(`step ${decision.step} has no checkbox the host could tick`);
    tracker.writeBody(plan.issue, ticked);
    const after = nextStep(readSteps(tracker.read(plan.issue).body).steps);
    if (after !== null && after.position === step.position) return stop("the step tick did not take on the issue");
    console.log(`[${stage}] ticked`);
  }

  return stop(`the loop reached MAX_STEPS (${plan.maxSteps}) with steps still unticked`);
}
