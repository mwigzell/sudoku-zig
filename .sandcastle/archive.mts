// archive.mts — the record an accepted run leaves beside the issue it did.
//
// A run's directory is git-ignored, so the evidence an accept rested on would not survive a clone.
// Accepting copies the verdicts and the device evidence next to the issue and writes a README naming
// the branch, its commits, the judged criteria and the concerns the reviewer still held. The paths
// and the issue come in from the caller: this module reads no project file and runs no command of its own.

import { copyFileSync, existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { readLedger, type Tick } from "./ledger.mts";
import { EVIDENCE_FILE } from "./android_evidence.mts";
import { readFinalVerdict, type FinalVerdict } from "./verdict.mts";

/** One commit the accepted branch carried, oldest first: the short id and what it says. */
export type RunCommit = { sha: string; subject: string };

/** What the host knows about a finished run when the human accepts it. */
export interface ArchiveRun {
  /** The run's own directory, where the verdicts, ledger and shotgun report were written. */
  runsDir: string;
  /** Where accepted runs are recorded, one directory per issue. */
  archiveRoot: string;
  /** The issue the run was aimed at. */
  issue: number;
  /** That issue's title, so the directory says what the work was. */
  title: string;
  /** The run's branch. */
  branch: string;
  /** The branch the run was accepted into. */
  into: string;
  /** The commit the branch was cut from. */
  base: string;
  /** The branch's head, as it was merged. */
  head: string;
  /** The branch's commits, oldest first. */
  commits: readonly RunCommit[];
}

/**
 * Longest title slug a record directory carries, so a long issue title stays openable by eye.
 * The cut lands on a word boundary and drops a word that only joined the title's next clause,
 * so a directory never ends in "…-for".
 */
const MAX_SLUG = 48;

/** Words that say nothing on the end of a cut slug, so the cut does not leave one hanging. */
const JOINING_WORDS = new Set(["a", "an", "and", "at", "by", "for", "from", "in", "its", "of", "on", "or", "the", "to", "with"]);

/** The record directory's name: the issue number, then the title as a short kebab slug. */
export function archiveDirName(issue: number, title: string): string {
  let slug = title
    .toLowerCase()
    .replace(/[^a-z0-9]+/gu, "-")
    .replace(/^-+|-+$/gu, "");
  if (slug.length > MAX_SLUG) {
    const cut = slug.slice(0, MAX_SLUG + 1).lastIndexOf("-");
    slug = (cut > 0 ? slug.slice(0, cut) : slug.slice(0, MAX_SLUG)).replace(/-+$/u, "");
    while (JOINING_WORDS.has(slug.slice(slug.lastIndexOf("-") + 1))) slug = slug.slice(0, Math.max(0, slug.lastIndexOf("-")));
  }
  return slug.length === 0 ? String(issue) : `${issue}-${slug}`;
}
/** What each copied file answers, so the README's index says why a reader opens it. */
const FILE_ROLES: Readonly<Record<string, string>> = {
  "verdict-acs.json": "the whole-branch acceptance-criteria matrix, with the evidence quoted",
  "verdict-standards.json": "the standards lens, one answer per numbered rule",
  "shotgun.json": "the symbols the branch carries through several files",
  [EVIDENCE_FILE]: "the device run accept gated on: the methods, the commit and the result",
};


/** Step verdicts are numbered; they sort by that number, not as text. */
function stepNumber(name: string): number {
  const match = /^step-(\d+)-verdict\.json$/u.exec(name);
  return match === null ? -1 : Number(match[1]);
}

/** The files a record consists of, in the order a reader opens them. */
function recordFiles(runsDir: string): string[] {
  const present = new Set(readdirSync(runsDir));
  const steps = [...present].filter((name) => stepNumber(name) !== -1).sort((a, b) => stepNumber(a) - stepNumber(b));
  const rest = ["verdict-acs.json", "verdict-standards.json", "shotgun.json", EVIDENCE_FILE].filter((name) => present.has(name));
  return [...steps, ...rest];
}

/** The whole-branch verdict, or `null` when the run left none (a review that never ran). */
function finalVerdict(runsDir: string): FinalVerdict | null {
  const file = join(runsDir, "verdict-acs.json");
  if (!existsSync(file)) return null;
  const read = readFinalVerdict(readFileSync(file, "utf8"));
  // A malformed matrix is still the record the run produced; the README says what it could not read.
  return "problem" in read ? null : read.verdict;
}

/** The shotgun symbols, as the host counted them for the branch. */
function shotgunLines(runsDir: string): string[] {
  const file = join(runsDir, "shotgun.json");
  if (!existsSync(file)) return [];
  try {
    const read = JSON.parse(readFileSync(file, "utf8")) as Array<{ symbol?: unknown; files?: unknown; verdict?: unknown }>;
    return read
      .filter((entry) => typeof entry.symbol === "string" && typeof entry.files === "number")
      .map((entry) => `- \`${String(entry.symbol)}\` in ${String(entry.files)} files — ${String(entry.verdict ?? "reported")}`);
  } catch {
    return [];
  }
}

/** `count of total` for the ticks a run recorded against the checks it was judged by. */
function progress(ticks: number, total: number): string {
  return `${ticks} of ${total}`;
}

/** The README a reader opens first: what ran, what it proved, and what it left open. */
function readme(run: ArchiveRun, files: readonly string[], ticks: readonly Tick[], criteria: readonly Tick[], verdict: FinalVerdict | null): string {
  const steps = files.filter((name) => stepNumber(name) !== -1).length;
  const criteriaTotal = verdict === null ? 0 : verdict.criteria.length;
  const lines: string[] = [
    run.title.trim().length === 0 ? `# #${run.issue}` : `# #${run.issue} — ${run.title.trim()}`,
    "",
    "Run record for the sandcastle run that did this issue's work, written by `npm run sandcastle:accept`.",
    "",
    "## Run",
    "",
    `- Branch: \`${run.branch}\``,
    `- Cut from \`${run.into}\` at \`${run.base}\`; head \`${run.head}\` (${run.commits.length} commit${run.commits.length === 1 ? "" : "s"})`,
    `- Steps: ${progress(ticks.length, Math.max(steps, ticks.length))} ticked; acceptance criteria: ${
      verdict === null ? `${criteria.length} ticked` : progress(criteria.length, criteriaTotal)
    }`,
  ];
  if (verdict !== null) {
    const parity = verdict.parity_line === undefined
      ? "no parity citation in the whole-branch verdict"
      : `${verdict.parity_restored === true ? "parity restored" : "parity NOT restored"} — \`${verdict.parity_line}\``;
    lines.push(`- Final review: ${parity}`);
  } else {
    lines.push("- Final review: no whole-branch verdict was copied");
  }
  lines.push(`- Run logs and agent transcripts: \`${run.runsDir}/\` (git-ignored; this copy is the record)`);

  lines.push("", "Commits, oldest first:", "");
  if (run.commits.length === 0) lines.push("- (none recorded)");
  for (const [at, commit] of run.commits.entries()) lines.push(`${at + 1}. \`${commit.sha}\` ${commit.subject}`);

  lines.push("", "## Acceptance criteria", "");
  if (verdict === null || verdict.criteria.length === 0) lines.push("- (none recorded)");
  for (const entry of verdict?.criteria ?? []) lines.push(`- ${entry.status} — ${entry.criterion}`);

  lines.push("", "## Concerns (not fixed here)", "");
  if (verdict === null || verdict.concerns.length === 0) lines.push("- (none recorded)");
  for (const concern of verdict?.concerns ?? []) lines.push(`- ${concern}`);

  lines.push("", "## Shotgun", "");
  const shotgun = shotgunLines(run.runsDir);
  lines.push(...(shotgun.length === 0 ? ["- (none recorded)"] : shotgun));

  lines.push("", "## Files", "");
  for (const name of files) {
    const role = stepNumber(name) === -1
      ? (FILE_ROLES[name] ?? "the run's own record")
      : "a step reviewer's verdict: the test added, what happened on revert, `verify_exit`, standards";
    lines.push(`- \`${name}\` — ${role}`);
  }
  lines.push("");
  return lines.join("\n");
}

/** Copy a finished run's verdicts beside its issue and write the README that indexes them. */
export function archiveRun(run: ArchiveRun): string {
  const dir = join(run.archiveRoot, archiveDirName(run.issue, run.title));
  mkdirSync(dir, { recursive: true });

  const files = recordFiles(run.runsDir);
  for (const name of files) copyFileSync(join(run.runsDir, name), join(dir, name));

  const ledger = readLedger(join(run.runsDir, "ticks.json"));
  writeFileSync(
    join(dir, "README.md"),
    readme(run, files, ledger?.ticks ?? [], ledger?.criteria ?? [], finalVerdict(run.runsDir)),
  );
  return dir;
}
