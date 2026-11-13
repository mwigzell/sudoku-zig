// run_record.mts — what a run is aimed at, written once at its start.
//
// The ledger records what a run wrote to the tracker, so it only exists once a step has been
// ticked. A run that stops at its first step still has to be settleable, and settling needs the
// issue it was aimed at, so the aim is recorded before any agent starts.

import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";

/** The issue a run works on, the branch it commits to, and where it was cut from. */
export type RunRecord = {
  /** The issue the run was aimed at; settling the run closes it. */
  issue: number;
  /** The one branch every step of this run commits to. */
  branch: string;
  /** The branch the run was cut from and is accepted into. */
  targetBranch: string;
  /** When the run started, ISO 8601, so a stale run directory is recognisable. */
  startedAt: string;
};

/** Where a run keeps its own identity, beside its verdicts and its ledger. */
export function runRecordPath(runsDir: string): string {
  return join(runsDir, "run.json");
}

/** Write the record, creating the run directory when the run has not made it yet. */
export function writeRunRecord(runsDir: string, record: RunRecord): void {
  const file = runRecordPath(runsDir);
  mkdirSync(dirname(file), { recursive: true });
  writeFileSync(file, `${JSON.stringify(record, null, 2)}\n`);
}

/** The record a run left behind, or `null` for a run directory written before records existed. */
export function readRunRecord(runsDir: string): RunRecord | null {
  const file = runRecordPath(runsDir);
  if (!existsSync(file)) return null;
  const read = JSON.parse(readFileSync(file, "utf8")) as Partial<RunRecord>;
  return {
    issue: Number(read.issue),
    branch: String(read.branch ?? ""),
    targetBranch: String(read.targetBranch ?? ""),
    startedAt: String(read.startedAt ?? ""),
  };
}
