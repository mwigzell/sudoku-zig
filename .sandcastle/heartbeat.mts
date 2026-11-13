// heartbeat.mts — a run says it is still working, without knowing what the work is doing.
//
// An agent session can think for minutes and log nothing, which is indistinguishable from a run that
// died. So the wait itself beats: every `everyMs` while the work is outstanding, then once more at the
// end with how long it took.

/** How often a waiting run says it is still waiting: well inside `status`'s stall threshold. */
export const HEARTBEAT_MS = 30_000;

/** What a heartbeat says: which wait it is, and how long it has been waiting. */
export function heartbeatLine(what: string, waitedMs: number): string {
  return `${what} (${Math.round(waitedMs / 1000)}s)`;
}

/**
 * Await `work` while beating every `everyMs` milliseconds.
 *
 * `beat`: called with the line to log, so the caller decides where a heartbeat goes.
 * Returns what `work` resolved to; rejects as `work` rejects, so a failure is still the caller's.
 */
export async function withHeartbeat<T>(
  what: string,
  work: Promise<T>,
  beat: (line: string) => void,
  everyMs: number = HEARTBEAT_MS,
): Promise<T> {
  const startedAt = Date.now();
  // `unref` so a beat still scheduled can never hold the process open once the work is done.
  const timer = setInterval(() => beat(heartbeatLine(what, Date.now() - startedAt)), everyMs);
  timer.unref();
  try {
    return await work;
  } finally {
    clearInterval(timer);
  }
}
