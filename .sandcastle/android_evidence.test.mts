// android_evidence.test.mts — what an Android-scope branch owes, and how a run's evidence is judged.
//
// The required set is a property of the branch: the scenarios it adds or changes, the ones the issue
// declares, and the pinned smoke when it changes none. A run is proof only when its record is present,
// passed, names this commit, came from a clean tree and covers every required method.

import test from "node:test";
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { AndroidConfig } from "./project_config.mts";
import {
  checkAndroidEvidence,
  evidencePath,
  requiredScenarios,
  type BranchDiff,
  type Evidence,
} from "./android_evidence.mts";

/** The Android facts an ordinary project hands in, small enough to read in one glance. */
const ANDROID: AndroidConfig = {
  testFile: "src/android/test/FileBridgeTest.java",
  surface: ["src/android/jni_host.zig"],
  code: ["src/android/"],
  smoke: "coreAndJsLogLinesReachLogcat",
};

/** A diff line adding one scenario method, as git writes it. */
const ADDED = (method: string): string => `+    public void ${method}() throws IOException {`;

/** One branch: the paths it touches and the diff of the scenario file. */
function branch(touched: readonly string[], scenarios = ""): BranchDiff {
  return { touched, scenarios };
}

/** A run directory holding one evidence record, and the directory itself for cleanup. */
function evidenceDir(evidence: Evidence | null): string {
  const root = mkdtempSync(join(tmpdir(), "sandcastle-android-evidence-"));
  const runsDir = join(root, "logs", "1");
  mkdirSync(runsDir, { recursive: true });
  if (evidence !== null) writeFileSync(evidencePath(runsDir), JSON.stringify(evidence, null, 2));
  return runsDir;
}

/** A passing record for `methods` on `commit`, which individual tests spoil one field at a time. */
function passing(methods: readonly string[], commit: string): Evidence {
  return {
    required: methods.map((method) => ({ method, why: "the branch changes it" })),
    methods,
    command: "scripts/android-test.sh emulator-5554 a,b",
    result: "passed",
    device: "emulator-5554",
    duration_s: 12,
    commit,
    clean_tree: true,
    at: "2026-01-01T00:00:00Z",
  };
}

test("a scenario the branch adds is required, named with the reason it is required", () => {
  const set = requiredScenarios({
    diff: branch([ANDROID.testFile], [ADDED("aChangedScenario")].join("\n")),
    body: "no declared section",
    android: ANDROID,
  });

  assert.equal(set.kind, "required");
  assert.deepEqual(
    set.kind === "required" ? set.required.map((entry) => entry.method) : [],
    ["aChangedScenario"],
    "the branch's own new method is the work that needs proving",
  );
});

test("a private helper the branch adds is not a scenario a device can prove", () => {
  const set = requiredScenarios({
    diff: branch([ANDROID.testFile], "+    private void awaitDefaultEntry() throws IOException {"),
    body: "",
    android: ANDROID,
  });

  assert.deepEqual(
    set.kind === "required" ? set.required.map((entry) => entry.method) : [],
    [ANDROID.smoke],
    "JUnit cannot run a private helper by name, so requiring it would refuse work nothing could prove",
  );
});

test("a scenario the issue declares is required even when the branch changes no method", () => {
  const set = requiredScenarios({
    diff: branch(["src/android/jni_host.zig"]),
    body: "## Android scenarios\n\n`freshAppWithAutoSave` — the save path this change rewrites\n",
    android: ANDROID,
  });

  assert.equal(set.kind, "required");
  assert.ok(
    set.kind === "required" && set.required.some((entry) => entry.method === "freshAppWithAutoSave"),
    "a declared existing method is how a bridge change names its proof",
  );
});

test("a fenced example of the declared section is not read as a method", () => {
  const diff = branch(["src/android/jni_host.zig"]);
  // A worked example of one entry: read as prose, it would require a method the doc only shows.
  const example = "## Android scenarios\n\nA worked example:\n\n```markdown\n`aFencedExample` — a shape, not a declaration\n```\n";
  const set = requiredScenarios({ diff, body: example, android: ANDROID });

  assert.ok(
    !(set.kind === "required" && set.required.some((entry) => entry.method === "aFencedExample")),
    "an example inside a fence is prose about the section, not a method the run must prove",
  );
  // The same prose outside a fence is a declaration: the fence is what excludes it.
  const declared = requiredScenarios({ diff, body: "## Android scenarios\n\n`aFencedExample` — a declaration\n", android: ANDROID });
  assert.deepEqual(
    declared.kind === "required" ? declared.required.map((entry) => entry.method) : [],
    ["aFencedExample"],
  );

  // The doc's own shape — a fenced section with its heading — is prose about the section as well.
  const fencedSection = "## Android scenarios\n\n```markdown\n## Android scenarios\n\n`aFencedExample` — a shape\n```\n";
  const fromSection = requiredScenarios({ diff, body: fencedSection, android: ANDROID });
  assert.ok(!(fromSection.kind === "required" && fromSection.required.some((entry) => entry.method === "aFencedExample")));
});

test("a branch that changes no scenario requires the pinned smoke", () => {
  const set = requiredScenarios({
    diff: branch(["src/android/gate.zig"]),
    body: "",
    android: ANDROID,
  });

  assert.equal(set.kind, "required");
  assert.deepEqual(
    set.kind === "required" ? set.required.map((entry) => entry.method) : [],
    [ANDROID.smoke],
    "tooling work owes one pinned scenario, not a pick made per issue",
  );
});

test("a changed Android surface with no scenario stops as `no scenario names this change`", () => {
  const set = requiredScenarios({
    diff: branch(["src/android/jni_host.zig"]),
    body: "",
    android: ANDROID,
  });

  assert.equal(set.kind, "stop");
  assert.match(
    set.kind === "stop" ? set.reason : "",
    /no scenario names this change/u,
    "the stop names the defect: the app moved and nothing proves it",
  );
});

test("a branch that touches no Android code owes no evidence", () => {
  const runsDir = evidenceDir(null);
  try {
    const reason = checkAndroidEvidence({
      diff: branch(["src/core/board.zig"]),
      body: "",
      android: ANDROID,
      runsDir,
      commit: "abc123",
    });

    assert.equal(reason, null, "a terminal-only branch has no device run to prove");
  } finally {
    rmSync(join(runsDir, "..", ".."), { recursive: true, force: true });
  }
});

test("evidence that proves every required method on this commit passes", () => {
  const runsDir = evidenceDir(passing(["aChangedScenario"], "abc123"));
  try {
    const reason = checkAndroidEvidence({
      diff: branch([ANDROID.testFile], ADDED("aChangedScenario")),
      body: "",
      android: ANDROID,
      runsDir,
      commit: "abc123",
    });

    assert.equal(reason, null);
  } finally {
    rmSync(join(runsDir, "..", ".."), { recursive: true, force: true });
  }
});

test("no evidence refuses, naming the file it looked for", () => {
  const runsDir = evidenceDir(null);
  try {
    const reason = checkAndroidEvidence({
      diff: branch(["src/android/gate.zig"]),
      body: "",
      android: ANDROID,
      runsDir,
      commit: "abc123",
    });

    assert.match(String(reason), /no android-evidence\.json in .*logs\/1/u);
  } finally {
    rmSync(join(runsDir, "..", ".."), { recursive: true, force: true });
  }
});

test("a failed device run refuses, naming the run and its device", () => {
  const runsDir = evidenceDir({ ...passing([ANDROID.smoke], "abc123"), result: "failed" });
  try {
    const reason = checkAndroidEvidence({
      diff: branch(["src/android/gate.zig"]),
      body: "",
      android: ANDROID,
      runsDir,
      commit: "abc123",
    });

    assert.match(String(reason), /device run failed \("failed" on emulator-5554\)/u);
  } finally {
    rmSync(join(runsDir, "..", ".."), { recursive: true, force: true });
  }
});

test("evidence from another commit refuses, naming both commits", () => {
  const runsDir = evidenceDir(passing([ANDROID.smoke], "1111111111"));
  try {
    const reason = checkAndroidEvidence({
      diff: branch(["src/android/gate.zig"]),
      body: "",
      android: ANDROID,
      runsDir,
      commit: "2222222222",
    });

    assert.match(String(reason), /proves commit 1111111111, not this branch's head 2222222222/u);
  } finally {
    rmSync(join(runsDir, "..", ".."), { recursive: true, force: true });
  }
});

test("evidence from a dirty worktree refuses: it proves code that was never committed", () => {
  const runsDir = evidenceDir({ ...passing([ANDROID.smoke], "abc123"), clean_tree: false });
  try {
    const reason = checkAndroidEvidence({
      diff: branch(["src/android/gate.zig"]),
      body: "",
      android: ANDROID,
      runsDir,
      commit: "abc123",
    });

    assert.match(String(reason), /dirty worktree/u);
  } finally {
    rmSync(join(runsDir, "..", ".."), { recursive: true, force: true });
  }
});

test("evidence naming fewer methods than the branch requires refuses, naming the missing one", () => {
  const runsDir = evidenceDir(passing(["aChangedScenario"], "abc123"));
  try {
    const reason = checkAndroidEvidence({
      diff: branch([ANDROID.testFile], [ADDED("aChangedScenario"), ADDED("anotherScenario")].join("\n")),
      body: "",
      android: ANDROID,
      runsDir,
      commit: "abc123",
    });

    assert.match(String(reason), /did not prove anotherScenario/u);
    assert.doesNotMatch(String(reason), /did not prove aChangedScenario/u);
  } finally {
    rmSync(join(runsDir, "..", ".."), { recursive: true, force: true });
  }
});
