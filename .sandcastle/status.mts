// status.mts — where a run stands, read from what the run itself wrote.
//
// Nothing here asks git or GitHub: the run's directory holds its aim (`run.json`), its log
// (`events.jsonl`) and what it ticked (`ticks.json`), which is enough to say where it is.

import { existsSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { readEvents, type RunEvent } from "./events.mts";
import { readLedger, type Ledger } from "./ledger.mts";
import { readRunRecord, type RunRecord } from "./run_record.mts";

/** How long without an event a run stops counting as live. Heartbeats keep a working run inside it. */
export const STALLED_AFTER_MS = 90_000;

/** Where a run stands: what it is, how far it got, and whether anything is happening. */
export type RunStatus = {
  /** The run's stamp, which is also the name of its directory. */
  stamp: string;
  /** The issue it aims at and the branch it commits to, when it recorded them. */
  record: RunRecord | null;
  /** Every event the run logged, in order. */
  events: RunEvent[];
  /** What it ticked, when it ticked anything. */
  ledger: Ledger | null;
};

/** The newest run directory under `logsDir`, or `null` when the harness has never run here. */
export function newestRunDir(logsDir: string): string | null {
  if (!existsSync(logsDir)) return null;
  const runs = readdirSync(logsDir, { withFileTypes: true })
    .filter((entry) => entry.isDirectory() && /^\d+$/u.test(entry.name))
    .map((entry) => entry.name);
  if (runs.length === 0) return null;

  // A stamp is a millisecond clock, so the largest number is the newest run, whatever the mtimes say.
  runs.sort((left, right) => Number(left) - Number(right));
  return join(logsDir, runs[runs.length - 1]!);
}

/** Read one run's status from its directory. */
export function readStatus(stampDir: string): RunStatus {
  return {
    stamp: stampDir.split("/").pop() ?? stampDir,
    record: readRunRecord(stampDir),
    events: readEvents(stampDir),
    ledger: readLedger(join(stampDir, "ticks.json")),
  };
}

/** `live`, `stalled`, `finished`, or `not started` — told apart by the last event and its age. */
export function phase(status: RunStatus, now: number): "live" | "stalled" | "finished" | "not started" {
  const last = status.events.at(-1);
  if (last === undefined) return "not started";
  if (last.kind === "end" || last.kind === "stop") return "finished";
  return now - Date.parse(last.at) > STALLED_AFTER_MS ? "stalled" : "live";
}

/** The iteration the run is on, read from the last step line its loop logged. */
export function iteration(events: RunEvent[]): { at: number; of: number } {
  for (const event of [...events].reverse()) {
    const match = /^step (\d+)\/(\d+)/u.exec(event.message);
    if (match) return { at: Number(match[1]), of: Number(match[2]) };
  }
  return { at: 0, of: 0 };
}

/** Where the run goes next: the step after those it ticked, the final review, or nothing. */
export function nextUp(status: RunStatus, now: number): string {
  if (phase(status, now) === "finished") return "nothing, the run has ended";
  const { of } = iteration(status.events);
  if (of === 0) return "the first step";
  const ticked = status.ledger?.ticks.length ?? 0;
  return ticked < of ? `step ${ticked + 1} of ${of}` : "the whole-branch review";
}

/** The status as lines for the terminal: what the run is, how far it got, what it last said. */
export function formatStatus(status: RunStatus, now: number): string[] {
  const { at, of } = iteration(status.events);
  const last = status.events.at(-1);
  const ticks = status.ledger?.ticks.length ?? 0;
  const criteria = status.ledger?.criteria.length ?? 0;
  const started = status.record?.startedAt ? Date.parse(status.record.startedAt) : undefined;
  const ended = last === undefined ? undefined : Date.parse(last.at);
  const elapsed = started === undefined ? undefined : Math.max(0, Math.round(((ended ?? now) - started) / 1000));

  const lines = [
    `run:      ${status.stamp}`,
    `issue:    ${status.record === null ? "(not recorded)" : `#${status.record.issue}`}`,
    `branch:   ${status.record?.branch ?? "(not recorded)"}`,
    `phase:    ${phase(status, now)}`,
    `step:     ${of === 0 ? "none started" : `${at} of ${of}`}`,
    `next:     ${nextUp(status, now)}`,
    `ticks:    ${ticks} step(s), ${criteria} criterion(s)`,
  ];
  if (elapsed !== undefined) lines.push(`elapsed:  ${elapsed}s`);
  if (last !== undefined) lines.push(`last:     ${last.at} [${last.kind}] ${last.message}`);

  return lines;
}

if (import.meta.main) {
  const logsDir = process.argv[2] ?? ".sandcastle/logs";
  const stampDir = newestRunDir(logsDir);
  if (stampDir === null) {
    console.error(`No sandcastle run under ${logsDir}.`);
    console.error("Start one with: npm run sandcastle -- --issue <number>");
    process.exit(1);
  }
  process.stdout.write(`${formatStatus(readStatus(stampDir), Date.now()).join("\n")}\n`);
}
