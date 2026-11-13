// accept.mts — the tracker half of accepting a run: close the issue it was aimed at.
//
// `scripts/sandcastle-accept.sh` merges the run branch, then calls this. Closing belongs here
// rather than in the entry: the run already proved the issue's criteria, so accepting it is the
// end of that issue. The git half stays in the script.

import { execFileSync } from "node:child_process";
import { join } from "node:path";
import { readLedger } from "./ledger.mts";
import { readRunRecord } from "./run_record.mts";
import { ghTracker } from "./loop.mts";

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

if (import.meta.main) {
  const at = process.argv.indexOf("--stamp");
  const stamp = at === -1 ? "" : (process.argv[at + 1] ?? "");
  const intoAt = process.argv.indexOf("--into");
  const into = intoAt === -1 ? "develop" : (process.argv[intoAt + 1] ?? "develop");
  const branchAt = process.argv.indexOf("--branch");
  const branch = branchAt === -1 ? `sandcastle/<run>/${stamp}` : (process.argv[branchAt + 1] ?? "");

  if (!/^\d+$/u.test(stamp)) {
    console.error("usage: npx tsx .sandcastle/accept.mts --stamp <run stamp> --branch <branch> --into <branch>");
    process.exit(1);
  }

  const result = closeAcceptedRun(join(".sandcastle", "logs", stamp), branch, into, ghCloser());
  if ("problem" in result) {
    console.error(`[accept] ${result.problem}`);
    process.exit(1);
  }
  console.log(`[accept] closed #${result.closed}`);
}
