// project.mts — this repository's facts, the one place the harness's project policy is written.
//
// The generic modules (`plan`, `loop`, `verdict`, `standards`, `ledger`, `resume`, `events`,
// `report`) are handed this value and never name the toolchain, the standards file, the tracker
// label or a repository path themselves. Changing a fact here is the whole change.

import type { ProjectConfig } from "./project_config.mts";

export type { ProjectConfig } from "./project_config.mts";

/** The one gate command, so the parity-off variant is the same gate with one flag added. */
const VERIFY = "zig build verify";

/**
 * This repository, as the harness sees it.
 *
 * - `zig build verify` is the gate: tests, formatting, the standards script and coverage in one
 *   command, which is why the reviewers must run it rather than a subset.
 * - `AGENTS.md` owns the rules the standards lens answers, under its `## Coding standards` heading;
 *   the harness parses that file rather than keeping a copy of the list.
 * - `ready-for-agent` is triage's word that an issue is specified enough to step.
 */
export const PROJECT: ProjectConfig = {
  verify: VERIFY,
  // The parity check is the one step a window may omit, and the flag names the issue that window belongs to.
  verifyOff: (issue) => `${VERIFY} -Dparity=off -Dparity-off-issue=${issue}`,
  // The line that check prints when it passed, which the whole-branch verdict must quote, and the
  // example the final-review prompt shows so the reviewer knows which line to copy.
  parity: { line: /^✓ parity: \d+ scenario\(s\) on native, web and Android$/u, sample: "✓ parity: 12 scenario(s) on native, web and Android" },
  standards: { file: "AGENTS.md", section: "Coding standards" },
  tracker: { readyLabel: "ready-for-agent" },
  agent: { model: "ollama/sandcastle-worker" },
  paths: {
    runsDir: ".sandcastle/logs",
    archive: ".scratch/sudoku/issues",
    env: ".sandcastle/.env",
    prompts: {
      implement: ".sandcastle/implement-prompt.md",
      review: ".sandcastle/review-prompt.md",
      finalReview: ".sandcastle/final-review-prompt.md",
    },
    verdicts: {
      step: ".sandcastle/verdict.json",
      criteria: ".sandcastle/verdict-acs.json",
      standards: ".sandcastle/verdict-standards.json",
    },
  },
  docs: { harness: "docs/agents/sandcastle.md", decisions: "docs/adr" },
  // The device suite `zig build verify` cannot reach, the app paths whose change owes a scenario,
  // and the one pinned method that proves tooling work which changes no scenario at all.
  android: {
    testFile: "src/android/test/FileBridgeTest.java",
    surface: [
      "src/android/jni_host.zig",
      "src/entry_android.zig",
      "src/android/bootstrap/",
      "src/wasm/android_bridge.js",
    ],
    code: [
      "src/android/",
      "src/entry_android.zig",
      "src/wasm/android_bridge.js",
      "build/android.zig",
      "scripts/android-test.sh",
    ],
    smoke: "coreAndJsLogLinesReachLogcat",
  },
};
