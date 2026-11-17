// standards.mts — the standards a run must answer for, read from AGENTS.md itself.
//
// The list of rules is the owner's, not the harness's: it is parsed out of `AGENTS.md` on every run,
// so a rule added there is required by the next run with no change here. Hardcoding the list would
// turn "every rule answered" into a check that passes by being out of date.

import type { ShotgunClaim } from "./shotgun.mts";

/** One coding standard, as `AGENTS.md` numbers it. */
export type Rule = {
  /** The number the standard carries in `AGENTS.md`; stable across runs, and what a report refers to. */
  position: number;
  /** The standard's title, which is how a report names it. */
  title: string;
  /** The bold-only wording, when the title continues past it; a report may use either. */
  aliases?: string[];
};

/** What a reviewer said about one standard. */
export type RuleVerdict = {
  /** The standard's title, worded as `AGENTS.md` words it — the host matches on this text. */
  rule: string;
  verdict: "PASS" | "VIOLATION";
  /** `file:line` for a pass, and the violation with its site for a failure. Never "code smell". */
  evidence: string;
};

/** A run's answers to the standards lens. */
export type StandardsReport = {
  /** One answer per rule in the branch's `AGENTS.md`, no rule skipped and none invented. */
  rules: RuleVerdict[];
  /** The symbols the diff carries through several files; the host counts the files, not the reviewer. */
  shotgun: ShotgunClaim[];
};

const HEADING = /^##\s+Coding standards\s*$/iu;
const ANY_HEADING = /^##\s+\S/u;
// A rule is a numbered item at the left margin whose text opens with a bold title. The bold may be
// only the first words (`**Clean** code style.`), so the title is what follows it too.
const RULE = /^(\d+)\.\s+\*\*(.+?)\*\*(.*)$/u;
// Plain words after the bold belong to the title; a separator or a capital starts the description.
const TITLE_CONTINUATION = /^[a-z][^.:;,!?—–(]*/u;

/**
 * The coding standards in `AGENTS.md`, in order.
 *
 * Reads only the numbered items under `## Coding standards`, so a rule's indented sub-bullets
 * (`- **HARD RULE (MANDATORY):** …`) stay part of that rule instead of becoming rules of their own.
 * Throws when the section is missing: a run with no standards to answer for is a stop, not a pass.
 */
export function readRules(markdown: string): Rule[] {
  const lines = markdown.split("\n");
  const start = lines.findIndex((line) => HEADING.test(line));
  if (start === -1) throw new Error('no "## Coding standards" section in AGENTS.md');

  const rules: Rule[] = [];
  for (const line of lines.slice(start + 1)) {
    if (ANY_HEADING.test(line)) break;
    const match = RULE.exec(line);
    if (match) rules.push({ position: Number(match[1]), ...ruleTitle(match[2]!.trim(), match[3] ?? "") });
  }
  if (rules.length === 0) throw new Error('the "## Coding standards" section in AGENTS.md has no numbered rules');

  return rules;
}

/**
 * A rule's title: its bold text, plus the plain words that continue it.
 *
 * `**Clean** code style.` names the standard "Clean code style", while `**DRY** — Don't repeat
 * yourself.` and `**Document public surfaces.** Every function…` stop at the bold, so a report
 * may use either wording without inventing a rule.
 */
function ruleTitle(bold: string, rest: string): { title: string; aliases?: string[] } {
  if (/[.:;,!?]$/u.test(bold)) return { title: bold };
  const continuation = TITLE_CONTINUATION.exec(rest.trim());
  if (!continuation) return { title: bold };
  // A report may name the standard by its bold text alone; both readings are the same rule.
  return { title: `${bold} ${continuation[0].trim()}`, aliases: [bold] };
}

/** Normalise a title for matching, so punctuation or a stray double space cannot split a match. */
function key(title: string): string {
  // Trailing punctuation is a heading's decoration, not part of the standard's name: AGENTS.md
  // writes `**SOLID principles:**` and `**Constructors are pure.**`, a report may write either
  // without the colon or full stop, and both name the same rule.
  return title.trim().replace(/[.:;,!?]+$/u, "").replace(/\s+/gu, " ").toLowerCase();
}

/** Whether a report's wording names this rule, by its title or an alias. */
function names(rule: Rule, text: string): boolean {
  const wanted = key(text);
  return key(rule.title) === wanted || (rule.aliases ?? []).some((alias) => key(alias) === wanted);
}

/**
 * Read `verdict-standards.json`, checked field by field so a malformed report is never a pass.
 *
 * The report is the reviewer's whole answer to the standards lens; the reviewer does not also get
 * to say "clean" somewhere else, or the two could disagree.
 */
export function readReport(raw: string): { report: StandardsReport } | { problem: string } {
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return { problem: "the standards report is not valid JSON" };
  }
  if (typeof parsed !== "object" || parsed === null) return { problem: "the standards report is not a JSON object" };

  const record = parsed as Record<string, unknown>;
  if (!Array.isArray(record.rules)) return { problem: "the standards report has no rules field" };
  if (!Array.isArray(record.shotgun)) return { problem: "the standards report has no shotgun field" };
  for (const [at, entry] of record.shotgun.entries()) {
    const claim = entry as Record<string, unknown>;
    if (typeof claim.symbol !== "string") return { problem: `the standards report's shotgun[${at}] names no symbol` };
  }
  for (const [at, entry] of record.rules.entries()) {
    const rule = entry as Record<string, unknown>;
    if (typeof rule.rule !== "string" || typeof rule.evidence !== "string") {
      return { problem: `the standards report's rules[${at}] has no rule and evidence text` };
    }
    if (rule.verdict !== "PASS" && rule.verdict !== "VIOLATION") {
      return { problem: `the standards report's rules[${at}].verdict is not PASS or VIOLATION` };
    }
  }
  return { report: record as unknown as StandardsReport };
}

/**
 * Check a standards report against the rules the run was asked about.
 *
 * The reviewer may neither skip a rule nor answer one that does not exist, and an answer carries
 * evidence or it is not an answer — the same shape as the acceptance-criteria matrix.
 * Returns `{ ok: true }`, or `{ problem }` naming the first defect so the run can stop on it.
 */
export function validateReport(report: StandardsReport, rules: Rule[]): { ok: true } | { problem: string } {

  const missing = rules.filter((rule) => !report.rules.some((entry) => names(rule, entry.rule)));
  if (missing.length > 0) return { problem: `left unjudged: ${missing.map((rule) => rule.title).join("; ")}` };

  const invented = report.rules.filter((entry) => !rules.some((rule) => names(rule, entry.rule)));
  if (invented.length > 0) {
    return { problem: `answers a standard AGENTS.md does not have: ${invented.map((entry) => entry.rule).join("; ")}` };
  }

  const unproven = report.rules.filter((entry) => entry.evidence.trim().length === 0);
  if (unproven.length > 0) return { problem: `answered without evidence: ${unproven.map((entry) => entry.rule).join("; ")}` };

  return { ok: true };
}
