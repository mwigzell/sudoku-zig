// project_config.mts — the shape of the facts a project hands the harness.
//
// The harness is project-neutral: it is told its gate command, where the standards live, which
// trait clears an issue for a run, which agent to start and which paths to work with. This module
// is the type alone, so a generic module can name the shape without reaching this repository's
// adapter; `project.mts` fills it in.

/**
 * The Android facts a project hands in: which scenario file holds its device suite, which paths
 * make a branch Android-scope, and the one scenario that proves a branch that changes none.
 *
 * `zig build verify` runs no Android test, so the device proof of an Android change is a recorded
 * run of these methods. Keeping the paths and the smoke here means the harness derives the
 * requirement from the branch and never names a repository path of its own.
 */
export interface AndroidConfig {
  /** The scenario file whose added or changed methods are a branch's own proof. */
  testFile: string;
  /** Paths of the Android app itself: changing one proves nothing without a scenario. */
  surface: readonly string[];
  /** Paths that make a branch Android-scope: a change to any of them owes a device run. */
  code: readonly string[];
  /** The one method that proves a branch which adds or changes no scenario. */
  smoke: string;
}

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
  /**
   * The same gate with this project's cross-arm parity check off, for the steps a declared parity
   * window covers. `issue` is the window's own issue, so the gate can refuse a closed one.
   */
  verifyOff: (issue: number) => string;
  /**
   * The cross-arm parity check the gate runs. `line` is the shape of the line that check prints
   * when it passed: the whole-branch verdict quotes it, and the host reads that citation against
   * this shape. `sample` is the same line as a prompt shows it, carrying a count of its own.
   */
  parity: { line: RegExp; sample: string };
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
    /** Where an accepted run's verdicts are copied for the record: one directory per issue. */
    archive: string;
    /** The file holding the token the sandboxed agents call the tracker with. */
    env: string;
    /** What each role's agent session is told, by role. */
    prompts: { implement: string; review: string; finalReview: string };
    /** Where the agents write their verdicts inside the worktree, by kind. */
    verdicts: { step: string; criteria: string; standards: string };
  };
  /** Where a reader finds the harness's operating manual and its decision records. */
  docs: { harness: string; decisions: string };
  /** The device suite a branch of this project must prove before it can be accepted. */
  android: AndroidConfig;
}
