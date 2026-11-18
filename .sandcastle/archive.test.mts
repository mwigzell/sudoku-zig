// archive.test.mts — accepting a run leaves a record a later reader can open.
//
// The run directory is git-ignored, so a clone would keep the merge and lose the evidence it was
// accepted on. Accept copies the verdicts beside the issue they judged and writes a README that
// names the branch, what it contained and what the reviewer still wanted fixed.

import test from "node:test";
import assert from "node:assert/strict";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { archiveDirName, archiveRun } from "./archive.mts";
import { writeLedger } from "./ledger.mts";
import { writeRunRecord } from "./run_record.mts";

/** The issue the fixture run was aimed at; the record's heading is built from it, not spelled out. */
const ISSUE = 42;

/** A whole-branch verdict with one passing criterion, as the reviewer writes it. */
const FINAL = {
  criteria: [
    { criterion: "Plain `zig build verify` is untouched.", status: "PASS", evidence: "exit 0" },
    { criterion: "The window is refused when closed.", status: "PASS", evidence: "exit 1" },
  ],
  parity_restored: true,
  parity_line: "✓ parity: 85 scenario(s) on native, web and Android",
  concerns: ["The ADR reads stricter than the shipped seam."],
  standards: "All rules pass.",
};

/** The symbols the branch carries through several files, as the host counted them. */
const SHOTGUN = [{ symbol: "parity", files: 20, verdict: "plumbing" }];

/** A run directory with one step verdict and a whole-branch review. */
function fixtureRun(): { root: string; runsDir: string } {
  const root = mkdtempSync(join(tmpdir(), "sandcastle-archive-"));
  const runsDir = join(root, "logs", "7");
  mkdirSync(runsDir, { recursive: true });
  writeRunRecord(runsDir, {
    issue: 42,
    branch: "sandcastle/sequential-reviewer/7",
    targetBranch: "develop",
    startedAt: "2026-01-01T00:00:00.000Z",
  });
  writeLedger(join(runsDir, "ticks.json"), {
    issue: 42,
    ticks: [{ position: 1, at: "a", issue: 42 }],
    criteria: [{ position: 1, at: "a", issue: 42 }],
  });
  writeFileSync(join(runsDir, "step-1-verdict.json"), "{}");
  writeFileSync(join(runsDir, "verdict-acs.json"), JSON.stringify(FINAL));
  writeFileSync(join(runsDir, "verdict-standards.json"), "{}");
  writeFileSync(join(runsDir, "shotgun.json"), JSON.stringify(SHOTGUN));
  writeFileSync(join(runsDir, "run.log"), "not part of the record");
  return { root, runsDir };
}

/** The run facts an accept hands the archiver, with the git half already resolved. */
function facts(runsDir: string, archiveRoot: string) {
  return {
    runsDir,
    archiveRoot,
    issue: 42,
    title: "A refused save says what happened",
    branch: "sandcastle/sequential-reviewer/7",
    into: "develop",
    base: "9a42b7a",
    head: "b649adc",
    commits: [
      { sha: "0f0f0f0", subject: "refactor(flow): name the refusal once" },
      { sha: "b649adc", subject: "fix(flow): a refused save says the game file was written" },
    ],
  };
}

test("the record lives beside the issue, named for it and its title", () => {
  assert.equal(archiveDirName(42, "A refused save says what happened"), "42-a-refused-save-says-what-happened");
  assert.equal(archiveDirName(42, "  Fill / Pencil  Marks!  "), "42-fill-pencil-marks");
  assert.equal(archiveDirName(42, ""), "42", "a title that slugs to nothing still names the issue");
  assert.equal(
    archiveDirName(42, "a title far longer than any directory needs to be to stay readable on a laptop screen"),
    "42-a-title-far-longer-than-any-directory-needs",
    "a long title is cut at a word boundary the directory can live with",
  );
  assert.equal(
    archiveDirName(141, "verify + sandcastle: step-scoped parity window for cross-arm refactors"),
    "141-verify-sandcastle-step-scoped-parity-window",
    "a cut that lands before a joining word leaves that word off",
  );
});

test("accepting copies the verdicts and writes the run record", () => {
  const { root, runsDir } = fixtureRun();
  const archiveRoot = join(root, "issues");
  try {
    const dir = archiveRun(facts(runsDir, archiveRoot));

    assert.equal(dir, join(archiveRoot, "42-a-refused-save-says-what-happened"));
    for (const name of ["step-1-verdict.json", "verdict-acs.json", "verdict-standards.json", "shotgun.json"]) {
      assert.ok(existsSync(join(dir, name)), `${name} is part of the record`);
    }
    assert.equal(existsSync(join(dir, "run.log")), false, "the transcript stays in the run directory");

    const readme = readFileSync(join(dir, "README.md"), "utf8");
    assert.equal(readme.split("\n")[0], `# #${ISSUE} — A refused save says what happened`);
    assert.match(readme, /`sandcastle\/sequential-reviewer\/7`/, "the branch is named");
    assert.match(readme, /Cut from `develop` at `9a42b7a`; head `b649adc` \(2 commits\)/u);
    assert.match(readme, /1\. `0f0f0f0` refactor\(flow\): name the refusal once/u);
    assert.match(readme, /2\. `b649adc` fix\(flow\): a refused save says the game file was written/u);
    assert.match(readme, /Steps: 1 of 1 ticked; acceptance criteria: 1 of 2/u);
    assert.match(readme, /parity restored — `✓ parity: 85 scenario\(s\) on native, web and Android`/u);
    assert.match(readme, /- PASS — Plain `zig build verify` is untouched\./u);
    assert.match(readme, /- PASS — The window is refused when closed\./u);
    assert.match(readme, /The ADR reads stricter than the shipped seam\./u);
    assert.match(readme, /`parity` in 20 files — plumbing/u);
    assert.match(readme, new RegExp(`${runsDir}/`, "u"), "the git-ignored run directory is pointed at");
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("a run whose review wrote no matrix still leaves a record that says so", () => {
  const { root, runsDir } = fixtureRun();
  const archiveRoot = join(root, "issues");
  try {
    rmSync(join(runsDir, "verdict-acs.json"));
    rmSync(join(runsDir, "shotgun.json"));

    const dir = archiveRun(facts(runsDir, archiveRoot));
    const readme = readFileSync(join(dir, "README.md"), "utf8");

    assert.match(readme, /Final review: no whole-branch verdict was copied/u);
    assert.match(readme, /- \(none recorded\)/u);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("re-archiving a run rewrites its record instead of failing", () => {
  const { root, runsDir } = fixtureRun();
  const archiveRoot = join(root, "issues");
  try {
    archiveRun(facts(runsDir, archiveRoot));
    const second = archiveRun(facts(runsDir, archiveRoot));

    assert.ok(existsSync(join(second, "README.md")));
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
