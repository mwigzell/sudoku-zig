// docs_framing.test.mts — the written half of the parity window.
//
// The window only works if the people and sessions that declare, triage and run an issue find the
// rule where they look: `AGENTS.md` for the standing rule, the tracker doc for the triage gate, and
// the harness manual for the gate a step inside a window runs. This test pins those claims, so the
// framing cannot fall out of one document while the code keeps its half.

import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { PROJECT } from "./project.mts";

/** The repository root: the documents are read where they live, never a copy. */
const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
/** The tracker's operating doc, which triage and the harness both point at. */
const TRACKER = "docs/agents/issue-tracker.md";

/** The text of one committed document. */
function docOf(file: string): string {
  return readFileSync(join(ROOT, file), "utf8");
}

/**
 * Asserts `file` states every claim, naming the first it does not.
 *
 * A claim is a regex plus the sentence it stands for, so a failure says which statement is missing
 * from which document rather than only that some prose moved.
 */
function states(file: string, claims: ReadonlyArray<readonly [RegExp, string]>): void {
  const text = docOf(file);
  for (const [claim, meaning] of claims) {
    assert.match(text, claim, `${file} does not say ${meaning}`);
  }
}

test("AGENTS.md carries the standing rule: a parity-observed contract change declares a step-scoped window", () => {
  states(PROJECT.standards.file, [
    [/Parity window/u, "an issue declares a `## Parity window`"],
    [/parity-observed contract/u, "which issues need one: those changing a contract parity observes"],
    [/ready-for-agent/u, "the window is what lets such an issue be readied for an agent"],
    [/zig build verify/u, "the plain gate is what a step outside the window runs"],
  ]);
});

test("the tracker doc makes the window a triage gate and takes it away when the issue closes", () => {
  states(TRACKER, [
    [/## Parity window/u, "the window has a section of its own"],
    [/ready-for-agent/u, "the window decides whether an issue reaches `ready-for-agent`"],
    [/not `ready-for-agent`|is not ready|no window/u, "an issue that needs one and lacks it is not ready"],
    [/[Cc]lose[sd]?\b.*(window|section)|(window|section).*clos/u, "the window is removed, or marked closed, when the issue closes"],
  ]);
});

test("the harness manual names the flag, the per-step command and the final-review check", () => {
  const harness = PROJECT.docs.harness;
  // The documented per-step command is the one the plan hands a windowed step, not a description of it.
  assert.ok(
    docOf(harness).includes(PROJECT.verifyOff(141)),
    `${harness} must show the window's gate exactly as the harness passes it: ${PROJECT.verifyOff(141)}`,
  );
  states(harness, [
    [/only ever passed inside|never outside/u, "the flag is passed only inside a declared window"],
    [/every other step|plain `zig build verify`/u, "every step outside the window runs the plain gate"],
    [/parity_restored/u, "the whole-branch verdict records parity restored"],
    [/host stops/u, "the host, not the reviewer, stops a run whose window was not restored"],
  ]);
});
