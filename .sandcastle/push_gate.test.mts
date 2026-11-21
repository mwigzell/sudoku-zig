// push_gate.test.mts — the lanes a push must prove, the stop at the first failure, and the record.
//
// The push gate is shell and one of its lanes needs a device for minutes, so the tests drive the
// lanes through their overrides: what is proven here is the order, the stop and the record shape,
// never a claim that the device suite itself ran.

import test from "node:test";
import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

/** The repository root: the gate runs where it lives, never from a copy. */
const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
/** The gate script under test. */
const GATE = join(ROOT, "scripts/push-gate.sh");
/** The manual a reader finds the gate in. */
const DOC = "docs/agents/push-gate.md";
/** The environment variable that moves the per-lane record, so a test never writes the real one. */
const RECORD_DIR_ENV = "PUSH_GATE_RECORD_DIR";
/** The environment variable that moves the coverage summary, so a test never reads the real one. */
const COVERAGE_JSON_ENV = "PUSH_GATE_COVERAGE_JSON";
/** The environment variables that move the warm-timing state, so a test never reads the real one. */
const VERIFY_TIMING_ENV = "PUSH_GATE_VERIFY_TIMING";
const SLOW_TIMING_ENV = "PUSH_GATE_SLOW_TIMING";

/** One lane as `--lanes` and the record write it. */
interface Lane {
  name: string;
  command: string;
  status?: string;
  duration_s?: number | null;
  warm_s?: number | null;
}

/** The record one push-gate run wrote, keyed by the commit it names. */
interface PushRecord {
  commit: string;
  result: string;
  coverage_percent: number | null;
  lanes: Lane[];
}

/** The commit this test run's HEAD names: the record belongs to it, not to a fresh checkout. */
function head(): string {
  return execFileSync("git", ["rev-parse", "HEAD"], { cwd: ROOT, encoding: "utf8" }).trim();
}

/** The environment without this gate's overrides, so a default lane list is read uninfluenced. */
function bareEnv(): NodeJS.ProcessEnv {
  const env = { ...process.env };
  for (const name of ["PUSH_GATE_VERIFY_CMD", "PUSH_GATE_SLOW_CMD", "PUSH_GATE_DEVICE_CMD", "PUSH_GATE_EMULATOR_CMD", RECORD_DIR_ENV, COVERAGE_JSON_ENV, VERIFY_TIMING_ENV, SLOW_TIMING_ENV]) delete env[name];
  return env;
}

/** Lane commands that log their own name and exit with the status the caller gives them. */
function fakeLanes(log: string, statuses: { verify?: number; slow?: number; device?: number } = {}): Record<string, string> {
  const lane = (name: "verify" | "slow" | "device"): string =>
    `printf '${name}\\n' >> '${log}'; exit ${statuses[name] ?? 0}`;
  return {
    PUSH_GATE_VERIFY_CMD: lane("verify"),
    PUSH_GATE_SLOW_CMD: lane("slow"),
    PUSH_GATE_DEVICE_CMD: lane("device"),
    PUSH_GATE_EMULATOR_CMD: `printf 'emulator\\n' >> '${log}'; exit 0`,
    [COVERAGE_JSON_ENV]: "/nonexistent/coverage.json",
    [VERIFY_TIMING_ENV]: "/nonexistent/verify-timing.json",
    [SLOW_TIMING_ENV]: "/nonexistent/slow-timing.json",
  };
}

/** Run the gate with fake lanes and a borrowed record directory. */
function runGate(recordDir: string, env: Record<string, string>): ReturnType<typeof spawnSync> {
  return spawnSync("bash", [GATE], {
    cwd: ROOT,
    encoding: "utf8",
    env: { ...process.env, [RECORD_DIR_ENV]: recordDir, ...env },
  });
}

/** The record the run left for this HEAD. */
function recordIn(recordDir: string): PushRecord {
  const path = join(recordDir, `${head()}.json`);
  assert.ok(existsSync(path), `the gate must record its lanes at ${path}`);
  return JSON.parse(readFileSync(path, "utf8")) as PushRecord;
}

/** A temporary record directory and lane log, cleaned up by the caller's `finally`. */
function fixture(): { root: string; recordDir: string; log: string } {
  const root = mkdtempSync(join(tmpdir(), "push-gate-"));
  return { root, recordDir: join(root, "records"), log: join(root, "lanes.log") };
}

/** The lane names the log holds, in the order they ran. */
function lanesRun(log: string): string[] {
  if (!existsSync(log)) return [];
  return readFileSync(log, "utf8").split("\n").filter((line) => line.length > 0);
}

test("the gate's lanes are verify, verify-slow and the full device suite, cheapest first", () => {
  const lanes = JSON.parse(execFileSync("bash", [GATE, "--lanes"], { cwd: ROOT, encoding: "utf8", env: bareEnv() })) as Lane[];

  assert.deepEqual(
    lanes.map((lane) => lane.name),
    ["verify", "verify-slow", "android-device"],
  );
  assert.deepEqual(
    lanes.map((lane) => lane.command),
    ["zig build verify", "zig build verify-slow", "zig build android-test"],
    "the device lane is the whole suite; a filter would prove a method, not a push",
  );
});

test("a clean push runs every lane in order and records each one passed", () => {
  const { root, recordDir, log } = fixture();
  try {
    const run = runGate(recordDir, fakeLanes(log));

    assert.equal(run.status, 0, `a passing push gate exits zero; it printed:\n${run.stdout}${run.stderr}`);
    assert.deepEqual(lanesRun(log), ["verify", "slow", "emulator", "device"], "the device lane starts its emulator, then runs the suite");
    const record = recordIn(recordDir);
    assert.equal(record.commit, head(), "the record names the commit it proved");
    assert.equal(record.result, "passed");
    assert.equal(record.coverage_percent, null, "an overridden verify lane leaves no coverage.json, so the record says null");
    assert.deepEqual(
      record.lanes.map((lane) => [lane.name, lane.warm_s]),
      [
        ["verify", null],
        ["verify-slow", null],
        ["android-device", undefined],
      ],
      "an overridden lane leaves no timing state, so verify and verify-slow carry null warm_s and the device lane none",
    );
    assert.deepEqual(
      record.lanes.map((lane) => [lane.name, lane.status]),
      [
        ["verify", "passed"],
        ["verify-slow", "passed"],
        ["android-device", "passed"],
      ],
    );
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("the first failing lane stops the gate and the record says which lanes never ran", () => {
  const { root, recordDir, log } = fixture();
  try {
    const run = runGate(recordDir, fakeLanes(log, { slow: 1 }));

    assert.notEqual(run.status, 0, "a failed lane is a failed push gate");
    assert.deepEqual(lanesRun(log), ["verify", "slow"], "a later lane costs minutes, so a failure stops the run");
    const record = recordIn(recordDir);
    assert.equal(record.result, "failed");
    assert.deepEqual(
      record.lanes.map((lane) => [lane.name, lane.status]),
      [
        ["verify", "passed"],
        ["verify-slow", "failed"],
        ["android-device", "skipped"],
      ],
    );
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("the manual makes the gate the only way to push, and names what it runs", () => {
  const text = readFileSync(join(ROOT, DOC), "utf8");
  const claims: ReadonlyArray<readonly [RegExp, string]> = [
    [/zig build push-gate/u, "the gate's command"],
    [/only way to push|push waits/u, "a push waits for the gate"],
    [/cheapest first/u, "the lanes run cheapest first"],
    [/first failure/u, "a failure stops the run"],
    [/verify-slow/u, "the slow suite is a lane"],
    [/android-test/u, "the full device suite is a lane"],
    [/\.push-gate/u, "where the per-lane record lives"],
    [/never skip|does not skip/u, "a device that fails to boot fails the run rather than skipping it"],
    [/scripts\/android-emulator-start\.sh/u, "the device lane starts its own emulator"],
  ];
  for (const [claim, meaning] of claims) assert.match(text, claim, `${DOC} does not say ${meaning}`);

  const standards = readFileSync(join(ROOT, "AGENTS.md"), "utf8");
  assert.match(standards, /zig build push-gate/u, "AGENTS.md is where a session looks for the gates, so it names this one");
});
