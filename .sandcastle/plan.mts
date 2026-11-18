// plan.mts — what the host reads before a run: the issue's `## Steps`, which step is
// next, and the shape of the run (branch, iteration bound). Pure functions only: no
// git, no network, no sandbox, so the loop's decisions are testable without an agent.
// Project facts (the readiness label) arrive as a `ProjectConfig`, never as literals.
//
// A step is a `- [ ]` checkbox and nothing else. The host ticks a step by editing the
// issue body, so a checkbox is the only shape it can tick without rewriting the author's
// words; an issue that numbers its steps or heads them is refused, not reshaped.
//
// The same read covers the issue's `## Parity window`: which steps run the gate with the
// cross-arm parity check off. The shape is pinned in the harness manual.

import type { ProjectConfig } from "./project_config.mts";

/** One step of an issue's `## Steps` section, in body order. */
export interface Step {
  /** 1-based position; also the loop's iteration number. */
  position: number;
  /** The step's checkbox text, as written in the issue body. */
  title: string;
  /** Whether the issue body already marks this step done. */
  ticked: boolean;
  /**
   * The sub-issue this step stands for, when the step's checkbox names one by issue number.
   * `null` means the step is the issue's own work, which is the single multi-step shape.
   */
  child: number | null;
}

/**
 * The steps of this issue during which the gate runs with the cross-arm parity check off.
 *
 * Parity compares the front ends against each other, so a contract change cannot be green one arm
 * at a time; a window is the declared, expiring way to land the arms without it.
 */
export interface ParityWindow {
  /** The issue the window belongs to; the tracker must report it open before the window is used. */
  issue: number;
  /** The issue steps the window covers, ascending, each of them a step the issue has. */
  steps: number[];
}

/** Why an issue cannot be run as a stepped run. */
export type Refusal =
  | { kind: "no-steps-section" }
  | { kind: "not-checkboxes"; shape: string }
  /** The issue does not carry the readiness label; `readyLabel` is the one the project's tracker uses. */
  | { kind: "not-ready"; labels: string[]; readyLabel: string }
  /** The `## Parity window` cannot be read; `detail` says which part, so the fix is named, not implied. */
  | { kind: "parity-window-malformed"; detail: string }
  /** The window names no issue to hang the window on, so nothing would ever close it. */
  | { kind: "parity-window-unnamed" }
  /** The window covers a step past the issue's last one; `steps` is how many the issue has. */
  | { kind: "parity-window-step"; step: number; steps: number }
  /** The window names an issue the tracker does not report open, so the window has no owner left. */
  | { kind: "parity-window-not-open"; issue: number };

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
  /**
   * The parity window the issue declares, or `null` when the gate runs every check.
   *
   * The steps it covers run the gate with the cross-arm parity check off; every other step and the
   * whole-branch review run plain, which is what proves parity is back on.
   */
  parity: ParityWindow | null;
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
/** The heading that opens the acceptance criteria: judged once, by the whole-branch reviewer. */
const CRITERIA_HEADING = /^##\s+acceptance criteria\s*$/i;
/** The next level-2 heading closes the section, so acceptance criteria are never read as steps. */
const NEXT_SECTION = /^##\s+\S/;
/** A step whose text names a sub-issue: that child is the step, and carries its own criteria. */
const CHILD_REFERENCE = /(?:^|\s)#(\d+)\b/;

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
  return sectionUnder(body, STEP_HEADING);
}

/** The lines under the first level-2 heading matching `heading`; the next `##` closes it. */
function sectionUnder(body: string, heading: RegExp): string[] | null {
  const lines = body.split("\n");
  const start = lines.findIndex((line) => heading.test(line));
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
      const title = checkbox[2].trim();
      const child = CHILD_REFERENCE.exec(title);
      steps.push({
        position: steps.length + 1,
        title,
        ticked: checkbox[1] !== " ",
        child: child === null ? null : Number(child[1]),
      });
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

/** One acceptance criterion the host may tick, as the issue body words it. */
export interface Criterion {
  /** 1-based position among the issue's criteria, in body order. */
  position: number;
  /** The criterion's text, without its checkbox. */
  text: string;
  /** Whether the issue already marks it done. */
  ticked: boolean;
}

/**
 * Read the acceptance criteria out of an issue body.
 *
 * Only checkbox items under `## Acceptance criteria` count. They are judged once by the
 * whole-branch reviewer and ticked by the host on its evidence, never per step.
 */
export function readCriteria(body: string): Criterion[] {
  const section = sectionUnder(body, CRITERIA_HEADING);
  if (section === null) return [];

  const criteria: Criterion[] = [];
  for (let at = 0; at < section.length; at += 1) {
    const checkbox = CHECKBOX_ITEM.exec(section[at]!);
    if (checkbox === null) continue;
    // A criterion wraps like prose; its indented continuation lines are the same sentence.
    const parts = [checkbox[2].trim()];
    while (at + 1 < section.length) {
      const next = section[at + 1]!;
      if (next.trim().length === 0 || CHECKBOX_ITEM.test(next) || !/^\s+\S/u.test(next)) break;
      parts.push(next.trim());
      at += 1;
    }
    criteria.push({ position: criteria.length + 1, text: parts.join(" "), ticked: checkbox[1] !== " " });
  }
  return criteria;
}

/** Tick one acceptance criterion by position; `null` when the position is not a criterion. */
export function tickCriterion(body: string, position: number): string | null {
  return flipMarkUnder(body, CRITERIA_HEADING, position, "[ ]", "[x]");
}

/** Take one acceptance criterion's mark back out; `null` when the position is not a criterion. */
export function untickCriterion(body: string, position: number): string | null {
  return flipMarkUnder(body, CRITERIA_HEADING, position, "[x]", "[ ]");
}

/**
 * Write a step's done mark into an issue body.
 *
 * Only the one step line changes, from `- [ ]` to `- [x]`; every other byte is left as the
 * author wrote it, so `untickStep` can flip the same line back. Returns `null` when the
 * position is not a checkbox step, which means there is nothing the host may tick.
 */
export function tickStep(body: string, position: number): string | null {
  return flipStepMark(body, position, "[ ]", "[x]");
}

/**
 * Take a step's done mark back out of an issue body.
 *
 * The symmetric half of `tickStep`: only the one step line changes, from `- [x]` to `- [ ]`,
 * so a drop rewrites exactly the bytes the run wrote. Returns `null` when the position is not
 * a checkbox step.
 */
export function untickStep(body: string, position: number): string | null {
  return flipStepMark(body, position, "[x]", "[ ]");
}

/** Replace one checkbox item's mark under `heading`; `null` when the position is not one. */
function flipMarkUnder(body: string, heading: RegExp, position: number, from: string, to: string): string | null {
  const lines = body.split("\n");
  const start = lines.findIndex((line) => heading.test(line));
  if (start === -1) return null;

  // Walk the section the same way the reader does, so position means the same item in both.
  let seen = 0;
  for (let index = start + 1; index < lines.length; index++) {
    const line = lines[index];
    if (NEXT_SECTION.test(line)) break;
    if (!CHECKBOX_ITEM.test(line)) continue;
    seen++;
    if (seen !== position) continue;
    lines[index] = line.replace(from, to);
    return lines.join("\n");
  }
  return null;
}

/** Replace one checkbox step's mark; `null` when the position is not a checkbox step. */
function flipStepMark(body: string, position: number, from: string, to: string): string | null {
  return flipMarkUnder(body, STEP_HEADING, position, from, to);
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

/**
 * Why an issue may not be run yet, or `null` when it carries the readiness label.
 *
 * `--issue N` names the work; the label says whether triage has cleared it. A run refuses an
 * issue wearing another role (`needs-triage`, `needs-info`, `ready-for-human`, `wontfix`),
 * naming the labels it does carry, rather than stepping work nobody has finished specifying.
 * `readyLabel` is the label the project's tracker uses for "specified enough to step".
 */
export function readinessRefusal(labels: string[], readyLabel: string): Refusal | null {
  if (labels.includes(readyLabel)) return null;
  return { kind: "not-ready", labels, readyLabel };
}

/** The heading a parity window is declared under. */
const PARITY_HEADING = /^##\s+parity window\s*$/iu;
/** The line that opens a window: `off for steps <first>–<last>`, or one step on its own. */
const WINDOW_OFF = /^off\s+for\s+steps\b/iu;
/** That line's range; the ends are joined by an en dash, a hyphen or an em dash. */
const WINDOW_RANGE = /^off\s+for\s+steps\s+(\d+)(?:\s*[-–—]\s*(\d+))?/iu;
/** The issue the window belongs to, written `#N` somewhere inside the section. */
const WINDOW_ISSUE = /#(\d+)\b/u;
/** A window whose work is done, said on the section's first line instead of deleting it. */
const WINDOW_CLOSED = /^closed\b/iu;
/** A fenced block's fence; what it holds is an example, never a declaration. */
const FENCE = /^\s*(?:```|~~~)/u;

/**
 * The body with every fenced code block's lines dropped.
 *
 * Issues document the window's shape inside a fence. Reading that example as a declaration would
 * give a window to every issue that writes the shape down, so fences are read as prose, not syntax.
 */
function withoutFences(body: string): string {
  let fenced = false;
  const kept: string[] = [];
  for (const line of body.split("\n")) {
    if (FENCE.test(line)) {
      fenced = !fenced;
      continue;
    }
    if (!fenced) kept.push(line);
  }
  return kept.join("\n");
}

/**
 * Read the issue's `## Parity window`, or `null` when it declares none.
 *
 * The window decides whether the gate runs a check, so it is refused rather than guessed at: a
 * section with no readable range, one covering a step the issue does not have, and one naming no
 * issue all stop the run before an agent starts. Whether that issue is open is the tracker's
 * answer, asked once by the entry; the parser only carries the number.
 *
 * Returns the window, or `null` with the reason it cannot be used.
 */
export function readParityWindow(
  body: string,
  stepCount: number,
): { parity: ParityWindow | null; refusal: Refusal | null } {
  const section = sectionUnder(withoutFences(body), PARITY_HEADING);
  if (section === null) return { parity: null, refusal: null };

  const lines = section.map((line) => line.trim()).filter((line) => line.length > 0);
  // A closed window is history: the section stays for the reader, and the gate runs every check.
  if (lines.length > 0 && WINDOW_CLOSED.test(lines[0]!)) return { parity: null, refusal: null };

  const off = lines.find((line) => WINDOW_OFF.test(line));
  if (off === undefined) {
    return {
      parity: null,
      refusal: { kind: "parity-window-malformed", detail: "it has no `off for steps <first>–<last>` line" },
    };
  }

  const range = WINDOW_RANGE.exec(off);
  if (range === null) {
    return { parity: null, refusal: { kind: "parity-window-malformed", detail: `\`${off}\` is not a step range` } };
  }
  const from = Number(range[1]);
  const to = range[2] === undefined ? from : Number(range[2]);
  if (to < from) {
    return { parity: null, refusal: { kind: "parity-window-malformed", detail: `\`${off}\` runs backwards` } };
  }

  // The issue is what makes a window expire: it names whose steps these are, and the entry asks the
  // tracker whether it is still open before any step runs with parity off.
  const issue = WINDOW_ISSUE.exec(lines.join("\n"));
  if (issue === null) return { parity: null, refusal: { kind: "parity-window-unnamed" } };
  if (to > stepCount) {
    return { parity: null, refusal: { kind: "parity-window-step", step: to, steps: stepCount } };
  }

  const steps: number[] = [];
  for (let at = from; at <= to; at++) steps.push(at);
  return { parity: { issue: Number(issue[1]), steps }, refusal: null };
}

/**
 * Why a declared window may not be used, given what the tracker says about its issue.
 *
 * The parser cannot open an issue, so the entry asks the tracker once and hands the answer here;
 * the refusal is decided in one place, and a window on an issue that is no longer open stops the run.
 */
export function windowStateRefusal(issue: number, open: boolean): Refusal | null {
  return open ? null : { kind: "parity-window-not-open", issue };
}


/** How the run would be aimed at one issue, resolved from the issue and the run's stamp. */
export function makePlan(
  issue: number,
  title: string,
  body: string,
  options: { stamp: number; targetBranch: string; labels: string[]; project: ProjectConfig },
): Plan {
  const { steps, refusal: stepsRefusal } = readSteps(body);
  // A window is checked against the steps it covers, so it is read only once they are readable.
  const window = stepsRefusal === null ? readParityWindow(body, steps.length) : { parity: null, refusal: null };
  // Readiness comes first: an issue triage has not cleared is not a run's work, whatever its steps.
  const refusal = readinessRefusal(options.labels, options.project.tracker.readyLabel) ?? stepsRefusal ?? window.refusal;
  // A resumed run pays only for the steps still unticked; the done ones are history.
  const remaining = steps.filter((step) => !step.ticked).length;
  return {
    issue,
    title,
    steps: refusal === null ? steps : [],
    next: refusal === null ? nextStep(steps) : null,
    parity: refusal === null ? window.parity : null,
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

/** A window's steps as the plan prints them: a range, or the one step a collapsed range covers. */
function windowRange(window: ParityWindow): string {
  const first = window.steps[0]!;
  const last = window.steps[window.steps.length - 1]!;
  return first === last ? `step ${first}` : `steps ${first}–${last}`;
}

/**
 * Why the run will not start, in words that name what to change.
 *
 * Returned as text rather than logged here: the entry prints it, and an issue refused by the
 * tracker's answer (a window on a closed issue) is worded by this same function.
 */
export function refusalText(refusal: Refusal): string {
  if (refusal.kind === "not-ready") {
    const carried = refusal.labels.length === 0 ? "no labels at all" : refusal.labels.join(", ");
    return `the issue does not carry \`${refusal.readyLabel}\` (it has: ${carried}), so triage has not cleared it for a run`;
  }

  if (refusal.kind === "no-steps-section") {
    return "the issue body has no `## Steps` section, so there is nothing to step";
  }

  if (refusal.kind === "parity-window-malformed") {
    return (
      `the \`## Parity window\` cannot be read: ${refusal.detail}; ` +
      "write it as `off for steps <first>–<last> (#<issue>)`"
    );
  }

  if (refusal.kind === "parity-window-unnamed") {
    return "the `## Parity window` names no issue; write the issue it belongs to as `(#N)`, or delete the section";
  }

  if (refusal.kind === "parity-window-step") {
    return (
      `the \`## Parity window\` names step ${refusal.step}, but the issue has ${refusal.steps} ` +
      "steps; a window may only cover steps the issue has"
    );
  }

  if (refusal.kind === "parity-window-not-open") {
    return (
      `the \`## Parity window\` names #${refusal.issue}, which the tracker does not report open; ` +
      "parity off needs an open issue"
    );
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
    return [`${issue}`, `refused:   ${refusalText(plan.refusal)}`, `no agent is invoked by this plan`];
  }

  const done = plan.steps.filter((step) => step.ticked).length;
  const remaining = plan.steps.length - done;
  const left = `${remaining} ${remaining === 1 ? "step" : "steps"} left`;
  const next = plan.next === null ? "none left" : `${plan.next.position}. ${shorten(plan.next.title)}`;
  // The window is printed because it changes what every step's green means: which steps ran the
  // gate with a check omitted, and that the steps after it run it whole.
  const window = plan.parity === null
    ? []
    : [`window:    parity off for ${windowRange(plan.parity)} (#${plan.parity.issue})`];

  return [
    issue,
    `steps:     ${plan.steps.length} (${done} done, next ${plan.next === null ? "none" : plan.next.position})`,
    `next:      ${next}`,
    ...window,
    `branch:    ${plan.branch} (cut from ${plan.targetBranch})`,
    `MAX_STEPS: ${plan.maxSteps} (${left} + ${FINAL_REVIEW_RUNS} final review, one iteration each), up to ${plan.agentRuns} agent runs`,
    `shape:     implementer → reviewer per step, then one whole-branch review (AC matrix + standards lens)`,
    `no agent is invoked by this plan`,
  ];
}
