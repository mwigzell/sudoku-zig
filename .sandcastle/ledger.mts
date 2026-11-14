// ledger.mts — the host's record of the ticks a run wrote to the tracker.
//
// The loop ticks the issue as each step passes, and only the host ever writes to the tracker.
// This record is what lets a drop take those marks back: it names the issue and the position of
// every step this run ticked, in the order the ticks landed.

import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { untickCriterion, untickStep } from "./plan.mts";
import type { Tracker } from "./loop.mts";

/** One mark the host wrote: which issue, which checkbox position, and when. */
export type Tick = { position: number; at: string; issue: number };

/** What one run wrote to the tracker: the issue it aimed at, and every tick it made there. */
export type Ledger = {
  issue: number;
  /** Steps ticked as they passed, in order. */
  ticks: Tick[];
  /** Acceptance criteria ticked by the whole-branch review; absent in a ledger written before it existed. */
  criteria: Tick[];
};

/** Where a run keeps its record, beside the verdicts it copied out of the sandbox. */
export function ledgerPath(runsDir: string): string {
  return join(runsDir, "ticks.json");
}

/** The ledger with one more step tick on it; the ledger handed in is left alone. */
export function recordTick(ledger: Ledger, position: number, at: string, issue: number = ledger.issue): Ledger {
  return { issue: ledger.issue, ticks: [...ledger.ticks, { position, at, issue }], criteria: ledger.criteria };
}

/**
 * The ledger with one more acceptance-criterion tick on it; the ledger handed in is left alone.
 *
 * `issue` defaults to the run's own issue and is the child's when a step's criteria were judged by
 * that child's reviewer — a drop has to know which body to take the mark back from.
 */
export function recordCriterion(ledger: Ledger, position: number, at: string, issue: number = ledger.issue): Ledger {
  return { issue: ledger.issue, ticks: ledger.ticks, criteria: [...ledger.criteria, { position, at, issue }] };
}

/** Write the record, creating the run directory when the run has not made it yet. */
export function writeLedger(file: string, ledger: Ledger): void {
  mkdirSync(dirname(file), { recursive: true });
  writeFileSync(file, `${JSON.stringify(ledger, null, 2)}\n`);
}

/** The record a run left behind, or `null` when it ticked nothing (or never ran). */
export function readLedger(file: string): Ledger | null {
  if (!existsSync(file)) return null;
  const read = JSON.parse(readFileSync(file, "utf8")) as Partial<Ledger>;
  const issue = Number(read.issue);
  // A ledger written before ticks carried their issue means the run's own issue for every tick.
  const own = (ticks: Tick[] | undefined): Tick[] => (ticks ?? []).map((tick) => ({ ...tick, issue: tick.issue ?? issue }));
  return { issue, ticks: own(read.ticks), criteria: own(read.criteria) };
}

/** Take back the ticks this run recorded on one issue, leaving other bytes as written. */
export function untickRecorded(body: string, ticks: readonly Tick[], criteria: readonly Tick[]): string {
  let current = body;
  for (const tick of ticks) current = untickStep(current, tick.position) ?? current;
  for (const tick of criteria) current = untickCriterion(current, tick.position) ?? current;
  return current;
}

/** Something that can produce a tracker for any issue: the run's own, or a child's. */
export type TrackerSource = (issue: number) => Tracker;

/**
 * Take back every tick a run recorded, per issue.
 *
 * Reads each issue as the tracker holds it now, so the marks are undone on top of whatever else
 * changed since, and returns the positions it unticked. An empty record writes nothing: a run that
 * ticked nothing has nothing to take back.
 */
export function untickRun(ledger: Ledger, trackerFor: TrackerSource): number[] {
  if (ledger.ticks.length === 0 && ledger.criteria.length === 0) return [];

  const issues = [...new Set([...ledger.ticks, ...ledger.criteria].map((tick) => tick.issue))];
  for (const issue of issues) {
    const ticks = ledger.ticks.filter((tick) => tick.issue === issue);
    const criteria = ledger.criteria.filter((tick) => tick.issue === issue);
    const tracker = trackerFor(issue);
    tracker.writeBody(issue, untickRecorded(tracker.read(issue).body, ticks, criteria));
  }
  return [...ledger.ticks, ...ledger.criteria].map((tick) => tick.position);
}
