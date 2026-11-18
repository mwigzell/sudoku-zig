// main.test.mts — the entry's half of the parity window: the tracker call the pure parser cannot make.
//
// `plan.mts` reads the window and carries its issue number; whether that issue is still open is
// tracker work, so the entry asks `gh` once and refuses before a plan is printed or a run starts.
// The entry is exercised here against a stubbed tracker: the refusal paths cost nothing and cannot
// rot between gate runs, and a stub that rejects the state query proves the call is not made for an
// issue that declares no window.

import test from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { chmodSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

/** The repository root: the entry runs where it lives, never as a copy. */
const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
/** The entry under test. */
const ENTRY = join(ROOT, ".sandcastle", "main.mts");

/** The issue a run is aimed at; the window it declares belongs to another one. */
const AIM = 118;
/** The issue a window hangs on: the tracker decides whether it may be used. */
const WINDOW_ISSUE = 117;
/** A label the project's tracker uses for an issue triage has cleared. */
const READY = "ready-for-agent";

/** Steps the aim's body offers, so a window on them is a window the issue has. */
const STEPS = Array.from({ length: 5 }, (_, at) => `- [ ] **Step ${at + 1}:** work.`);

/**
 * A `gh` that answers from the environment instead of the network.
 *
 * The entry asks for `--json title,body,labels` to read the issue and `--json state -q .state` for a
 * window's issue. `GH_STATE` set to `unsupported` makes the state query fail, which is how a run that
 * declares no window proves it never asked.
 */
const GH_STUB = `#!/usr/bin/env bash
case "$*" in
  *"--json title,body,labels"*) cat "$GH_ISSUE_JSON" ;;
  *"--json state"*)
    if [ "\${GH_STATE:-}" = "unsupported" ]; then echo "gh: the state was not asked for" >&2; exit 1; fi
    echo "\${GH_STATE:-OPEN}"
    ;;
  *) echo "gh: unsupported arguments: $*" >&2; exit 1 ;;
esac
`;

/** What one entry run printed and exited with. */
interface EntryRun {
  status: number | null;
  stdout: string;
  stderr: string;
}

/**
 * Runs the entry's `--plan` on the aimed issue with `gh` stubbed.
 *
 * `state` is the answer the tracker gives for the window's issue; `window` is left off to run an
 * issue that declares none.
 */
function runPlan(state: string, window?: string): EntryRun {
  const dir = mkdtempSync(join(tmpdir(), "sandcastle-entry-"));
  const issueFile = join(dir, "issue.json");
  const body = [
    "## Problem",
    "",
    "Nothing.",
    "",
    ...(window === undefined ? [] : ["## Parity window", window, ""]),
    "## Steps",
    "",
    ...STEPS,
    "",
  ].join("\n");
  writeFileSync(issueFile, JSON.stringify({ title: "One vehicle", body, labels: [{ name: READY }] }));
  writeFileSync(join(dir, "gh"), GH_STUB);
  chmodSync(join(dir, "gh"), 0o755);
  try {
    const result = spawnSync(process.execPath, [ENTRY, "--issue", String(AIM), "--plan"], {
      cwd: ROOT,
      encoding: "utf8",
      env: { ...process.env, PATH: `${dir}:${process.env.PATH ?? ""}`, GH_ISSUE_JSON: issueFile, GH_STATE: state },
    });
    return { status: result.status, stdout: result.stdout, stderr: result.stderr };
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

test("a plan reads a declared window and prints it, once the tracker says the issue is open", () => {
  const run = runPlan("OPEN", `off for steps 1–4 (#${WINDOW_ISSUE}) — \`zig build verify -Dparity=off\``);
  const plan = run.stdout;

  assert.equal(run.status, 0, `the entry refused an open window: ${run.stderr}`);
  assert.match(plan, new RegExp(`window:\\s+parity off for steps 1–4 \\(#${WINDOW_ISSUE}\\)`, "u"));
  assert.match(plan, /branch:/u, "an accepted plan still prints the run's shape");
});

test("a plan refuses a window the tracker reports closed, and prints no run shape", () => {
  const run = runPlan("CLOSED", `off for steps 1–4 (#${WINDOW_ISSUE})`);

  assert.equal(run.status, 1, "a window on a closed issue must stop the run");
  assert.match(run.stderr, new RegExp(`refused:.*#${WINDOW_ISSUE}`, "u"), "the refusal names the issue");
  assert.match(run.stderr, /does not report open/u);
  assert.doesNotMatch(run.stdout, /branch:/u, "a refused window prints no branch to act on");
});

/** An issue with no window pays for no tracker call: the stub fails the query, the plan still passes. */
test("a plan for an issue that declares no window never asks the tracker about one", () => {
  const run = runPlan("unsupported");

  assert.equal(run.status, 0, `the entry asked for a window's state it did not need: ${run.stderr}`);
  assert.doesNotMatch(run.stdout, /window:/u);
});
