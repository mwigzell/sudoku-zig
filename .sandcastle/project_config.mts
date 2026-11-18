// project_config.mts — the shape of the facts a project hands the harness.
//
// The harness is project-neutral: it is told its gate command, where the standards live, which
// trait clears an issue for a run, which agent to start and which paths to work with. This module
// is the type alone, so a generic module can name the shape without reaching this repository's
// adapter; `project.mts` fills it in.

/**
 * Everything the harness must be told about the repository it runs in.
 *
 * These are project facts, not harness policy: a second consumer fills the same fields with its own
 * values and the modules that read them need no change. Paths are relative to the repository root
 * the harness runs from.
 */
export interface ProjectConfig {
  /** The gate command every step, step reviewer and whole-branch review runs and quotes. */
  verify: string;
  /** The file that owns the coding standards, and the level-2 section inside it that numbers them. */
  standards: { file: string; section: string };
  /** The tracker the host writes to, and the label triage puts on an issue a run may step. */
  tracker: { readyLabel: string };
  /** The agent every session of a run starts as. */
  agent: { model: string };
  /** Where the harness keeps its per-run logs, agent token, prompts and verdict files. */
  paths: {
    /** Root of the per-run directories: one subdirectory per run stamp. */
    runsDir: string;
    /** The file holding the token the sandboxed agents call the tracker with. */
    env: string;
    /** What each role's agent session is told, by role. */
    prompts: { implement: string; review: string; finalReview: string };
    /** Where the agents write their verdicts inside the worktree, by kind. */
    verdicts: { step: string; criteria: string; standards: string };
  };
  /** Where a reader finds the harness's operating manual and its decision records. */
  docs: { harness: string; decisions: string };
}
