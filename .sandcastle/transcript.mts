// transcript.mts — an agent's own words, folded into the run's log while it works.
//
// Sandcastle writes one transcript per agent session under the logs directory. A person watching a
// run wants those lines in the same stream as the steps, so this tails the newest transcript and
// hands each new line back as a `detail` event. The transcript stays on disk: this only mirrors it.

import { existsSync, readdirSync, readFileSync, statSync, watch, type FSWatcher } from "node:fs";
import { join } from "node:path";

/** How often the mirror retries when a filesystem watch cannot be set up at all. */
const FALLBACK_POLL_MS = 5_000;

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

/**
 * Call `onLine` whenever a transcript under `logsDir` grows, and return the function that stops it.
 *
 * The directory is watched rather than the file, because each agent writes a new transcript and a
 * watch on the old one would outlive it. A watch that cannot be set up falls back to a slow timer:
 * the mirror is a convenience, and losing its immediacy must never cost the run its log.
 * `onLine` is called once immediately, so a transcript that already has lines is not missed.
 */
export function watchTranscript(logsDir: string, onLine: () => void): () => void {
  let watcher: FSWatcher | null = null;
  let timer: NodeJS.Timeout | null = null;
  const wake = (): void => {
    try {
      onLine();
    } catch {
      // A transcript that is being rotated can vanish mid-read; the next write reads it again.
    }
  };
  try {
    watcher = watch(logsDir, { persistent: false }, wake);
    // A watcher that errors is dead; the timer takes over so the log keeps filling.
    watcher.on("error", () => {
      watcher?.close();
      watcher = null;
      timer ??= setInterval(wake, FALLBACK_POLL_MS);
      timer.unref();
    });
  } catch {
    timer = setInterval(wake, FALLBACK_POLL_MS);
    timer.unref();
  }
  wake();
  return () => {
    watcher?.close();
    if (timer !== null) clearInterval(timer);
  };
}
