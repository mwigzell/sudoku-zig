// transcript.mts — an agent's own words, folded into the run's log while it works.
//
// Sandcastle writes one transcript per agent session under the logs directory. A person watching a
// run wants those lines in the same stream as the steps, so this tails the newest transcript and
// hands each new line back as a `detail` event. The transcript stays on disk: this only mirrors it.

import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";

/** The newest agent transcript under `logsDir`, or `null` when no agent has written one yet. */
export function newestTranscript(logsDir: string): string | null {
  if (!existsSync(logsDir)) return null;
  const transcripts = readdirSync(logsDir)
    .filter((name) => name.startsWith("sandcastle-") && name.endsWith(".log"))
    .map((name) => join(logsDir, name))
    .sort((left, right) => statSync(left).mtimeMs - statSync(right).mtimeMs);
  return transcripts.length === 0 ? null : transcripts[transcripts.length - 1]!;
}

/** The role a transcript belongs to, read from its name: `implementer`, `reviewer` or `final-review`. */
export function transcriptRole(path: string): string {
  const name = path.slice(path.lastIndexOf("/") + 1);
  const match = /-(implementer|reviewer|final-review)-/u.exec(name);
  return match === null ? "agent" : match[1]!;
}

/** What a tailer has read so far, so each line is reported once even as the file grows. */
export type Tail = { path: string | null; offset: number };

/** A tailer that has read nothing yet. */
export function emptyTail(): Tail {
  return { path: null, offset: 0 };
}

/**
 * The lines written since the last read, and the tail to hand back next time.
 *
 * A new transcript starts from its beginning, which is what makes a step's first lines appear as
 * soon as the next agent takes over. Only complete lines are reported, so a half-written line waits.
 */
export function readNewLines(tail: Tail, logsDir: string): { lines: string[]; tail: Tail } {
  const path = newestTranscript(logsDir);
  if (path === null) return { lines: [], tail };
  const offset = path === tail.path ? tail.offset : 0;
  const text = readFileSync(path, "utf8");
  const end = text.lastIndexOf("\n");
  if (end === -1) return { lines: [], tail: { path, offset } };
  const fresh = text.slice(offset, end + 1);
  const lines = fresh.split("\n").filter((line) => line.trim().length > 0);
  return { lines, tail: { path, offset: end + 1 } };
}
