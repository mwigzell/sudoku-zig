// seed.mts — one pristine session per run, forked by every role.
//
// The startup context — system prompt, the project's standing instructions, skills, tool schemas,
// and the domain model the seed prompt has it read — is identical for every step and every role,
// and it is the expensive part of a prompt. A run pays for it once here and forks this session per
// role, so each role's session carries the prefix and only its own instruction.
//
// Fork, not resume: a reviewer exists to falsify the implementer's work, so it must not inherit the
// implementer's transcript. Fork gives both — a warm prefix and a clean role.

import type { AgentProvider, SandboxRunResult } from "@ai-hero/sandcastle";

/** What a role needs to fork the seed: the session id, and the fork itself. */
export interface SeedSession {
  /** The captured session id, recorded on the run so a resumed run can fork the same seed. */
  readonly sessionId: string;
  /** Fork the seed with `prompt` as the role's instruction, leaving the parent session intact. */
  fork(prompt: string, options: ForkOptions): Promise<SandboxRunResult>;
}

/**
 * One role's fork: its name for the log.
 *
 * No prompt arguments: sandcastle refuses `promptArgs` on an inline prompt rather than ignoring
 * it, so the role's `{{KEY}}` values are substituted before the fork is made.
 */
export interface ForkOptions {
  /** Log name, so a run's transcripts stay distinguishable. */
  name: string;
}

/** The part of a sandbox the seed needs; the real `Sandbox` from sandcastle satisfies it. */
export interface SeedSandbox {
  run(options: SeedRunOptions): Promise<SandboxRunResult>;
}

/** The one run that opens the seed: a prompt file, one iteration, no prompt arguments. */
export interface SeedRunOptions {
  name: string;
  maxIterations: number;
  agent: AgentProvider;
  promptFile: string;
}

/** The session id a run captured, or `null` when the agent reported none. */
export function capturedSessionId(result: SandboxRunResult): string | null {
  const id = result.iterations.at(-1)?.sessionId;
  return id === undefined || id === "" ? null : id;
}

/**
 * Open the run's seed session and return the handle every role forks.
 *
 * `sandbox`: the run's sandbox, which owns the session store.
 * `agent`: the agent every role runs as.
 * `promptFile`: the seed prompt, which has the agent read the domain model before it answers.
 * Throws when the agent captured no session id or cannot fork: a run that cannot fork must say so
 * rather than quietly spawning cold for every step.
 */
export async function openSeed(sandbox: SeedSandbox, agent: AgentProvider, promptFile: string): Promise<SeedSession> {
  const opened = await sandbox.run({ name: "seed", maxIterations: 1, agent, promptFile });
  const sessionId = capturedSessionId(opened);
  if (sessionId === null) {
    throw new Error("the agent captured no session id for the run's seed, so no role could fork it");
  }
  if (opened.fork === undefined) {
    throw new Error("the agent cannot fork a session, so the run's roles would each spawn cold");
  }
  const fork = opened.fork;
  return {
    sessionId,
    fork: (prompt, options) => fork(prompt, { name: options.name }),
  };
}
