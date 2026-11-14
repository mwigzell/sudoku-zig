// watch.mts — follow a run while it goes.
//
// `status` answers once; this answers until the run ends. It reads the same log on a poll rather
// than watching the filesystem, because the log is one small file and a poll cannot miss an event.

import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";
import { newestRunDir, phase, readStatus } from "./status.mts";
import type { RunEvent } from "./events.mts";

/** How often the watched log is read, in milliseconds. A heartbeat every 30s is well inside this. */
export const POLL_MS = 1_000;

/** What a follow-up read adds: the events the reader has not seen, and how many it has now seen. */
export function newLines(events: RunEvent[], seen: number): { lines: string[]; seen: number } {
  return {
    lines: events.slice(seen).map((event) => `${event.at} [${event.kind}] ${event.message}`),
    seen: events.length,
  };
}

/** The lines of `text` past `offset`, and the offset to resume from: only complete lines count. */
export function newTextLines(text: string, offset: number): { lines: string[]; offset: number } {
  const fresh = text.slice(offset);
  const end = fresh.lastIndexOf("\n");
  if (end === -1) return { lines: [], offset };
  return { lines: fresh.slice(0, end).split("\n"), offset: offset + end + 1 };
}

/** The newest agent transcript a run has written, so a watcher follows the agent that is running now. */
export function activeAgentLog(logsDir: string): string | null {
  if (!existsSync(logsDir)) return null;
  const logs = readdirSync(logsDir)
    .filter((name) => name.startsWith("sandcastle-") && name.endsWith(".log"))
    .map((name) => join(logsDir, name))
    .sort((left, right) => statSync(left).mtimeMs - statSync(right).mtimeMs);
  return logs.length === 0 ? null : logs[logs.length - 1]!;
}

if (import.meta.main) {
  const logsDir = process.argv[2] ?? ".sandcastle/logs";
  const stampDir = newestRunDir(logsDir);
  if (stampDir === null) {
    console.error(`No sandcastle run under ${logsDir}.`);
    process.exit(1);
  }

  let seen = 0;
  let agentLog = activeAgentLog(logsDir);
  let agentOffset = 0;
  // The first line names the run; after that only what is new is printed, so the terminal reads as a log.
  console.log(`watching ${stampDir} (Ctrl-C to stop watching; the run keeps going)`);

  const tick = (): boolean => {
    const status = readStatus(stampDir);
    for (const line of newLines(status.events, seen).lines) console.log(line);
    seen = status.events.length;

    // The agent's transcript is the other half of "what is happening": the ledger says which step,
    // the transcript says what the agent is doing about it.
    const newest = activeAgentLog(logsDir);
    if (newest !== agentLog) {
      agentLog = newest;
      agentOffset = 0;
    }
    if (agentLog !== null) {
      const text = readFileSync(agentLog, "utf8");
      const read = newTextLines(text, agentOffset);
      for (const line of read.lines) if (line.trim().length > 0) console.log(`agent> ${line}`);
      agentOffset = read.offset;
    }

    const current = phase(status, Date.now());
    if (current === "finished") {
      console.log(`[watch] the run is ${current}`);
      return true;
    }
    return false;
  };

  if (tick()) process.exit(0);
  const timer = setInterval(() => {
    if (tick()) {
      clearInterval(timer);
      process.exit(0);
    }
  }, POLL_MS);
}
