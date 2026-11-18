// parity_window.test.mts — the gate's step-scoped parity window.
//
// `zig build verify -Dparity=off -Dparity-off-issue=N` is the only way to run the gate with the
// cross-front-end parity check omitted, and only while issue N is open. The guard that decides that
// is a script, so it is exercised here against a stubbed `gh`: the refusal paths cost nothing and
// cannot rot between gate runs. The build option itself is read from `zig build --help`, which
// compiles `build.zig`, so this fails on the day the graph stops declaring the flag.

import test from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { chmodSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

/** The repository root: the guard and the build graph are read where they live, never a copy. */
const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const GUARD = join(ROOT, "scripts", "verify-parity-off.sh");

/** Issues the stubbed tracker answers for: one open (this repository's window), one closed. */
const OPEN_ISSUE = "141";
const CLOSED_ISSUE = "140";
/** An issue the tracker refuses to resolve, standing in for a typo or a deleted issue. */
const UNKNOWN_ISSUE = "999999";
const BANNER = `── parity OFF (#${OPEN_ISSUE}) ──`;

/**
 * A `gh` that answers from a table instead of the network.
 *
 * The guard asks `gh issue view <N> --json state -q .state`, so the number is the third argument and
 * the state is the whole of the answer; anything else exits like a tracker that cannot resolve it.
 */
const GH_STUB = `#!/usr/bin/env bash
case "\${3:-}" in
  ${OPEN_ISSUE}) echo OPEN ;;
  ${CLOSED_ISSUE}) echo CLOSED ;;
  *) echo "gh: no such issue" >&2; exit 1 ;;
esac
`;

/** What one guard run printed and exited with. */
interface GuardRun {
  status: number | null;
  stdout: string;
  stderr: string;
}

/**
 * Runs the guard with the stubbed tracker in front of the real one.
 *
 * `issue` is left off to exercise the incomplete-flag path, which is what a build passes when
 * `-Dparity=off` arrives without `-Dparity-off-issue`.
 */
function runGuard(issue?: string): GuardRun {
  const stubDir = mkdtempSync(join(tmpdir(), "parity-window-"));
  writeFileSync(join(stubDir, "gh"), GH_STUB);
  chmodSync(join(stubDir, "gh"), 0o755);
  try {
    const args = issue === undefined ? [GUARD] : [GUARD, issue];
    const result = spawnSync("bash", args, {
      cwd: ROOT,
      encoding: "utf8",
      env: { ...process.env, PATH: `${stubDir}:${process.env.PATH ?? ""}` },
    });
    return { status: result.status, stdout: result.stdout, stderr: result.stderr };
  } finally {
    rmSync(stubDir, { recursive: true, force: true });
  }
}

test("the guard refuses parity off without an issue to hang the window on", () => {
  const run = runGuard();
  assert.notEqual(run.status, 0, "parity was turned off with no issue named");
  assert.match(run.stderr, /-Dparity-off-issue/u, "the refusal must name the missing flag");
  assert.equal(run.stdout.includes("parity OFF"), false, "a refused window must not print the OFF banner");
});

test("the guard refuses a window on a closed issue", () => {
  const run = runGuard(CLOSED_ISSUE);
  assert.notEqual(run.status, 0, `parity was turned off for closed issue #${CLOSED_ISSUE}`);
  assert.match(run.stderr, new RegExp(`#?${CLOSED_ISSUE}`, "u"), "the refusal must name the issue");
  assert.match(run.stderr, /CLOSED/u, "the refusal must say what the tracker answered");
});

test("the guard refuses a window it cannot resolve to an issue", () => {
  const run = runGuard(UNKNOWN_ISSUE);
  assert.notEqual(run.status, 0, `parity was turned off for unresolvable issue #${UNKNOWN_ISSUE}`);
  assert.match(run.stderr, new RegExp(`#${UNKNOWN_ISSUE}`, "u"), "the refusal must name the issue it could not resolve");
});

test("the guard accepts an open issue and says the check is off", () => {
  const run = runGuard(OPEN_ISSUE);
  assert.equal(run.status, 0, `the guard refused an open issue: ${run.stderr}`);
  assert.equal(run.stdout.includes(BANNER), true, `the OFF banner is missing from: ${run.stdout}`);
});

test("the gate declares the parity window options", () => {
  const result = spawnSync("zig", ["build", "--help"], { cwd: ROOT, encoding: "utf8" });
  assert.equal(result.status, 0, `zig build --help failed: ${result.stderr}`);
  assert.match(result.stdout, /-Dparity=\[enum\]/u, "build.zig declares no -Dparity option");
  assert.match(result.stdout, /-Dparity-off-issue=\[/u, "build.zig declares no -Dparity-off-issue option");
});
