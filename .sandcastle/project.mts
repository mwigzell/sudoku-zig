// project.mts — this repository's facts, the one place the harness's project policy is written.
//
// The generic modules (`plan`, `loop`, `verdict`, `standards`, `ledger`, `resume`, `events`,
// `report`) are handed this value and never name the toolchain, the standards file, the tracker
// label or a repository path themselves. Changing a fact here is the whole change.

import type { ProjectConfig } from "./project_config.mts";

export type { ProjectConfig } from "./project_config.mts";

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
  verify: "zig build verify",
  standards: { file: "AGENTS.md", section: "Coding standards" },
  tracker: { readyLabel: "ready-for-agent" },
  agent: { model: "ollama/sandcastle-worker" },
  paths: {
    runsDir: ".sandcastle/logs",
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
};
