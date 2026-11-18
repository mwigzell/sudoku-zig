// verdict.mts — the step verdict a reviewer writes after each step, and the rule that
// decides whether the loop may start the next one. The verdict carries no acceptance
// criterion status; criteria are judged once, at the end of the run. The gate command
// comes from the project's `ProjectConfig`, so a stop reason quotes this project's gate.

import type { ProjectConfig } from "./project_config.mts";

/**
 * What a step's reviewer reports. Every field is evidence the reviewer produced itself;
 * a missing or empty one is an unproven step, never a pass.
 */
export interface StepVerdict {
  /** The step this verdict judges; the loop only ticks a step the verdict names. */
  step: number;
  /** The failing test the step added, as `file: what it asserts`. */
  test_added: string;
  /** Exit code of the project's verify command (`ProjectConfig.verify`) in the reviewer's own run. */
  verify_exit: number;
  /**
   * The gate the reviewer ran, as `on` or `off (#N)`: `off (#N)` only when that gate carried this
   * project's parity-off flag for the window's issue N. The plan decides which of the two a step gets.
   */
  parity: string;
  /** The mechanical standards result, or the violation that was found. */
  standards: string;
  /** Whether the new test encodes what the issue's step text asked for. */
  on_track: boolean;
  /** Anything the next step's agent must know. */
  concerns: string[];
  /** Evidence that the step's new tests fail when its production change is reverted. */
  red_on_revert: string;
  /** Acceptance criteria this step appears to endanger, by name only. */
  ac_at_risk: string[];
  /** Whether the accumulated branch still reads like it is heading for the issue's criteria. */
  drift: boolean;
}

/** What the loop does with a step once its verdict is in. */
export type Decision =
  | { kind: "tick"; step: number }
  | { kind: "stop"; reason: string };

/** A verdict read from disk, or why it could not be read. */
export type VerdictRead = { verdict: StepVerdict } | { problem: string };

/** The value the host would find unacceptable, named with the field it came from. */
const FIELD_TYPES: ReadonlyArray<[keyof StepVerdict, "string" | "number" | "boolean" | "strings"]> = [
  ["step", "number"],
  ["test_added", "string"],
  ["verify_exit", "number"],
  ["parity", "string"],
  ["standards", "string"],
  ["on_track", "boolean"],
  ["concerns", "strings"],
  ["red_on_revert", "string"],
  ["ac_at_risk", "strings"],
  ["drift", "boolean"],
];

function holds(value: unknown, type: "string" | "number" | "boolean" | "strings"): boolean {
  if (type === "strings") return Array.isArray(value) && value.every((item) => typeof item === "string");
  return typeof value === type;
}

/** The parity a verdict may declare: the gate whole, or the gate with the check off for issue N. */
const PARITY_DECLARATION = /^(?:on|off \(#\d+\))$/u;

/**
 * Read a reviewer's verdict file.
 *
 * The shape is checked field by field rather than trusted: a verdict that cannot be read
 * stops the run, so a malformed file must be a problem and never an empty pass.
 */
export function readVerdict(raw: string): VerdictRead {
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return { problem: "the verdict file is not valid JSON" };
  }
  if (typeof parsed !== "object" || parsed === null) return { problem: "the verdict file is not a JSON object" };

  const record = parsed as Record<string, unknown>;
  for (const [field, type] of FIELD_TYPES) {
    if (!(field in record)) return { problem: `the verdict has no ${field} field` };
    if (!holds(record[field], type)) {
      return { problem: `the verdict's ${field} is not ${type === "strings" ? "a list of strings" : `a ${type}`}` };
    }
  }
  // The field says which gate the step ran, so a value the host cannot read would make its green
  // ambiguous rather than wrong: it is a problem, never a pass.
  if (!PARITY_DECLARATION.test(record.parity as string)) {
    return { problem: "the verdict's parity is not `on` or `off (#N)`" };
  }
  return { verdict: record as unknown as StepVerdict };
}

/**
 * Decide what the loop does with a step verdict.
 *
 * A step is done only when it added a test, that test is red when the step's production
 * change is reverted, the project's `verify` is green, and the reviewer is neither off track
 * nor worried that the branch is drifting. Anything else stops the run with the branch left
 * where it is, so a human reads a red step rather than the loop building on it.
 * `project` supplies the gate command the stop reason quotes, so the harness names no tool.
 */
export function decide(verdict: StepVerdict, expectedStep: number, project: ProjectConfig): Decision {
  if (verdict.step !== expectedStep) {
    return { kind: "stop", reason: `the verdict names step ${verdict.step}, not step ${expectedStep}` };
  }
  if (!verdict.on_track) return { kind: "stop", reason: "the step is not on track" };
  if (verdict.verify_exit !== 0) return { kind: "stop", reason: `${project.verify} exited ${verdict.verify_exit}` };
  if (verdict.standards !== "clean") return { kind: "stop", reason: `standards: ${verdict.standards}` };
  if (verdict.ac_at_risk.length > 0) {
    return { kind: "stop", reason: `acceptance criteria at risk: ${verdict.ac_at_risk.join(", ")}` };
  }
  if (verdict.drift) return { kind: "stop", reason: "the branch has drifted from the issue" };
  if (verdict.test_added.trim().length === 0) return { kind: "stop", reason: "the step added no test" };
  if (verdict.red_on_revert.trim().length === 0) {
    return { kind: "stop", reason: "no red-on-revert evidence for the test the step added" };
  }
  return { kind: "tick", step: verdict.step };
}

/**
 * Why a step's declared parity is not the gate the run gave it, or `null` when it is.
 *
 * The window decides which gate each step runs, so the verdict's parity is checked against it: a
 * step that ran a different gate proves something other than what the run claims, and the loop
 * stops rather than reading its green as proof. `expected` is the step's `gateFor(...).parity`.
 */
export function parityMismatch(verdict: StepVerdict, expected: string): string | null {
  if (verdict.parity === expected) return null;
  if (expected === "on") {
    return (
      `step ${verdict.step} is outside the parity window, but its reviewer ran the gate with parity ` +
      `${verdict.parity}; a step outside the window runs the gate whole`
    );
  }
  return (
    `step ${verdict.step} is inside the parity window, but its reviewer ran the gate with parity ` +
    `${verdict.parity}; a windowed step must declare ${expected}`
  );
}

// ---------------------------------------------------------------------------
// The whole-branch pass
//
// Steps are judged one at a time; the acceptance criteria are judged once, after the last
// step, by a reviewer that reads the whole branch. It reports the matrix and never ticks a
// criterion: the host ticks steps, and only a human says an issue is done.
// ---------------------------------------------------------------------------

/** One acceptance criterion as the whole-branch reviewer found it, with the evidence it read. */
export interface CriterionVerdict {
  /** The criterion, as the issue words it. */
  criterion: string;
  /** `PASS` only when the reviewer found evidence on the branch; otherwise `FAIL`. */
  status: "PASS" | "FAIL";
  /** What the reviewer read to decide: a test name, a command and its output. */
  evidence: string;
}

/** What the whole-branch reviewer reports once every step has landed. */
export interface FinalVerdict {
  /** Every acceptance criterion of the issue, in the issue's order. */
  criteria: CriterionVerdict[];
  /**
   * Whether the reviewer's own run of the plain gate reported the cross-arm parity check passing.
   * The whole-branch verdict must carry it; a sub-issue's matrix is not a gate report and need not.
   */
  parity_restored?: boolean;
  /**
   * The parity line the plain gate printed, quoted as it was. The host reads this citation against the
   * project's own shape: a verdict that quotes nothing, or something else, proves nothing about parity.
   */
  parity_line?: string;
  /** Anything a human should read before accepting the run. */
  concerns: string[];
  /** The standards verdict as the reviewer worded it, when it reports one here; the lens has its own file. */
  standards?: string;
}

/** What the host does with the whole-branch verdict. */
export type FinalDecision = { kind: "pass" } | { kind: "stop"; reason: string };

/** Read a whole-branch verdict, checked field by field so a malformed file is never a pass. */
export function readFinalVerdict(raw: string): { verdict: FinalVerdict } | { problem: string } {
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return { problem: "the verdict file is not valid JSON" };
  }
  if (typeof parsed !== "object" || parsed === null) return { problem: "the verdict file is not a JSON object" };

  const record = parsed as Record<string, unknown>;
  if (!Array.isArray(record.criteria)) return { problem: "the verdict has no criteria field" };
  for (const [at, criterion] of record.criteria.entries()) {
    const entry = criterion as Record<string, unknown>;
    if (typeof entry.criterion !== "string" || typeof entry.evidence !== "string") {
      return { problem: `the verdict's criteria[${at}] has no criterion and evidence text` };
    }
    if (entry.status !== "PASS" && entry.status !== "FAIL") {
      return { problem: `the verdict's criteria[${at}].status is not PASS or FAIL` };
    }
  }
  if (!holds(record.concerns, "strings")) return { problem: "the verdict's concerns is not a list of strings" };
  // The parity fields are the whole-branch review's proof that the check is back on, so a value the
  // host cannot read is a problem rather than a citation it might take on trust.
  if ("parity_restored" in record && typeof record.parity_restored !== "boolean") {
    return { problem: "the verdict's parity_restored is not a boolean" };
  }
  if ("parity_line" in record && typeof record.parity_line !== "string") {
    return { problem: "the verdict's parity_line is not a string" };
  }
  return { verdict: record as unknown as FinalVerdict };
}

/**
 * Decide whether a run has reached its criteria.
 *
 * A run passes only when every criterion is marked `PASS` with evidence the reviewer read. Any
 * criterion `FAIL`, or `PASS` on nothing, stops the run with the criteria named, so a human reads the
 * matrix instead of a run claiming to be done. The standards lens is judged separately, from its own report.
 */
export function decideFinal(verdict: FinalVerdict): FinalDecision {
  const failed = verdict.criteria.filter((entry) => entry.status !== "PASS");
  if (failed.length > 0) {
    return { kind: "stop", reason: `unproven: ${failed.map((entry) => entry.criterion).join("; ")}` };
  }

  // A criterion marked PASS on an empty evidence line asserts nothing, so it does not count as proof.
  const unevidenced = verdict.criteria.filter((entry) => entry.evidence.trim().length === 0);
  if (unevidenced.length > 0) {
    return { kind: "stop", reason: `no evidence: ${unevidenced.map((entry) => entry.criterion).join("; ")}` };
  }

  return { kind: "pass" };
}

/**
 * Why the branch's parity check is not proven restored, or `null` when it is.
 *
 * The whole-branch review runs the plain gate, so its verdict must quote the parity line that gate
 * printed and report the check passing. The citation is read against `project.parity.line`, and a
 * declared window that is not proven back on stops the run: the host decides, never the reviewer's
 * goodwill. `windowIssue` is the issue the plan's window belongs to, or `null` when none was declared.
 */
export function parityRestored(verdict: FinalVerdict, windowIssue: number | null, project: ProjectConfig): string | null {
  const cited = (verdict.parity_line ?? "").trim();
  if (!project.parity.line.test(cited)) {
    return cited.length === 0
      ? `the whole-branch verdict cites no gate parity line; quote the line the plain gate printed, as in \`${project.parity.sample}\``
      : `the whole-branch verdict's parity line is not the gate's: \`${cited}\`; quote the line the plain gate printed`;
  }
  if (verdict.parity_restored === true) return null;

  return windowIssue === null
    ? `the whole-branch review reported the gate's parity check not restored (\`${cited}\`)`
    : `parity off was declared for the steps of #${windowIssue}, and the whole-branch review did not prove it restored (\`${cited}\`)`;
}

/** The criteria the host may tick for a passing verdict, or why it may not. */
export type TickedCriteria = { positions: number[] } | { problem: string };

/**
 * Map a passing verdict onto the issue's own criteria list.
 *
 * The matrix is matched one for one against the issue body, so a reviewer can neither invent a
 * criterion nor silently skip the one it could not prove, and only the criteria it marked
 * `proven` — with evidence, as `decideFinal` requires — are handed back to be ticked.
 * `criteria`: the issue's criteria, in body order, as read from the tracker.
 */
export function tickedCriteria(
  verdict: FinalVerdict,
  criteria: ReadonlyArray<{ position: number; text: string; ticked: boolean }>,
): TickedCriteria {
  const byText = new Map(criteria.map((entry) => [entry.text, entry]));

  for (const entry of verdict.criteria) {
    if (!byText.has(entry.criterion)) {
      return { problem: `the verdict names a criterion the issue does not have: ${entry.criterion}` };
    }
  }

  const judged = new Set(verdict.criteria.map((entry) => entry.criterion));
  const unjudged = criteria.filter((entry) => !judged.has(entry.text));
  if (unjudged.length > 0) {
    return { problem: `the verdict left unjudged: ${unjudged.map((entry) => entry.text).join("; ")}` };
  }

  const positions = verdict.criteria
    .filter((entry) => entry.status === "PASS" && entry.evidence.trim().length > 0)
    .map((entry) => byText.get(entry.criterion)!.position)
    .filter((position) => !criteria.find((entry) => entry.position === position)?.ticked);

  return { positions };
}
