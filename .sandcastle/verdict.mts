// verdict.mts — the step verdict a reviewer writes after each step, and the rule that
// decides whether the loop may start the next one. The verdict carries no acceptance
// criterion status; criteria are judged once, at the end of the run.

/**
 * What a step's reviewer reports. Every field is evidence the reviewer produced itself;
 * a missing or empty one is an unproven step, never a pass.
 */
export interface StepVerdict {
  /** The step this verdict judges; the loop only ticks a step the verdict names. */
  step: number;
  /** The failing test the step added, as `file: what it asserts`. */
  test_added: string;
  /** Exit code of `zig build verify` in the reviewer's own run. */
  verify_exit: number;
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
  return { verdict: record as unknown as StepVerdict };
}

/**
 * Decide what the loop does with a step verdict.
 *
 * A step is done only when it added a test, that test is red when the step's production
 * change is reverted, `verify` is green, and the reviewer is neither off track nor
 * worried that the branch is drifting. Anything else stops the run with the branch left
 * where it is, so a human reads a red step rather than the loop building on it.
 */
export function decide(verdict: StepVerdict, expectedStep: number): Decision {
  if (verdict.step !== expectedStep) {
    return { kind: "stop", reason: `the verdict names step ${verdict.step}, not step ${expectedStep}` };
  }
  if (!verdict.on_track) return { kind: "stop", reason: "the step is not on track" };
  if (verdict.verify_exit !== 0) return { kind: "stop", reason: `zig build verify exited ${verdict.verify_exit}` };
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
  /** `proven` only when the reviewer found evidence on the branch; otherwise `unproven`. */
  status: "proven" | "unproven";
  /** What the reviewer read to decide: a test name, a command and its output. */
  evidence: string;
}

/** What the whole-branch reviewer reports once every step has landed. */
export interface FinalVerdict {
  /** Every acceptance criterion of the issue, in the issue's order. */
  criteria: CriterionVerdict[];
  /** Anything a human should read before accepting the run. */
  concerns: string[];
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
    if (entry.status !== "proven" && entry.status !== "unproven") {
      return { problem: `the verdict's criteria[${at}].status is not proven or unproven` };
    }
  }
  if (!holds(record.concerns, "strings")) return { problem: "the verdict's concerns is not a list of strings" };
  return { verdict: record as unknown as FinalVerdict };
}

/**
 * Decide whether a run has reached its criteria.
 *
 * A run passes only when every criterion is proven with evidence the reviewer read. Any criterion
 * unproven, or proven on nothing, stops the run with the criteria named, so a human reads the matrix
 * instead of a run claiming to be done. The standards lens is judged separately, from its own report.
 */
export function decideFinal(verdict: FinalVerdict): FinalDecision {
  const unproven = verdict.criteria.filter((entry) => entry.status !== "proven");
  if (unproven.length > 0) {
    return { kind: "stop", reason: `unproven: ${unproven.map((entry) => entry.criterion).join("; ")}` };
  }

  // A criterion marked proven on an empty evidence line asserts nothing, so it counts as unproven.
  const unevidenced = verdict.criteria.filter((entry) => entry.evidence.trim().length === 0);
  if (unevidenced.length > 0) {
    return { kind: "stop", reason: `no evidence: ${unevidenced.map((entry) => entry.criterion).join("; ")}` };
  }

  return { kind: "pass" };
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
    .filter((entry) => entry.status === "proven" && entry.evidence.trim().length > 0)
    .map((entry) => byText.get(entry.criterion)!.position)
    .filter((position) => !criteria.find((entry) => entry.position === position)?.ticked);

  return { positions };
}
