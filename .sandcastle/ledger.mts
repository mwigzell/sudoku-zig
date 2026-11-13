// ledger.mts — the host's record of the ticks a run wrote to the tracker.
//
// The loop ticks the issue as each step passes, and only the host ever writes to the tracker.
// This record is what lets a drop take those marks back: it names the issue and the position of
// every step this run ticked, in the order the ticks landed.

import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { untickCriterion, untickStep } from "./plan.mts";
import type { Tracker } from "./loop.mts";

/** One mark the host wrote: the step position it ticked, and when. */
export type Tick = { position: number; at: string };

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
export function recordTick(ledger: Ledger, position: number, at: string): Ledger {
  return { issue: ledger.issue, ticks: [...ledger.ticks, { position, at }], criteria: ledger.criteria };
}

/** The ledger with one more acceptance-criterion tick on it; the ledger handed in is left alone. */
export function recordCriterion(ledger: Ledger, position: number, at: string): Ledger {
  return { issue: ledger.issue, ticks: ledger.ticks, criteria: [...ledger.criteria, { position, at }] };
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
  return { issue: Number(read.issue), ticks: read.ticks ?? [], criteria: read.criteria ?? [] };
}

/** Take back every tick this run recorded, steps and criteria alike, leaving other bytes as written. */
export function untickRecorded(body: string, ledger: Ledger): string {
  let current = body;
  for (const tick of ledger.ticks) current = untickStep(current, tick.position) ?? current;
  for (const tick of ledger.criteria) current = untickCriterion(current, tick.position) ?? current;
  return current;
}

/**
 * Take back every tick a run recorded on its issue.
 *
 * Reads the issue as the tracker holds it now, so the marks are undone on top of whatever
 * else changed since, and returns the step positions it unticked. An empty record writes
 * nothing: a run that ticked no step has nothing to take back.
 */
export function untickRun(ledger: Ledger, tracker: Tracker): number[] {
  if (ledger.ticks.length === 0 && ledger.criteria.length === 0) return [];
  const body = tracker.read(ledger.issue).body;
  tracker.writeBody(ledger.issue, untickRecorded(body, ledger));
  return [...ledger.ticks, ...ledger.criteria].map((tick) => tick.position);
}
