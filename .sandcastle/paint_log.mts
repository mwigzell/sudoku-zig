// paint_log.mts — a run's `run.log` as a person watching it should see it.
//
// `run.log` stays plain text on disk so it reads the same in an editor, a diff or a paste. This
// adds the colour and the section rules for a terminal: green for a tick or a pass, red for a stop,
// cyan for an agent taking over, and a rule opening each step so the reader can see where they are.

import { closeSync, openSync, readFileSync, readSync, statSync, watchFile } from "node:fs";
import { paintRunLogLine, type EventKind, type RunEvent } from "./events.mts";

/** One `run.log` line back into the event it was written from; `null` when it is not one. */
export function parseRunLogLine(line: string): RunEvent | null {
  const match = /^(\S+) \[([a-z-]+)(?: ([a-z-]+))?\] (.*)$/u.exec(line);
  if (match === null) return null;
  const [, at, kind, role, message] = match;
  const event: RunEvent = { at: at!, kind: kind as EventKind, message: message! };
  return role === undefined ? event : { ...event, role };
}

/** Paint one line, falling back to the raw text when it is not a log line. */
function paint(line: string, colour: boolean): string {
  const event = parseRunLogLine(line);
  return event === null ? line : paintRunLogLine(event, colour);
}

/** The last `count` non-empty lines of a file, without reading a long run's whole log. */
function lastLines(path: string, count: number): string[] {
  const size = statSync(path).size;
  if (size === 0) return [];
  const window = Math.min(size, 256 * 1024);
  const buffer = Buffer.alloc(window);
  const fd = openSync(path, "r");
  try {
    readSync(fd, buffer, 0, window, size - window);
  } finally {
    closeSync(fd);
  }
  const lines = buffer.toString("utf8").split("\n").filter((line) => line.length > 0);
  return lines.slice(Math.max(0, lines.length - count));
}

/** Print the last `count` lines of `path`, painted. */
export function printTail(path: string, count: number, colour: boolean): void {
  for (const line of lastLines(path, count)) console.log(paint(line, colour));
}

/** Follow `path`, painting each new line, until the process is interrupted. */
export function follow(path: string, count: number, colour: boolean): void {
  printTail(path, count, colour);
  let offset = statSync(path).size;
  watchFile(path, { interval: 500 }, () => {
    const size = statSync(path).size;
    // A log that shrank was replaced, so read it again from the top rather than from a stale offset.
    if (size < offset) offset = 0;
    if (size === offset) return;
    const fresh = readFileSync(path).subarray(offset, size).toString("utf8");
    offset = size;
    for (const line of fresh.split("\n").filter((line) => line.length > 0)) console.log(paint(line, colour));
  });
}

if (import.meta.main) {
  const args = process.argv.slice(2);
  const path = args.find((arg) => !arg.startsWith("--"));
  if (path === undefined) {
    console.error("usage: paint_log.mts <run.log> [lines] [--follow] [--colour]");
    process.exit(1);
  }
  const count = Number(args.find((arg) => /^\d+$/u.test(arg)) ?? 60);
  const colour = args.includes("--colour");
  if (args.includes("--follow")) follow(path, count, colour);
  else printTail(path, count, colour);
}
