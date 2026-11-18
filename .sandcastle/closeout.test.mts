// closeout.test.mts — the host's last phase: a run whose branch is Android-scope proves it on a device.
//
// The device suite is outside `zig build verify`, so the entry derives the scenarios the branch owes,
// runs the project's gate for exactly those and leaves the record in the run directory. The gate is
// injected here, so the closeout's decisions are proven without a device: what it runs, what it keeps,
// and the stop it reports when the gate fails, the record is short, or no scenario names the change.

import test from "node:test";
import assert from "node:assert/strict";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { AndroidConfig } from "./project_config.mts";
import { evidencePath, type BranchDiff, type Evidence } from "./android_evidence.mts";
import { closeoutFor, type CloseoutRequest, type GateOutcome, type GateRunner } from "./closeout.mts";

/** The issue the fixture run was aimed at. */
const ISSUE = 142;
/** The commit the run's branch is at: the only one a record can prove. */
const HEAD = "532319a1b2c3";

/** The Android facts an ordinary project hands in, small enough to read in one glance. */
const ANDROID: AndroidConfig = {
  testFile: "src/android/test/FileBridgeTest.java",
  surface: ["src/android/jni_host.zig"],
  code: ["src/android/"],
  smoke: "coreAndJsLogLinesReachLogcat",
  gate: {
    command: ({ methods, evidenceOut, issue }) =>
      `fake-gate --methods=${methods.join(",")} --evidence-out=${evidenceOut} --issue=${issue}`,
    startScript: "scripts/fake-emulator-start.sh",
  },
};

/** A diff line adding one scenario method, as git writes it. */
const ADDED = (method: string): string => `+    public void ${method}() throws IOException {`;

/** One branch: the paths it touches and the diff of the scenario file. */
function branch(touched: readonly string[], scenarios = ""): BranchDiff {
  return { touched, scenarios };
}

/** A passing record for `methods` on the branch head, which individual tests spoil one field at a time. */
function passing(methods: readonly string[]): Evidence {
  return {
    issue: ISSUE,
    required: methods.map((method) => ({ method, why: "required by this run" })),
    methods,
    command: "scripts/android-test.sh emulator-5554",
    result: "passed",
    device: "emulator-5554",
    duration_s: 12,
    commit: HEAD,
    clean_tree: true,
    at: "2026-01-01T00:00:00Z",
  };
}

/** A gate runner that records each command and, when given a record, writes it where the gate would. */
function fakeGate(
  file: string | null,
  record: Evidence | null,
  outcome: { ok?: boolean; output?: string } = {},
): { commands: string[]; run: GateRunner } {
  const commands: string[] = [];
  return {
    commands,
    run: (command: string): GateOutcome => {
      commands.push(command);
      if (file !== null && record !== null) writeFileSync(file, `${JSON.stringify(record, null, 2)}\n`);
      return { ok: outcome.ok ?? true, output: outcome.output ?? "" };
    },
  };
}

/** A temporary run directory, cleaned up by the caller's `finally`. */
function fixture(): { root: string; runsDir: string } {
  const root = mkdtempSync(join(tmpdir(), "sandcastle-closeout-"));
  const runsDir = join(root, "logs", "1");
  mkdirSync(runsDir, { recursive: true });
  return { root, runsDir };
}

/** The closeout request for a branch, with the run's own directory and head. */
function request(runsDir: string, diff: BranchDiff, body = ""): CloseoutRequest {
  return { runsDir, issue: ISSUE, body, base: "b649adc", head: HEAD, android: ANDROID, diff };
}

test("a branch that changes no Android code is ready for accept with no device run", () => {
  const { root, runsDir } = fixture();
  try {
    const gate = fakeGate(null, null);

    const result = closeoutFor(request(runsDir, branch(["docs/agents/sandcastle.md"])), gate.run);

    assert.equal(result.kind, "ready");
    assert.deepEqual(gate.commands, [], "no Android code changed, so a device run would prove nothing");
    assert.equal(result.kind === "ready" && result.evidence, null, "there is no record to point at");
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("an Android branch proves its added scenario with the project's gate, and keeps the record", () => {
  const { root, runsDir } = fixture();
  try {
    const file = evidencePath(runsDir);
    const gate = fakeGate(file, passing(["aChangedScenario"]));

    const result = closeoutFor(
      request(runsDir, branch([ANDROID.testFile], ADDED("aChangedScenario"))),
      gate.run,
    );

    assert.equal(result.kind, "ready");
    assert.equal(result.kind === "ready" && result.evidence, file, "the run directory holds the record accept reads");
    assert.ok(existsSync(file), "the record the gate wrote is what the run keeps");
    assert.equal(gate.commands.length, 1, "one gate run proves the whole set");
    assert.match(gate.commands[0] ?? "", /--methods=aChangedScenario/u, "the branch's own method is what the gate runs");
    assert.ok(
      (gate.commands[0] ?? "").includes(file),
      "the gate is told where the run directory's record goes",
    );
    assert.match(gate.commands[0] ?? "", new RegExp(`--issue=${ISSUE}`, "u"), "the record names the issue it proves");
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("a branch that changes Android code but no scenario owes the pinned smoke", () => {
  const { root, runsDir } = fixture();
  try {
    const gate = fakeGate(evidencePath(runsDir), passing([ANDROID.smoke]));

    // The gate's own tooling, not the app surface: no scenario changed, so the smoke is the proof.
    const result = closeoutFor(request(runsDir, branch(["src/android/gate.zig"])), gate.run);

    assert.equal(result.kind, "ready");
    assert.match(
      gate.commands[0] ?? "",
      new RegExp(`--methods=${ANDROID.smoke}`, "u"),
      "tooling work is proved by the one pinned method, not by a method picked per run",
    );
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("a declared scenario is what a bridge change runs, and it names the gate's methods", () => {
  const { root, runsDir } = fixture();
  try {
    const gate = fakeGate(evidencePath(runsDir), passing(["freshAppWithAutoSave"]));

    const result = closeoutFor(
      request(runsDir, branch(["src/android/jni_host.zig"]), "## Android scenarios\n\n`freshAppWithAutoSave` — the save path this change rewrites\n"),
      gate.run,
    );

    assert.equal(result.kind, "ready");
    assert.match(gate.commands[0] ?? "", /--methods=freshAppWithAutoSave/u);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("no device stops the run with the start-script instruction, and it is never a skip", () => {
  const { root, runsDir } = fixture();
  try {
    const missingDevice = `android-gate: no device attached — start one with ${ANDROID.gate.startScript}; this run is never skipped\n`;
    const gate = fakeGate(null, null, { ok: false, output: missingDevice });

    const result = closeoutFor(request(runsDir, branch([ANDROID.testFile], ADDED("aChangedScenario"))), gate.run);

    assert.equal(result.kind, "stopped");
    assert.match(result.kind === "stopped" ? result.message : "", /^stopped: device — /u, "the run says which phase stopped it");
    assert.ok(
      (result.kind === "stopped" ? result.message : "").includes(ANDROID.gate.startScript),
      "a missing device is a stop that names the script that starts one",
    );
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("a record that proves another commit is a stop, not a ready run", () => {
  const { root, runsDir } = fixture();
  try {
    const stale = { ...passing(["aChangedScenario"]), commit: "0f0f0f0" };
    const gate = fakeGate(evidencePath(runsDir), stale);

    const result = closeoutFor(request(runsDir, branch([ANDROID.testFile], ADDED("aChangedScenario"))), gate.run);

    assert.equal(result.kind, "stopped");
    assert.match(
      result.kind === "stopped" ? result.message : "",
      /not this branch's head/u,
      "a green gate whose record proves another commit leaves accept with nothing to rest on",
    );
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("a changed Android surface with no scenario stops before any gate runs", () => {
  const { root, runsDir } = fixture();
  try {
    const gate = fakeGate(null, null);

    const result = closeoutFor(request(runsDir, branch(["src/android/jni_host.zig"])), gate.run);

    // The surface change with no scenario is the stop; the smoke would hide it, so it is not run.
    assert.equal(result.kind, "stopped");
    assert.match(result.kind === "stopped" ? result.message : "", /no scenario names this change/u);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

/**
 * The entry is the phase's only caller: the loop has no sandbox to leave, and the run the phase
 * needs costs an agent, so the wiring is pinned here rather than driven.
 */
test("the entry runs the closeout only after a green loop, and returns what it decides", () => {
  const entry = readFileSync(new URL("./main.mts", import.meta.url), "utf8");
  const loop = entry.indexOf("await runSteps(");
  const gate = entry.indexOf("return androidCloseout(");

  assert.ok(loop !== -1, "the entry runs the step loop");
  assert.ok(gate > loop, "the closeout runs after the loop returns, never before it");
  assert.match(
    entry.slice(loop, gate),
    /if \(steps !== 0\) return steps;/u,
    "a stopped loop is returned as it is, so no device run follows it",
  );
  assert.match(entry.slice(gate), /worktree: sandbox\.worktreePath/u, "the gate proves the run's own worktree, not the host's checkout");
});
