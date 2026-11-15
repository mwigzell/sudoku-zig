// resume.mts — whether an aim continues a run that stopped or starts a fresh one.
//
// A run that stops leaves its branch, its worktree-free commits and the steps it already ticked.
// Those are the run's earned work, so aiming at the same issue again continues it: the same stamp,
// the same branch, the same log directory, and only the unticked steps are left to do. Aiming at a
// different issue is a different run, and one repository holds one unaccepted run at a time.

/** An unaccepted run found in the repository: its branch, and the record it left of its aim. */
export type UnsettledRun = {
  /** The stamp the branch and the run directory end with. */
  stamp: number;
  /** The run's branch, as `git branch` spells it. */
  branch: string;
  /** The issue the run was aimed at, or `null` when the run left no record of it. */
  issue: number | null;
};

/** What a run should do with what the repository already holds. */
export type ResumeDecision =
  | { kind: "fresh" }
  | { kind: "resume"; stamp: number; branch: string }
  | { kind: "stop"; reason: string };

/**
 * Decide whether `issue` continues an unaccepted run or starts a fresh one.
 *
 * Pure: the caller reads the branches and run records, and acts on the answer. A run with no
 * recorded aim cannot be judged safe to continue, so it stops rather than guessing which issue it
 * belonged to.
 */
export function decideResume(runs: readonly UnsettledRun[], issue: number): ResumeDecision {
  if (runs.length === 0) return { kind: "fresh" };
  if (runs.length > 1) {
    return { kind: "stop", reason: `more than one unaccepted run remains (${runs.map((run) => run.branch).join(", ")}); accept or drop them first` };
  }

  const [run] = runs as [UnsettledRun];
  if (run.issue === null) {
    return {
      kind: "stop",
      reason: `${run.branch} left no record of the issue it was aimed at; accept or drop it before starting a run`,
    };
  }
  if (run.issue !== issue) {
    return {
      kind: "stop",
      reason: `the unaccepted run ${run.branch} was aimed at #${run.issue}; accept or drop it before aiming a run at #${issue}`,
    };
  }
  return { kind: "resume", stamp: run.stamp, branch: run.branch };
}
