// boundary.test.mts — the seam between the generic harness and this repository.
//
// The generic modules act only on the `ProjectConfig` they are handed. A repo literal, an ambient
// read of a project file, a hard-coded working directory or a subprocess inside one of them would
// tie the harness to this repository and make the seam decorative. This test is what keeps the
// seam real, so it fails on the first one rather than on the day the harness is extracted.

import test from "node:test";
import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

/** Where the harness's own files live; the scan reads the real modules, never a copy. */
const HERE = dirname(fileURLToPath(import.meta.url));

/**
 * The modules that must stay project-neutral.
 *
 * `project.mts` (the adapter) and `main.mts` (the entry) are deliberately absent: they are the two
 * places allowed to know what repository this is.
 */
const GENERIC_MODULES = [
  "plan.mts",
  "loop.mts",
  "verdict.mts",
  "standards.mts",
  "ledger.mts",
  "resume.mts",
  "events.mts",
  "report.mts",
];

/** The text of one harness module, as committed. */
function sourceOf(file: string): string {
  return readFileSync(join(HERE, file), "utf8");
}

/**
 * Facts only this repository knows. A generic module that names one is carrying project policy
 * in code, which is the thing the seam exists to prevent.
 *
 * The parity check is matched by how this repo spells it (`verify-parity`, `-Dparity`,
 * `SUDOKU_PARITY_OFF`), not by the bare word: a config field a project names `parity` is still a
 * value handed in, while a hard-coded flag or env var is the project's check baked into the harness.
 */
const REPO_LITERALS: ReadonlyArray<{ pattern: RegExp; fact: string }> = [
  { pattern: /\bzig\b/iu, fact: "the Zig toolchain" },
  { pattern: /sudoku/iu, fact: "the project's name" },
  { pattern: /AGENTS\.md/u, fact: "the standards file" },
  { pattern: /verify-parity|-Dparity|SUDOKU_PARITY_OFF/u, fact: "the parity check" },
];

/** A read whose path is written in the module rather than taken from the config. */
const AMBIENT_READ = /(?:readFileSync|readFile|readdirSync)\(\s*["'`]/u;
/** A read rooted at a directory the module names itself, instead of one it was handed. */
const AMBIENT_ROOT = /(?:readFileSync|readFile)\(\s*join\(\s*["'`]/u;
/** A subprocess: the entry owns those, so a generic module must not reach one. */
const SUBPROCESS = /\b(?:execFileSync|execFile|execSync|spawnSync|spawn)\b/u;
/** Importing the adapter would let a generic module read this repo's facts without being given them. */
const ADAPTER_IMPORT = /from\s+["'][^"']*project\.mts["']/u;
/** The config type is a type-only import: it is erased, so no runtime edge to the adapter exists. */
const CONFIG_IMPORT = /^\s*import\s+(?!type\b).*project_config\.mts/mu;

/**
 * Every way `text` breaks the seam for a module named `file`.
 *
 * Returns the rules broken with the site of each, so a failure says what moved where rather than
 * only that some module is impure.
 */
function seamViolations(file: string, text: string): string[] {
  const found: string[] = [];
  for (const { pattern, fact } of REPO_LITERALS) {
    const match = pattern.exec(text);
    if (match) found.push(`${file} names ${fact}: "${match[0]}"`);
  }
  if (AMBIENT_READ.test(text) || AMBIENT_ROOT.test(text)) found.push(`${file} reads a project file by a path it names itself`);
  if (/process\.cwd\(\)/u.test(text)) found.push(`${file} hard-codes the working directory (process.cwd())`);
  if (SUBPROCESS.test(text)) found.push(`${file} spawns a subprocess`);
  if (ADAPTER_IMPORT.test(text)) found.push(`${file} imports the project adapter`);
  if (CONFIG_IMPORT.test(text)) found.push(`${file} imports ProjectConfig as a value; the type must be imported with \`import type\``);
  return found;
}

test("no generic module names a fact only this repository knows", () => {
  const violations = GENERIC_MODULES.flatMap((file) => seamViolations(file, sourceOf(file)));
  assert.deepEqual(violations, [], `a generic module carries project policy:\n${violations.join("\n")}`);
});

test("no generic module reads a project file by an ambient path, hard-codes the cwd or spawns a process", () => {
  for (const file of GENERIC_MODULES) {
    const text = sourceOf(file);
    assert.equal(AMBIENT_READ.test(text) || AMBIENT_ROOT.test(text), false, `${file} reads a project file by a path it names itself`);
    assert.equal(/process\.cwd\(\)/u.test(text), false, `${file} hard-codes the working directory`);
    assert.equal(SUBPROCESS.test(text), false, `${file} spawns a subprocess`);
  }
});

test("no generic module imports the adapter, and the config type is imported as a type", () => {
  for (const file of GENERIC_MODULES) {
    const text = sourceOf(file);
    assert.doesNotMatch(text, ADAPTER_IMPORT, `${file} imports the adapter`);
    assert.doesNotMatch(text, CONFIG_IMPORT, `${file} imports the config type as a value`);
  }
});

test("the checker itself catches a planted literal, ambient read, subprocess and adapter import", () => {
  // Without this, a checker that silently matched nothing would pass every module above.
  assert.equal(seamViolations("x.mts", 'const verify = "zig build verify";\n').length, 1);
  assert.equal(seamViolations("x.mts", 'readFileSync(".sandcastle/verdict.json", "utf8");\n').length, 1);
  assert.equal(seamViolations("x.mts", 'execFileSync("gh", ["issue", "view"]);\n').length, 1);
  assert.equal(seamViolations("x.mts", 'import { PROJECT } from "./project.mts";\n').length, 1);
  assert.equal(seamViolations("x.mts", 'import { ProjectConfig } from "./project_config.mts";\n').length, 1);
  assert.deepEqual(seamViolations("x.mts", 'import type { ProjectConfig } from "./project_config.mts";\n'), []);
});

test("the adapter fills every fact the harness hands in", async () => {
  const { PROJECT } = await import("./project.mts");

  assert.equal(typeof PROJECT.verify, "string");
  assert.match(String(PROJECT.verify), /\S/u, "the verify command is the gate every session runs");
  const offGate = PROJECT.verifyOff(1);
  assert.equal(typeof offGate, "string", "a window's step is handed a command, not a flag to add itself");
  assert.ok(offGate.startsWith(`${PROJECT.verify} `), `the off gate is the same gate: ${offGate}`);
  assert.notEqual(offGate, PROJECT.verify, "the off gate is a different command, or the window would change nothing");
  const standards = PROJECT.standards;
  assert.ok(existsSync(join(HERE, "..", standards.file)), `the standards file ${standards.file} exists`);
  assert.match(standards.section, /\S/u, "the standards section names a heading the file carries");
  const tracker = PROJECT.tracker;
  assert.match(tracker.readyLabel, /\S/u, "the readiness label is the one triage writes");
  const agent = PROJECT.agent;
  assert.match(agent.model, /\S/u, "the agent names the model a run starts");

  const paths = PROJECT.paths;
  for (const [role, path] of Object.entries(paths.prompts)) {
    assert.ok(existsSync(join(HERE, "..", path)), `the ${role} prompt ${path} exists`);
  }
  for (const [name, path] of Object.entries(paths.verdicts)) {
    assert.equal(path.endsWith(".json"), true, `the ${name} verdict is a json file the host can read`);
  }
  assert.match(paths.runsDir, /\S/u);
  assert.match(paths.env, /\S/u);

  const docs = PROJECT.docs;
  assert.ok(existsSync(join(HERE, "..", docs.harness)), `the harness manual ${docs.harness} exists`);
  assert.ok(existsSync(join(HERE, "..", docs.decisions)), `the decision records ${docs.decisions} exist`);
});
