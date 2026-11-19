// session_cost.mts — what an agent run cost, read from the session file the agent wrote.
//
// sandcastle's `pi` provider reports a session id but no token usage: only its Claude Code provider
// implements `parseSessionUsage`, so `iteration.usage` is always undefined for pi. The figures are
// still on disk — pi records `usage` on every assistant message — so the harness reads them itself
// rather than reporting a cost it does not have.

import { existsSync, readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";

/** One agent run's tokens, summed over every assistant message in its session. */
export interface SessionCost {
  /** Tokens the model read that were not cached. */
  inputTokens: number;
  /** Tokens written to the prompt cache. */
  cacheCreationInputTokens: number;
  /** Tokens read from the prompt cache, which a fork's shared prefix mostly is. */
  cacheReadInputTokens: number;
  /** Tokens the model wrote. */
  outputTokens: number;
}

/** The usage block pi writes on an assistant message; every field optional, as a provider may omit one. */
type Usage = {
  input?: number;
  output?: number;
  cacheRead?: number;
  cacheWrite?: number;
};

/** The session file whose name ends with `sessionId`, searched one level down from `sessionsDir`. */
export function sessionFile(sessionsDir: string, sessionId: string): string | null {
  if (!existsSync(sessionsDir)) return null;
  for (const project of readdirSync(sessionsDir, { withFileTypes: true })) {
    if (!project.isDirectory()) continue;
    const dir = join(sessionsDir, project.name);
    for (const name of readdirSync(dir)) {
      // pi names a session `<stamp>_<id>.jsonl`, so the id is matched as the tail of the stem.
      if (name.endsWith(`_${sessionId}.jsonl`)) return join(dir, name);
    }
  }
  return null;
}

/**
 * Sum the token usage of every assistant message in a session's JSONL content.
 *
 * A line that is not JSON, or a message without usage, is skipped: a session file is an append log
 * and a half-written last line is normal. Returns `null` when the session recorded no usage at all,
 * so the caller says "no usage" rather than claiming a run cost nothing.
 */
export function sumSessionUsage(content: string): SessionCost | null {
  const total: SessionCost = { inputTokens: 0, cacheCreationInputTokens: 0, cacheReadInputTokens: 0, outputTokens: 0 };
  let seen = 0;
  for (const line of content.split("\n")) {
    if (line.trim().length === 0) continue;
    let parsed: unknown;
    try {
      parsed = JSON.parse(line);
    } catch {
      continue;
    }
    const message = (parsed as { message?: { role?: string; usage?: Usage } }).message;
    if (message?.role !== "assistant" || message.usage === undefined) continue;
    const usage = message.usage;
    seen += 1;
    total.inputTokens += usage.input ?? 0;
    total.outputTokens += usage.output ?? 0;
    total.cacheReadInputTokens += usage.cacheRead ?? 0;
    total.cacheCreationInputTokens += usage.cacheWrite ?? 0;
  }
  return seen === 0 ? null : total;
}

/** What a run's session cost, or `null` when its session file holds no usage to read. */
export function readSessionCost(sessionsDir: string, sessionId: string | null): SessionCost | null {
  if (sessionId === null) return null;
  const file = sessionFile(sessionsDir, sessionId);
  if (file === null) return null;
  return sumSessionUsage(readFileSync(file, "utf8"));
}
