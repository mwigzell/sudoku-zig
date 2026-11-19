// loop.mts — the host's step loop: one step per iteration, an implementer and a reviewer
// per step, every commit on the one run branch. The host owns every tracker write; the
// sandboxed agents never touch the tracker and never push.

import { copyFileSync, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import type { AgentProvider, SandboxRunOptions } from "@ai-hero/sandcastle";
import type { ProjectConfig } from "./project_config.mts";
import { emptyLedger, ledgerPath, readLedger, recordCriterion, recordTick, writeLedger } from "./ledger.mts";
import { appendEvent, type EventKind } from "./events.mts";
import { withHeartbeat } from "./heartbeat.mts";
import { emptyTail, readNewLines, transcriptRole } from "./transcript.mts";
import { branchSearch, countShotgun } from "./shotgun.mts";
import { readReport, readRules, validateReport } from "./standards.mts";
import { readRunRecord, writeRunRecord } from "./run_record.mts";
import { gateFor, nextStep, readCriteria, readSteps, tickCriterion, tickStep, type Plan } from "./plan.mts";
import { decide, decideFinal, parityMismatch, parityRestored, readFinalVerdict, readVerdict, tickedCriteria } from "./verdict.mts";

/** A verdict left by an earlier attempt is not this run's evidence: clear it before the agent writes. */
function clearVerdict(path: string): void {
  rmSync(path, { force: true });
}

/** One implementer and one reviewer run per step. */
export const STAGES_PER_STEP = 2;

/** How often the agent's transcript is folded into the run's log while it works. */
const TRANSCRIPT_POLL_MS = 2_000;

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
  /** This project's facts: gate command, standards file, prompts, verdict paths and agent. */
  project: ProjectConfig;
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
 * Run the issue's steps, one per iteration, until every step is ticked or a step stops the run.
 *
 * Each iteration starts a fresh agent session, so no step inherits the previous step's
 * context. A step that fails, proves nothing, drifts, or endangers an acceptance criterion
 * stops the loop with the branch left for accept or drop; nothing later may build on it.
 * Returns the process exit code: 0 when every step is ticked, 1 when the loop stopped.
 */
export async function runSteps(options: StepLoopOptions): Promise<number> {
  const { plan, sandbox, tracker, agent, runsDir, project } = options;
  mkdirSync(runsDir, { recursive: true });

  // One call per transition: what a person sees on stdout is also what the run's log keeps.
  // A step event also carries its iteration as data, so a reader need not parse the message.
  const event = (kind: EventKind, message: string, step?: { at: number; of: number }): void => {
    const at = new Date().toISOString();
    appendEvent(runsDir, step === undefined ? { at, kind, message } : { at, kind, message, step });
    console.log(`[${kind}] ${message}`);
  };

  event("run", `${plan.branch} on the step loop for issue #${plan.issue}, logs in ${runsDir}`);

  const stop = (reason: string): number => {
    event("stop", reason);
    return 1;
  };

  // An agent can think for minutes without logging; the wait beats, so `status` can still tell a
  // working run from a dead one.
  //
  // The agent's own transcript is mirrored into the log while it works, so a person following the
  // run reads the reasoning in the same stream as the steps rather than in a second file.
  const waiting = <T,>(what: string, work: Promise<T>): Promise<T> => {
    const logsDir = join(runsDir, "..");
    let tail = emptyTail();
    const mirror = (): void => {
      const read = readNewLines(tail, logsDir);
      tail = read.tail;
      const role = tail.path === null ? "agent" : transcriptRole(tail.path);
      for (const line of read.lines) {
        const at = new Date().toISOString();
        appendEvent(runsDir, { at, kind: "detail", message: line, role });
      }
    };
    const timer = setInterval(mirror, TRANSCRIPT_POLL_MS);
    timer.unref();
    return withHeartbeat(what, work, (line) => event("heartbeat", line)).finally(() => {
      clearInterval(timer);
      mirror();
    });
  };

  // Every tick this run writes is recorded here, so a drop can take exactly those back.
  const ledgerFile = ledgerPath(runsDir);
  // The aim is recorded before any agent runs: a run that stops at its first step still settles.
  // A continued run keeps the moment it first started, so its directory still reads as one age.
  const earlier = readRunRecord(runsDir);
  writeRunRecord(runsDir, {
    issue: plan.issue,
    branch: plan.branch,
    targetBranch: plan.targetBranch,
    startedAt: earlier?.startedAt || new Date().toISOString(),
  });

  for (let iteration = 1; iteration <= plan.maxSteps; iteration++) {
    const issue = tracker.read(plan.issue);
    const { steps, refusal } = readSteps(issue.body);
    if (refusal !== null) return stop("the issue body no longer holds checkbox steps");

    const step = nextStep(steps);
    if (step === null) {
      // Every step is ticked, so this iteration is the whole-branch review: the run's last agent,
      // and the only place the issue's acceptance criteria are judged. It reports; it never ticks.
      return await finalReview({ plan, sandbox, tracker, agent, runsDir, project, ledgerFile }, stop, event);
    }

    const stage = `step ${step.position}/${steps.length}`;
    // The window decides this step's gate: its prompt carries the command, so the agent never
    // chooses the gate and a step after the window cannot inherit the check being off.
    const gate = gateFor(plan.parity, step.position, project);
    // Sandcastle reserves SOURCE_BRANCH (the run branch, which the prompt reads directly) and
    // TARGET_BRANCH (the host's current branch, which the harness must not depend on). The run's
    // own base travels under its own name, so the review diff range is the branch it was cut from.
    const promptArgs = {
      ISSUE: plan.issue,
      STEP: step.position,
      STEPS_TOTAL: steps.length,
      STEP_TITLE: step.title,
      BASE_BRANCH: plan.targetBranch,
      VERIFY: gate.command,
      PARITY: gate.parity,
      ...childArgs(step.child, project),
    };

    event("step", `${stage}: ${step.title}`, { at: step.position, of: steps.length });
    event("agent-start", `${stage} implementer`);
    const implement = await waiting(`${stage} implementer`, sandbox.run({
      name: `implementer-${stage.replace(" ", "-").replace("/", "of")}`,
      maxIterations: 1,
      agent,
      promptFile: project.paths.prompts.implement,
      promptArgs,
    }));
    event("agent-end", `${stage} implementer`);
    if (implement.commits.length === 0) return stop(`the implementer committed nothing for ${stage}`);
    if (implement.commits.length > 1) {
      return stop(`the implementer made ${implement.commits.length} commits for ${stage}; a step is one commit`);
    }

    const verdictPath = join(sandbox.worktreePath, project.paths.verdicts.step);
    // A resumed run reuses the worktree, and a child step writes the matrix at the same path the
    // whole-branch review uses: clear both so only this agent's write can answer for this step.
    clearVerdict(verdictPath);
    clearVerdict(join(sandbox.worktreePath, project.paths.verdicts.criteria));

    event("agent-start", `${stage} reviewer`);
    const review = await waiting(`${stage} reviewer`, sandbox.run({
      name: `reviewer-${stage.replace(" ", "-").replace("/", "of")}`,
      maxIterations: 1,
      agent,
      promptFile: project.paths.prompts.review,
      promptArgs,
    }));
    event("agent-end", `${stage} reviewer`);
    if (review.commits.length > 0) return stop(`the reviewer committed to ${plan.branch}; a review may not write`);

    if (!existsSync(verdictPath)) return stop(`the reviewer wrote no ${project.paths.verdicts.step} for ${stage}`);
    const keptVerdict = join(runsDir, `step-${step.position}-verdict.json`);
    copyFileSync(verdictPath, keptVerdict);

    const read = readVerdict(readFileSync(keptVerdict, "utf8"));
    if ("problem" in read) return stop(read.problem);

    const decision = decide(read.verdict, step.position, project);
    if (decision.kind === "stop") {
      event("verdict", `${stage}: STOP — ${decision.reason}`);
      return stop(decision.reason);
    }

    // The run gave this step a gate; a verdict that declares another one did not run it, so its
    // green is about a different check. Never keep the hole open, and never accept it a step early.
    const wrongGate = parityMismatch(read.verdict, gate.parity);
    if (wrongGate !== null) {
      event("verdict", `${stage}: STOP — ${wrongGate}`);
      return stop(wrongGate);
    }

    event("verdict", `${stage}: PASS`);

    // A sub-issue step is a whole issue: its own reviewer judged that child's criteria, and the host
    // ticks them on the child. A child with any criterion still failing is not a finished step.
    if (step.child !== null) {
      const childIssue = step.child;
      const childMatrixPath = join(sandbox.worktreePath, project.paths.verdicts.criteria);
      if (!existsSync(childMatrixPath)) {
        return stop(`step ${step.position} is sub-issue #${childIssue}, but ${project.paths.verdicts.criteria} was not written for it`);
      }
      const childRead = readFinalVerdict(readFileSync(childMatrixPath, "utf8"));
      if ("problem" in childRead) return stop(`#${childIssue}: ${childRead.problem}`);

      const childDecision = decideFinal(childRead.verdict);
      if (childDecision.kind === "stop") return stop(`#${childIssue}: ${childDecision.reason}`);

      const childBody = tracker.read(childIssue).body;
      const positions = tickedCriteria(childRead.verdict, readCriteria(childBody));
      if ("problem" in positions) return stop(`#${childIssue}: ${positions.problem}`);

      if (positions.positions.length > 0) {
        let marked = childBody;
        for (const position of positions.positions) marked = tickCriterion(marked, position) ?? marked;
        tracker.writeBody(childIssue, marked);

        const at = new Date().toISOString();
        let recorded = readLedger(ledgerFile) ?? emptyLedger(plan.issue);
        for (const position of positions.positions) recorded = recordCriterion(recorded, position, at, childIssue);
        writeLedger(ledgerFile, recorded);
        event("criterion", `ticked criteria ${positions.positions.join(", ")} on sub-issue #${childIssue}`);
      }
    }

    // The tick is the host's write: the worker never edits the tracker, so a drop can undo
    // exactly the marks this run made.
    const ticked = tickStep(issue.body, decision.step);
    if (ticked === null) return stop(`step ${decision.step} has no checkbox the host could tick`);
    tracker.writeBody(plan.issue, ticked);
    const after = nextStep(readSteps(tracker.read(plan.issue).body).steps);
    if (after !== null && after.position === step.position) return stop("the step tick did not take on the issue");

    // Only ticks that landed are recorded, so the record is exactly what a drop has to take back.
    const ledger = readLedger(ledgerFile) ?? emptyLedger(plan.issue);
    writeLedger(ledgerFile, recordTick(ledger, decision.step, new Date().toISOString()));
    event("tick", `${stage}: step ${decision.step} ticked on #${plan.issue}`);
    console.log(`[${stage}] ticked`);
  }

  return stop(`the loop reached MAX_STEPS (${plan.maxSteps}) with steps still unticked`);
}


/** What each reviewer prompt says about a child issue: nothing, for an ordinary step. */
const CHILD_SECTION = `1. **Judge the sub-issue this step stands for.** \`!\`gh issue view {{CHILD_ISSUE}} --json title,body\`\` names its acceptance criteria. Unlike the parent's, these are yours: judge every one on this branch, and mark it \`PASS\` with evidence or \`FAIL\` with none.

`;

const CHILD_OUTPUT_HEAD = `This step is sub-issue \`{{CHILD_ISSUE}}\`, so also write `;
const CHILD_OUTPUT_TAIL = ` and nothing else:

\`\`\`json
{
  "criteria": [{ "criterion": "the criterion as the issue words it", "status": "PASS", "evidence": "what you read or ran" }],
  "concerns": []
}
\`\`\`

The host ticks the criteria you mark \`PASS\` on that sub-issue, and stops the run if any is \`FAIL\`. Word each criterion as the issue words it: the host matches your matrix against the child's body.`;

/** The prompt arguments that only a sub-issue step carries, so an ordinary step is unchanged. */
function childArgs(child: number | null, project: ProjectConfig): Record<string, string | number> {
  if (child === null) return { CHILD_SECTION: "", CHILD_OUTPUT: "" };
  const file = project.paths.verdicts.criteria;
  return { CHILD_ISSUE: child, CHILD_SECTION, CHILD_OUTPUT: `${CHILD_OUTPUT_HEAD}\`${file}\`${CHILD_OUTPUT_TAIL}` };
}

/**
 * The whole-branch review: one agent reads everything the branch changed and judges the issue's own
 * acceptance criteria, which the per-step reviewers deliberately left alone. A parent whose steps are
 * sub-issues has none of its own to judge here; their reviewers judged theirs as each step passed.
 *
 * The matrix (`verdict-acs.json`) is copied out of the worktree and decided like a step verdict is: a
 * run passes only when every criterion is `PASS` with evidence. Returns the process exit code.
 */
async function finalReview(
  options: Required<Pick<StepLoopOptions, "plan" | "sandbox" | "tracker" | "agent" | "runsDir" | "project">> & { ledgerFile: string },
  stop: (reason: string) => number,
  logEvent: (kind: EventKind, message: string) => void,
): Promise<number> {
  const { plan, sandbox, tracker, agent, runsDir, project, ledgerFile } = options;

  const verdictPath = join(sandbox.worktreePath, project.paths.verdicts.criteria);
  const standardsPath = join(sandbox.worktreePath, project.paths.verdicts.standards);
  // A resumed run reuses the worktree, so an earlier attempt's files must not answer for this one.
  clearVerdict(verdictPath);
  clearVerdict(standardsPath);

  logEvent("agent-start", "final reviewer: the issue's acceptance criteria");
  const review = await withHeartbeat(
    "final reviewer",
    sandbox.run({
      name: "final-review",
      maxIterations: 1,
      agent,
      promptFile: project.paths.prompts.finalReview,
      // The whole-branch review is the integration gate, so it is always handed the gate whole:
      // a declared window is over by now, and its verdict is what proves the check is back on.
      promptArgs: {
        ISSUE: plan.issue,
        BASE_BRANCH: plan.targetBranch,
        VERIFY: project.verify,
        PARITY_LINE: project.parity.sample,
      },
    }),
    (line) => logEvent("heartbeat", line),
  );
  logEvent("agent-end", "final reviewer");
  if (review.commits.length > 0) return stop(`the whole-branch reviewer committed to ${plan.branch}; a review may not write`);

  if (!existsSync(verdictPath)) return stop(`the whole-branch reviewer wrote no ${project.paths.verdicts.criteria}`);

  const kept = join(runsDir, "verdict-acs.json");
  copyFileSync(verdictPath, kept);

  const read = readFinalVerdict(readFileSync(kept, "utf8"));
  if ("problem" in read) return stop(read.problem);

  // The review ran the gate whole, so its verdict must quote that run's parity line: a declared window
  // the review does not prove restored stops the run here, whatever its criteria matrix says.
  const unrestored = parityRestored(read.verdict, plan.parity === null ? null : plan.parity.issue, project);
  if (unrestored !== null) {
    logEvent("verdict", `whole branch: STOP — ${unrestored}`);
    return stop(unrestored);
  }

  // The standards lens is a second file with its own verdict: the reviewer answers every rule the
  // branch's own standards file carries, and a rule it skipped, invented or left unevidenced stops the run.
  if (!existsSync(standardsPath)) return stop(`the whole-branch reviewer wrote no ${project.paths.verdicts.standards}`);
  const standardsKept = join(runsDir, "verdict-standards.json");
  copyFileSync(standardsPath, standardsKept);

  const standardsRead = readReport(readFileSync(standardsKept, "utf8"));
  if ("problem" in standardsRead) return stop(standardsRead.problem);

  const rules = readRules(readFileSync(join(sandbox.worktreePath, project.standards.file), "utf8"), project);
  const checked = validateReport(standardsRead.report, rules, project);
  if ("problem" in checked) return stop(`standards: ${checked.problem}`);

  // A violation is a stop for accept or drop, exactly as a failing step is.
  for (const entry of standardsRead.report.rules) {
    logEvent("verdict", `standards ${entry.verdict}: ${entry.rule} — ${entry.evidence}`);
  }
  // The shotgun figure is the one number in the lens the host counts itself, so a reviewer cannot
  // pad it: it names the symbols, the host counts the files that carry them on this branch.
  const counts = countShotgun(standardsRead.report.shotgun, branchSearch(sandbox.worktreePath));
  if ("problem" in counts) return stop(counts.problem);
  writeFileSync(join(runsDir, "shotgun.json"), `${JSON.stringify(counts.counts, null, 2)}\n`);
  for (const count of counts.counts) {
    logEvent("verdict", `shotgun ${count.symbol}: ${count.files} file(s), ${count.verdict}`);
  }

  const violations = standardsRead.report.rules.filter((entry) => entry.verdict === "VIOLATION");
  if (violations.length > 0) {
    return stop(`standards: ${violations.map((entry) => `${entry.rule} (${entry.evidence})`).join("; ")}`);
  }

  const decision = decideFinal(read.verdict);
  for (const entry of read.verdict.criteria) {
    logEvent("verdict", `${entry.status}: ${entry.criterion}`);
  }
  for (const concern of read.verdict.concerns) logEvent("verdict", `concern: ${concern}`);

  if (decision.kind === "stop") return stop(decision.reason);

  // The matrix is matched against the issue's own criteria, so the host ticks exactly what the
  // reviewer proved and nothing it invented or skipped. Ticking is the host's write, as for a step.
  const ticked = tickedCriteria(read.verdict, readCriteria(tracker.read(plan.issue).body));
  if ("problem" in ticked) return stop(ticked.problem);
  if (ticked.positions.length > 0) {
    let body = tracker.read(plan.issue).body;
    for (const position of ticked.positions) body = tickCriterion(body, position) ?? body;
    tracker.writeBody(plan.issue, body);

    const ledger = readLedger(ledgerFile) ?? emptyLedger(plan.issue);
    let recorded = ledger;
    const at = new Date().toISOString();
    for (const position of ticked.positions) recorded = recordCriterion(recorded, position, at);
    writeLedger(ledgerFile, recorded);
    logEvent("criterion", `ticked acceptance criteria ${ticked.positions.join(", ")} on #${plan.issue}`);
  }

  logEvent("end", "every acceptance criterion passed; the issue is left open for accept or drop");
  return 0;
}
