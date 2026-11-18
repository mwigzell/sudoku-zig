// android_evidence.mts — what an Android-scope branch must prove, and whether a run's record proves it.
//
// The project's gate cannot reach the device suite, so the proof of an Android change is a recorded
// device run. Which scenarios it must cover is a property of the branch — the methods it adds or
// changes, the ones the issue declares, and the pinned smoke when it changes none — never a list
// guessed before the code exists. Everything here is handed its project facts, so the judgement can
// be tested without a device.

import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import type { AndroidConfig } from "./project_config.mts";

/** One `FileBridgeTest` method a branch must prove, and why it is required. */
export interface Requirement {
  /** JUnit method name, as the scenario file declares it. */
  method: string;
  /** What proving it answers for this branch, so the requirement explains itself. */
  why: string;
}

/** The record one device run leaves beside a run's verdicts; its keys are the gate's own. */
export interface Evidence {
  /** The issue whose branch required the run; absent for a run outside an issue. */
  issue?: number;
  /** The methods the branch required, each with its reason. */
  required: readonly Requirement[];
  /** The methods the instrumented run executed. */
  methods: readonly string[];
  /** The command the run made, so a reader can repeat it. */
  command: string;
  /** `passed` or `failed`, as the gate wrote it. */
  result: string;
  /** The `adb` serial of the device the run proved itself on. */
  device: string;
  /** Wall-clock seconds the instrumented run took. */
  duration_s: number;
  /** The commit the run proved; a record naming another commit proves nothing. */
  commit: string;
  /** Whether the worktree was clean, as the run required. */
  clean_tree: boolean;
  /** When the record was written, UTC ISO 8601. */
  at: string;
}

/** What the branch changed: the paths it touches, and its diff of the scenario file. */
export interface BranchDiff {
  /** Every path the branch changes, from a name-only diff of base...head. */
  touched: readonly string[];
  /** The branch's diff of the scenario file, from a diff of base...head limited to that file. */
  scenarios: string;
}

/** What a branch owes the device suite. */
export type RequiredSet =
  /** The branch changes no Android code, so no device run proves anything about it. */
  | { kind: "not-android" }
  /** These methods must pass on a device before the branch can be accepted. */
  | { kind: "required"; required: Requirement[] }
  /** The branch changes Android behaviour and names nothing that proves it. */
  | { kind: "stop"; reason: string };

/** The evidence file a device run leaves in the run directory. */
export const EVIDENCE_FILE = "android-evidence.json";

/** Where a run's device evidence sits: beside its verdicts, so both are read from one directory. */
export function evidencePath(runsDir: string): string {
  return join(runsDir, EVIDENCE_FILE);
}

/**
 * A `+` line declaring a JUnit scenario: a public `void <name>(`.
 *
 * Only public methods are scenarios: JUnit cannot run a private helper by name, so requiring one
 * would make the gate refuse work it could never prove.
 */
const ADDED_METHOD = /^\+\s*public\s+(?:static\s+|final\s+)*void\s+([A-Za-z_$][\w$]*)\s*\(/u;
/** The diff header that names the file itself; it starts with `+` and is not a declaration. */
const DIFF_HEADER = /^\+\+\+/u;
/** The heading a branch declares extra scenarios under. */
const DECLARED_HEADING = /^##\s+android scenarios\s*$/iu;
/** The next level-2 heading, which closes the declared section. */
const NEXT_SECTION = /^##\s+\S/u;
/** A fenced block's fence; what it holds is an example, never a declaration. */
const FENCE = /^\s*(?:```|~~~)/u;
/** A method named in prose, as `\`name\`` or `\`name()\``. */
const CODE_SPAN = /`([A-Za-z_$][\w$]*)(?:\(\))?`/gu;

/**
 * The scenario methods a branch adds or changes.
 *
 * `diff` is the branch's diff of the scenario file. Only added lines count: a method the branch
 * removes needs no proof, and the diff's own `+++` header is not a declaration.
 */
export function addedOrChangedMethods(diff: string): string[] {
  const methods: string[] = [];
  for (const line of diff.split("\n")) {
    if (DIFF_HEADER.test(line)) continue;
    const match = ADDED_METHOD.exec(line);
    if (match === null) continue;
    const method = match[1]!;
    if (!methods.includes(method)) methods.push(method);
  }
  return methods;
}

/** The body with every fenced block's lines dropped: an example of the section is not a declaration. */
function withoutFences(body: string): string {
  const kept: string[] = [];
  let fenced = false;
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
 * The existing scenarios an issue declares under `## Android scenarios`.
 *
 * A declared scenario is how a bridge or core change names the proof it needs without adding a test.
 * The section is read without its fences, so the worked example a doc writes down is never mistaken
 * for a method the run must prove.
 */
export function declaredScenarios(body: string): string[] {
  const lines = withoutFences(body).split("\n");
  const start = lines.findIndex((line) => DECLARED_HEADING.test(line));
  if (start === -1) return [];

  const declared: string[] = [];
  for (const line of lines.slice(start + 1)) {
    if (NEXT_SECTION.test(line)) break;
    for (const span of line.matchAll(CODE_SPAN)) {
      const method = span[1]!;
      if (!declared.includes(method)) declared.push(method);
    }
  }
  return declared;
}

/** Whether any changed path is one of `paths`: an entry ending in `/` is a directory. */
function changesAny(touched: readonly string[], paths: readonly string[]): boolean {
  return touched.some((path) => paths.some((entry) => (entry.endsWith("/") ? path.startsWith(entry) : path === entry)));
}

/** The changed paths that made the branch Android-scope, so a refusal can name them. */
function androidPathsChanged(diff: BranchDiff, paths: readonly string[]): string[] {
  return diff.touched.filter((path) => paths.some((entry) => (entry.endsWith("/") ? path.startsWith(entry) : path === entry)));
}

/**
 * The scenarios this branch must prove on a device.
 *
 * The branch's own added or changed methods come first, then the ones the issue declares; a branch
 * that changes no scenario owes the pinned smoke. A branch that moves the Android app itself and
 * names no scenario at all stops here rather than accepting on nothing.
 */
export function requiredScenarios(input: { diff: BranchDiff; body: string; android: AndroidConfig }): RequiredSet {
  const { diff, body, android } = input;
  if (!changesAny(diff.touched, android.code)) return { kind: "not-android" };

  const required: Requirement[] = [];
  const require = (method: string, why: string): void => {
    if (required.some((entry) => entry.method === method)) return;
    required.push({ method, why });
  };

  for (const method of addedOrChangedMethods(diff.scenarios)) require(method, "added or changed by this branch");
  for (const method of declaredScenarios(body)) require(method, "declared in the issue's `## Android scenarios`");
  if (required.length > 0) return { kind: "required", required };

  const surface = androidPathsChanged(diff, android.surface);
  if (surface.length > 0) {
    return {
      kind: "stop",
      reason:
        `no scenario names this change: the branch changes the Android app (${surface.join(", ")}) and ` +
        "adds, changes or declares no scenario; add one, or say in the issue why one cannot exist",
    };
  }

  return { kind: "required", required: [{ method: android.smoke, why: "the pinned smoke: this branch changes no Android scenario" }] };
}

/** A run's evidence as it was read, or the reason it could not be. */
export type EvidenceRead = { evidence: Evidence } | { problem: string };

/** Read the device evidence a run left in its directory. */
export function readEvidence(runsDir: string): EvidenceRead {
  const file = evidencePath(runsDir);
  if (!existsSync(file)) {
    return { problem: `no ${EVIDENCE_FILE} in ${runsDir}, so nothing proves the device run this branch needs` };
  }
  try {
    const read = JSON.parse(readFileSync(file, "utf8")) as Partial<Evidence>;
    return {
      evidence: {
        required: Array.isArray(read.required) ? read.required : [],
        methods: Array.isArray(read.methods) ? read.methods.map(String) : [],
        command: String(read.command ?? ""),
        result: String(read.result ?? ""),
        device: String(read.device ?? ""),
        duration_s: Number(read.duration_s ?? 0),
        commit: String(read.commit ?? ""),
        clean_tree: read.clean_tree === true,
        at: String(read.at ?? ""),
      },
    };
  } catch (error) {
    return { problem: `${file} could not be read: ${(error as Error).message}` };
  }
}

/**
 * Why a branch may not be accepted for want of device proof, or `null` when it may.
 *
 * One reason, naming the defect: a missing record, a failed run, evidence from another commit or a
 * dirty tree, or a required scenario the run never proved.
 */
export function checkAndroidEvidence(input: {
  diff: BranchDiff;
  body: string;
  android: AndroidConfig;
  runsDir: string;
  commit: string;
}): string | null {
  const set = requiredScenarios(input);
  if (set.kind === "not-android") return null;
  if (set.kind === "stop") return set.reason;

  const read = readEvidence(input.runsDir);
  if ("problem" in read) return read.problem;

  const evidence = read.evidence;
  const problems: string[] = [];
  if (evidence.result !== "passed") {
    problems.push(`the device run failed ("${evidence.result}" on ${evidence.device})`);
  }
  if (evidence.commit !== input.commit) {
    problems.push(`the evidence proves commit ${evidence.commit || "nothing"}, not this branch's head ${input.commit}`);
  }
  if (!evidence.clean_tree) {
    problems.push("the evidence came from a dirty worktree, so it proves code that was never committed");
  }
  const missing = set.required.map((entry) => entry.method).filter((method) => !evidence.methods.includes(method));
  if (missing.length > 0) problems.push(`the device run did not prove ${missing.join(", ")}`);

  return problems.length === 0 ? null : problems.join("; ");
}
