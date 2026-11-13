// plan.mts — what the host reads before a run: the issue's `## Steps`, which step is
// next, and the shape of the run (branch, iteration bound). Pure functions only: no
// git, no network, no sandbox, so the loop's decisions are testable without an agent.
//
// A step is a `- [ ]` checkbox and nothing else. The host ticks a step by editing the
// issue body, so a checkbox is the only shape it can tick without rewriting the author's
// words; an issue that numbers its steps or heads them is refused, not reshaped.

/** One step of an issue's `## Steps` section, in body order. */
export interface Step {
  /** 1-based position; also the loop's iteration number. */
  position: number;
  /** The step's checkbox text, as written in the issue body. */
  title: string;
  /** Whether the issue body already marks this step done. */
  ticked: boolean;
}

/** Why an issue cannot be run as a stepped run. */
export type Refusal =
  | { kind: "no-steps-section" }
  | { kind: "not-checkboxes"; shape: string };

/** Everything the host needs about a run before it starts one. */
export interface Plan {
  /** Issue the run is aimed at. */
  issue: number;
  /** That issue's title, for a readable plan. */
  title: string;
  /** Every step found in the issue body, in order; empty when the issue is refused. */
  steps: Step[];
  /** The first step not yet ticked; `null` when the issue has none left. */
  next: Step | null;
  /** The one branch every step of this run commits to. */
  branch: string;
  /** The branch the run branch is cut from and merged back into. */
  targetBranch: string;
  /** Iteration bound: one per step plus the final review. */
  maxSteps: number;
  /** Agent runs the whole run costs at most: an implementer and a reviewer per step, plus the final review. */
  agentRuns: number;
  /** Why this issue cannot be stepped, or `null` when it can. */
  refusal: Refusal | null;
}

/** The section heading the host reads steps from. */
const STEP_HEADING = /^##\s+steps\s*$/i;
/** The next level-2 heading closes the section, so acceptance criteria are never read as steps. */
const NEXT_SECTION = /^##\s+\S/;
/** Shapes an issue may write its steps in that the host cannot tick. */
const STEP_SUBHEADING = /^###\s+step\b/i;
const NUMBERED_ITEM = /^\d+[.)]\s+/;
const CHECKBOX_ITEM = /^\s*[-*]\s+\[([ xX])\]\s+(.*)$/;

/** One implementer and one reviewer run per step. */
const RUNS_PER_STEP = 2;
/** The final whole-branch review, which every shape pays for. */
const FINAL_REVIEW_RUNS = 1;

/** The body lines inside `## Steps`, or `null` when the issue has no such section. */
function stepsSection(body: string): string[] | null {
  const lines = body.split("\n");
  const start = lines.findIndex((line) => STEP_HEADING.test(line));
  if (start === -1) return null;

  const section: string[] = [];
  for (const line of lines.slice(start + 1)) {
    if (NEXT_SECTION.test(line)) break;
    section.push(line);
  }
  return section;
}

/**
 * Read the steps out of an issue body.
 *
 * Only checkbox items inside `## Steps` count; prose above the first step is a preamble
 * and is ignored. When the issue cannot be stepped, returns no steps plus the reason.
 */
export function readSteps(body: string): { steps: Step[]; refusal: Refusal | null } {
  const section = stepsSection(body);
  if (section === null) return { steps: [], refusal: { kind: "no-steps-section" } };

  const steps: Step[] = [];
  for (const line of section) {
    const checkbox = CHECKBOX_ITEM.exec(line);
    if (checkbox) {
      steps.push({ position: steps.length + 1, title: checkbox[2].trim(), ticked: checkbox[1] !== " " });
    }
  }
  if (steps.length > 0) return { steps, refusal: null };

  // The section exists but holds nothing the host can tick; name the shape it used so
  // the report says what to change rather than only that the run will not start.
  if (section.some((line) => STEP_SUBHEADING.test(line))) {
    return { steps: [], refusal: { kind: "not-checkboxes", shape: "`### Step` headings" } };
  }
  if (section.some((line) => NUMBERED_ITEM.test(line))) {
    return { steps: [], refusal: { kind: "not-checkboxes", shape: "a numbered list" } };
  }
  return { steps: [], refusal: { kind: "not-checkboxes", shape: "prose" } };
}

/** The step list of an issue body, in body order. */
export function parseSteps(body: string): Step[] {
  return readSteps(body).steps;
}

/** The first step the issue body has not marked done; `null` when every step is done. */
export function nextStep(steps: Step[]): Step | null {
  return steps.find((step) => !step.ticked) ?? null;
}

/**
 * Write a step's done mark into an issue body.
 *
 * Only the one step line changes, from `- [ ]` to `- [x]`; every other byte is left as the
 * author wrote it, so a drop can flip the same line back. Returns `null` when the position
 * is not a checkbox step, which means there is nothing the host may tick.
 */
export function tickStep(body: string, position: number): string | null {
  const lines = body.split("\n");
  const start = lines.findIndex((line) => STEP_HEADING.test(line));
  if (start === -1) return null;

  // Walk the section the same way `readSteps` does, so position means the same step in both.
  let seen = 0;
  for (let index = start + 1; index < lines.length; index++) {
    const line = lines[index];
    if (NEXT_SECTION.test(line)) break;
    if (!CHECKBOX_ITEM.test(line)) continue;
    seen++;
    if (seen !== position) continue;
    lines[index] = line.replace("[ ]", "[x]");
    return lines.join("\n");
  }
  return null;
}

/** Iteration bound for a run: one per step plus the final review, so a box that never ticks cannot loop forever. */
export function maxSteps(stepCount: number): number {
  return stepCount + FINAL_REVIEW_RUNS;
}

/** Agent runs a run costs at most: two per step, plus the final whole-branch review. */
export function agentRuns(stepCount: number): number {
  return stepCount * RUNS_PER_STEP + FINAL_REVIEW_RUNS;
}

/** The one branch a run commits to; every step lands on it, and no step gets its own. */
export function runBranch(stamp: number): string {
  return `sandcastle/sequential-reviewer/${stamp}`;
}

/** How the run would be aimed at one issue, resolved from the issue and the run's stamp. */
export function makePlan(
  issue: number,
  title: string,
  body: string,
  options: { stamp: number; targetBranch: string },
): Plan {
  const { steps, refusal } = readSteps(body);
  // A resumed run pays only for the steps still unticked; the done ones are history.
  const remaining = steps.filter((step) => !step.ticked).length;
  return {
    issue,
    title,
    steps,
    next: nextStep(steps),
    branch: runBranch(options.stamp),
    targetBranch: options.targetBranch,
    maxSteps: maxSteps(remaining),
    agentRuns: agentRuns(remaining),
    refusal,
  };
}

/** Longest step title the plan prints before eliding; a plan is a glance, not the issue. */
const TITLE_WIDTH = 96;

function shorten(text: string): string {
  return text.length <= TITLE_WIDTH ? text : `${text.slice(0, TITLE_WIDTH - 1)}…`;
}

/** Why the run will not start, in words that name what to change. */
function refusalText(refusal: Refusal): string {
  if (refusal.kind === "no-steps-section") {
    return "the issue body has no `## Steps` section, so there is nothing to step";
  }
  return (
    `the \`## Steps\` section writes its steps as ${refusal.shape}, ` +
    "and the host ticks only `- [ ]` checkboxes; rewrite the steps as checkboxes, or run this issue by hand"
  );
}

/** The plan as lines for the terminal: what the run would do, before it costs an agent. */
export function formatPlan(plan: Plan): string[] {
  const issue = `issue:     #${plan.issue} ${shorten(plan.title)}`;

  // A refused issue has no run shape to print; the reason is the whole plan.
  if (plan.refusal !== null) {
    return [`${issue}`, `steps:     none — ${refusalText(plan.refusal)}`, `no agent is invoked by this plan`];
  }

  const done = plan.steps.filter((step) => step.ticked).length;
  const remaining = plan.steps.length - done;
  const left = `${remaining} ${remaining === 1 ? "step" : "steps"} left`;
  const next = plan.next === null ? "none left" : `${plan.next.position}. ${shorten(plan.next.title)}`;

  return [
    issue,
    `steps:     ${plan.steps.length} (${done} done, next ${plan.next === null ? "none" : plan.next.position})`,
    `next:      ${next}`,
    `branch:    ${plan.branch} (cut from ${plan.targetBranch})`,
    `MAX_STEPS: ${plan.maxSteps} (${left} + ${FINAL_REVIEW_RUNS} final review, one iteration each), up to ${plan.agentRuns} agent runs`,
    `shape:     implementer → reviewer per step, then one whole-branch review (AC matrix + standards lens)`,
    `no agent is invoked by this plan`,
  ];
}
