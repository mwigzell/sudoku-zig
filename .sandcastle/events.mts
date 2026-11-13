// events.mts — the run's own log: one timestamped line per event.
//
// A run's stdout is what a person watches while it goes; the event log is what is left afterwards.
// Both files carry the same events: `events.jsonl` for a program to read (`status`, `watch`) and
// `run.log` for a person to read, one line each.

import { appendFileSync, existsSync, mkdirSync, readFileSync } from "node:fs";
import { join } from "node:path";

/** The kinds of event a run records. One per transition the loop makes. */
export type EventKind =
  | "run"
  | "step"
  | "agent-start"
  | "agent-end"
  | "heartbeat"
  | "verdict"
  | "tick"
  | "criterion"
  | "end"
  | "stop";

/** One line of the run's log: when it happened, what kind it was, and what it said. */
export type RunEvent = {
  /** ISO 8601 timestamp, so two logs can be read side by side. */
  at: string;
  kind: EventKind;
  message: string;
};

/** `events.jsonl`, the machine-readable half of the run's log. */
export function eventsPath(runsDir: string): string {
  return join(runsDir, "events.jsonl");
}

/** `run.log`, the half a person reads. */
export function runLogPath(runsDir: string): string {
  return join(runsDir, "run.log");
}

/** `event` as its `run.log` line: the time, the kind in brackets, then the message. */
export function formatRunLogLine(event: RunEvent): string {
  return `${event.at} [${event.kind}] ${event.message}`;
}

/**
 * Append one event to both halves of the run's log.
 *
 * `runsDir`: the run's directory, created when the run has not made it yet.
 * `event`: the transition, already timed by the caller so the two files agree.
 */
export function appendEvent(runsDir: string, event: RunEvent): void {
  mkdirSync(runsDir, { recursive: true });
  appendFileSync(eventsPath(runsDir), `${JSON.stringify(event)}\n`);
  appendFileSync(runLogPath(runsDir), `${formatRunLogLine(event)}\n`);
}

/** Every event the run recorded, in order; empty when the run left no log (or none yet). */
export function readEvents(runsDir: string): RunEvent[] {
  const file = eventsPath(runsDir);
  if (!existsSync(file)) return [];
  return readFileSync(file, "utf8")
    .split("\n")
    .filter((line) => line.trim().length > 0)
    .map((line) => JSON.parse(line) as RunEvent);
}
