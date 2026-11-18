// accept.mts — what accepting a run leaves behind: its record beside the issue, and the issue closed.
//
// `scripts/sandcastle-accept.sh` asks this twice: `--check` before the merge, whether the run proved
// the branch on a device, then the close path after it, which files the record and closes the issue.
// The check comes before the merge because a refusal after it would leave the branch already in. The
// git half of the merge stays in the script.

import { execFileSync } from "node:child_process";
import { join } from "node:path";
import { checkAndroidEvidence, type BranchDiff } from "./android_evidence.mts";
import { readLedger } from "./ledger.mts";
import { readRunRecord } from "./run_record.mts";
import { ghTracker } from "./main.mts";
import { PROJECT } from "./project.mts";
import { archiveRun, type RunCommit } from "./archive.mts";
import type { AndroidConfig } from "./project_config.mts";

/** Something that can close an issue: `gh` through the host's own login. */
export interface IssueCloser {
  close(issue: number, comment: string): void;
}

/** The host's closer: one `gh issue close`, with the reason a reader will look for. */
export function ghCloser(): IssueCloser {
  return {
    close: (issue, comment) => {
      execFileSync("gh", ["issue", "close", String(issue), "--comment", comment], { encoding: "utf8" });
    },
  };
}

/**
 * A tracker fact the record and the accept check need: the issue's title, so its directory says
 * what the work was, and its body, where the scenarios the change exercises are declared.
 */
export interface IssueReader {
  title(issue: number): string;
  body(issue: number): string;
}

/** The host's reader: `gh issue view`, with the login the host already has. */
export function ghReader(): IssueReader {
  const view = (issue: number, fields: string, jq: string): string =>
    execFileSync("gh", ["issue", "view", String(issue), "--json", fields, "--jq", jq], { encoding: "utf8" });
  return {
    title: (issue) => view(issue, "title", ".title").trim(),
    body: (issue) => view(issue, "body", ".body"),
  };
}

/** The issue a run was aimed at, from its record or — for an older run — its ledger. */
export function issueOfRun(runsDir: string): number | null {
  const record = readRunRecord(runsDir);
  if (record !== null) return record.issue;
  return readLedger(join(runsDir, "ticks.json"))?.issue ?? null;
}

/**
 * Close the issue a run was aimed at, after its branch was accepted.
 *
 * Returns the issue it closed, or a reason it closed nothing: a run directory from before run
 * records existed leaves no issue to name, and guessing one would close the wrong issue.
 */
export function closeAcceptedRun(
  runsDir: string,
  branch: string,
  into: string,
  closer: IssueCloser,
): { closed: number } | { problem: string } {
  const issue = issueOfRun(runsDir);
  if (issue === null) return { problem: `no run record or ledger in ${runsDir}, so there is no issue to close` };

  closer.close(issue, `Accepted ${branch} into ${into}.`);
  return { closed: issue };
}

/** The commits `head` adds to `base`, oldest first: what the accepted branch was made of. */
export function commitsBetween(base: string, head: string): RunCommit[] {
  const log = execFileSync("git", ["log", "--reverse", "--format=%h%x09%s", `${base}..${head}`], { encoding: "utf8" });
  return log
    .split("\n")
    .filter((line) => line.trim().length > 0)
    .map((line) => {
      const [sha, ...subject] = line.split("\t");
      return { sha, subject: subject.join("\t") };
    });
}

/**
 * File the finished run's record beside its issue.
 *
 * Returns the directory written, or a reason it could not be filed: a run that names no issue
 * gives the record no home, and guessing one would file it under someone else's work.
 */
export function archiveAcceptedRun(
  runsDir: string,
  facts: { archiveRoot: string; branch: string; into: string; base: string; head: string; commits: readonly RunCommit[] },
  reader: IssueReader,
): { dir: string } | { problem: string } {
  const issue = issueOfRun(runsDir);
  if (issue === null) return { problem: `no run record or ledger in ${runsDir}, so the record has no issue to sit beside` };
  const title = reader.title(issue);
  return { dir: archiveRun({ runsDir, issue, title, ...facts }) };
}

/** Stage the record and commit it, unless the branch already carries these exact bytes. */
function commitArchive(dir: string, stamp: string, issue: number): void {
  execFileSync("git", ["add", "--", dir]);
  try {
    execFileSync("git", ["diff", "--cached", "--quiet"], { stdio: "ignore" });
    return;
  } catch {
    // Staged changes: the record is new or corrected, so it goes in its own commit.
  }
  execFileSync("git", ["commit", "-m", `chore(sandcastle): archive run ${stamp} for #${issue}`]);
}

/** The branch as git reports it: the paths it changes, and its diff of the scenario file. */
export interface BranchReader {
  diff(base: string, head: string, android: AndroidConfig): BranchDiff;
}

/**
 * The host's reader: two `git diff` calls, so the required set is judged on the branch itself.
 *
 * The scenario file's diff is asked for on its own, so a method name is never read out of another
 * file's hunk that happens to declare a `void` line.
 */
export function gitBranchReader(): BranchReader {
  const git = (args: string[]): string => execFileSync("git", args, { encoding: "utf8" });
  return {
    diff: (base, head, android) => ({
      touched: git(["diff", "--name-only", `${base}...${head}`])
        .split("\n")
        .map((line) => line.trim())
        .filter((line) => line.length > 0),
      scenarios: git(["diff", `${base}...${head}`, "--", android.testFile]),
    }),
  };
}

/**
 * Why the run may not be accepted for want of device proof, or `null` when it may.
 *
 * Both accept paths call this — `--check` before the merge and the close path after it — so neither
 * can skip the evidence. The issue's body supplies the scenarios it declares; a body that cannot be
 * read is a refusal rather than an unchecked accept.
 */
export function androidRefusal(input: {
  runsDir: string;
  base: string;
  head: string;
  android: AndroidConfig;
  reader: IssueReader;
  diff: BranchReader;
}): string | null {
  const issue = issueOfRun(input.runsDir);
  let body = "";
  if (issue !== null) {
    try {
      body = input.reader.body(issue);
    } catch (error) {
      return `the body of #${issue} could not be read, so its declared scenarios are unknown: ${(error as Error).message}`;
    }
  }
  return checkAndroidEvidence({
    diff: input.diff.diff(input.base, input.head, input.android),
    body,
    android: input.android,
    runsDir: input.runsDir,
    commit: input.head,
  });
}

if (import.meta.main) {
  const at = process.argv.indexOf("--stamp");
  const stamp = at === -1 ? "" : (process.argv[at + 1] ?? "");
  const intoAt = process.argv.indexOf("--into");
  const into = intoAt === -1
    ? execFileSync("git", ["rev-parse", "--abbrev-ref", "HEAD"], { encoding: "utf8" }).trim()
    : (process.argv[intoAt + 1] ?? "");
  const branchAt = process.argv.indexOf("--branch");
  const branch = branchAt === -1 ? `sandcastle/<run>/${stamp}` : (process.argv[branchAt + 1] ?? "");
  const argOf = (name: string): string => {
    const found = process.argv.indexOf(name);
    return found === -1 ? "" : (process.argv[found + 1] ?? "");
  };
  const base = argOf("--base");
  const head = argOf("--head");
  const check = process.argv.includes("--check");
  if (!/^\d+$/u.test(stamp) || base.length === 0 || head.length === 0) {
    console.error(
      "usage: npx tsx .sandcastle/accept.mts [--check] --stamp <run stamp> --branch <branch> --into <branch> --base <sha> --head <sha>",
    );
    process.exit(1);
  }

  const runsDir = join(PROJECT.paths.runsDir, stamp);
  const evidence = (): string | null =>
    androidRefusal({
      runsDir,
      base,
      head,
      android: PROJECT.android,
      reader: ghReader(),
      diff: gitBranchReader(),
    });

  // Before the merge there is still a branch to refuse: the script asks, and a refusal leaves the
  // branch where it is rather than merging work the device never proved.
  if (check) {
    const refusal = evidence();
    if (refusal !== null) {
      console.error(`[accept] refusing before the merge: ${refusal}`);
      process.exit(1);
    }
    console.log("[accept] the run's device evidence proves this branch");
    process.exit(0);
  }

  // The close path asks the same question, so an accept that skipped `--check` cannot close either.
  const refusal = evidence();
  if (refusal !== null) {
    console.error(`[accept] the branch is merged, but its device evidence does not prove it: ${refusal}`);
    process.exit(1);
  }
  let archived = false;
  // The merge already happened, so a failure here loses the record but not the branch: report it and
  // still close the issue, then exit non-zero so the accept is not mistaken for a clean one.
  try {
    const filed = archiveAcceptedRun(
      runsDir,
      { archiveRoot: PROJECT.paths.archive, branch, into, base, head, commits: commitsBetween(base, head) },
      ghReader(),
    );
    if ("problem" in filed) throw new Error(filed.problem);
    commitArchive(filed.dir, stamp, issueOfRun(runsDir) ?? 0);
    console.log(`[accept] filed the run record in ${filed.dir}`);
    archived = true;
  } catch (error) {
    console.error(`[accept] the run record was not filed: ${(error as Error).message}`);
  }

  const result = closeAcceptedRun(runsDir, branch, into, ghCloser());
  if ("problem" in result) {
    console.error(`[accept] ${result.problem}`);
    process.exit(1);
  }
  console.log(`[accept] closed #${result.closed}`);
  if (!archived) process.exit(1);
}
