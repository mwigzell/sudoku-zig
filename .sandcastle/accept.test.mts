// accept.test.mts — accepting a run closes the issue it was aimed at, and only on proof it named.

import test from "node:test";
import assert from "node:assert/strict";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { androidRefusal, archiveAcceptedRun, closeAcceptedRun } from "./accept.mts";
import { evidencePath } from "./android_evidence.mts";
import { writeRunRecord } from "./run_record.mts";
import { ledgerPath } from "./ledger.mts";
import type { AndroidConfig } from "./project_config.mts";

/** The Android facts these fixtures hand in, so the check is judged without this repo's adapter. */
const ANDROID: AndroidConfig = {
  testFile: "src/android/test/FileBridgeTest.java",
  surface: ["src/android/jni_host.zig"],
  code: ["src/android/"],
  smoke: "coreAndJsLogLinesReachLogcat",
};

/** A closer that records what it was asked to close, so no test shells out to `gh`. */
function fakeCloser() {
  const closed: Array<{ issue: number; comment: string }> = [];
  return {
    closed,
    close: (issue: number, comment: string) => void closed.push({ issue, comment }),
  };
}

function fixture(): string {
  const root = mkdtempSync(join(tmpdir(), "sandcastle-accept-"));
  return join(root, "runs", "1");
}

test("accepting a run closes the issue its record names, and says which", () => {
  const runsDir = fixture();
  try {
    writeRunRecord(runsDir, {
      issue: 116,
      branch: "sandcastle/sequential-reviewer/1",
      targetBranch: "develop",
      startedAt: "t1",
    });
    const closer = fakeCloser();

    const result = closeAcceptedRun(runsDir, "sandcastle/sequential-reviewer/1", "develop", closer);

    assert.deepEqual(result, { closed: 116 });
    assert.deepEqual(closer.closed, [
      { issue: 116, comment: "Accepted sandcastle/sequential-reviewer/1 into develop." },
    ]);
  } finally {
    rmSync(join(runsDir, "..", ".."), { recursive: true, force: true });
  }
});

test("a run directory from before run records falls back to the issue its ledger names", () => {
  const runsDir = fixture();
  try {
    mkdirSync(runsDir, { recursive: true });
    writeFileSync(ledgerPath(runsDir), JSON.stringify({ issue: 42, ticks: [{ position: 1, at: "a" }] }));

    assert.deepEqual(closeAcceptedRun(runsDir, "sandcastle/x/1", "develop", fakeCloser()), { closed: 42 });
  } finally {
    rmSync(join(runsDir, "..", ".."), { recursive: true, force: true });
  }
});

test("a run that leaves neither record nor ledger closes nothing and says why", () => {
  const runsDir = fixture();
  try {
    const closer = fakeCloser();

    const result = closeAcceptedRun(runsDir, "sandcastle/x/1", "develop", closer);

    assert.ok("problem" in result);
    assert.match(result.problem, /no run record or ledger in .* so there is no issue to close/);
    assert.deepEqual(closer.closed, [], "guessing an issue number would close the wrong issue");
  } finally {
    rmSync(join(runsDir, "..", ".."), { recursive: true, force: true });
  }
});

test("accepting files the run's record beside the issue, named by the tracker", () => {
  const root = mkdtempSync(join(tmpdir(), "sandcastle-accept-record-"));
  const runsDir = join(root, "runs", "1");
  const archiveRoot = join(root, "issues");
  try {
    writeRunRecord(runsDir, {
      issue: 77,
      branch: "sandcastle/sequential-reviewer/1",
      targetBranch: "develop",
      startedAt: "t1",
    });
    writeFileSync(join(runsDir, "step-1-verdict.json"), "{}");

    const filed = archiveAcceptedRun(
      runsDir,
      {
        archiveRoot,
        branch: "sandcastle/sequential-reviewer/1",
        into: "develop",
        base: "base111",
        head: "head222",
        commits: [{ sha: "head222", subject: "fix(flow): say what happened" }],
      },
      { title: () => "A refused save says what happened", body: () => "" },
    );

    assert.ok(!("problem" in filed), "the record has an issue to sit beside");
    assert.equal(filed.dir, join(archiveRoot, "77-a-refused-save-says-what-happened"));
    assert.ok(existsSync(join(filed.dir, "step-1-verdict.json")), "the verdict is copied, not moved");
    assert.match(readFileSync(join(filed.dir, "README.md"), "utf8"), /Cut from `develop` at `base111`; head `head222` \(1 commit\)/u);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("accept refuses an Android branch whose run left no device evidence, before the merge", () => {
  const runsDir = fixture();
  try {
    writeRunRecord(runsDir, {
      issue: 142,
      branch: "sandcastle/sequential-reviewer/1",
      targetBranch: "develop",
      startedAt: "t1",
    });

    const refusal = androidRefusal({
      runsDir,
      base: "base111",
      head: "head222",
      android: ANDROID,
      reader: { title: () => "a fixture", body: () => "" },
      diff: { diff: () => ({ touched: ["src/android/gate.zig"], scenarios: "" }) },
    });

    assert.match(String(refusal), /no android-evidence\.json/u, "the merge waits for the device run");
  } finally {
    rmSync(join(runsDir, "..", ".."), { recursive: true, force: true });
  }
});

test("accept lets the same branch through once its run holds passing evidence", () => {
  const runsDir = fixture();
  try {
    writeRunRecord(runsDir, {
      issue: 142,
      branch: "sandcastle/sequential-reviewer/1",
      targetBranch: "develop",
      startedAt: "t1",
    });
    writeFileSync(
      evidencePath(runsDir),
      JSON.stringify({
        required: [{ method: ANDROID.smoke, why: "the pinned smoke" }],
        methods: [ANDROID.smoke],
        command: "scripts/android-test.sh emulator-5554 coreAndJsLogLinesReachLogcat",
        result: "passed",
        device: "emulator-5554",
        duration_s: 9,
        commit: "head222",
        clean_tree: true,
        at: "2026-01-01T00:00:00Z",
      }),
    );

    const refusal = androidRefusal({
      runsDir,
      base: "base111",
      head: "head222",
      android: ANDROID,
      reader: { title: () => "a fixture", body: () => "" },
      diff: { diff: () => ({ touched: ["src/android/gate.zig"], scenarios: "" }) },
    });

    assert.equal(refusal, null, "the device run proved the pinned smoke on this commit");
  } finally {
    rmSync(join(runsDir, "..", ".."), { recursive: true, force: true });
  }
});
