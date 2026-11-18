// standards.test.mts — the standards a run must answer for are read from the project's
// standards file, not from the harness.

import { readFileSync } from "node:fs";
import test from "node:test";
import assert from "node:assert/strict";
import { PROJECT } from "./project.mts";
import { readRules, validateReport } from "./standards.mts";

const STANDARDS = `# Agents

## ${PROJECT.standards.section}

1. **Document public surfaces.** Every public function needs a header comment.
   - **HARD RULE (MANDATORY):** No undocumented public symbol is allowed.
2. **DRY** — Don't repeat yourself.
 - **Shotgun plumbing is a smell — say so.** Carry one value end to end.
3. **No magic numbers.** Name the constant.

## Test / SUT colocated

- Test blocks are colocated with the code being tested.
`;

test("the rules are the numbered items under the standards heading, and nothing else", () => {
  assert.deepEqual(readRules(STANDARDS, PROJECT), [
    { position: 1, title: "Document public surfaces." },
    { position: 2, title: "DRY" },
    { position: 3, title: "No magic numbers." },
  ]);
});

test("a standard added to the standards file is required by the next run, with no change to the harness", () => {
  const extended = STANDARDS.replace(
    "3. **No magic numbers.** Name the constant.",
    "3. **No magic numbers.** Name the constant.\n4. **Constructors are pure.** Only set fields.",
  );
  const rules = readRules(extended, PROJECT);
  assert.equal(rules.length, 4, "the added rule is a rule the moment the file says it is");

  const checked = validateReport(
    {
      rules: [
        { rule: "Document public surfaces.", verdict: "PASS", evidence: "src/sudoku.zig:12" },
        { rule: "DRY", verdict: "PASS", evidence: "src/host/host.zig:40" },
        { rule: "No magic numbers.", verdict: "PASS", evidence: "src/board/board.zig:7" },
      ],
      shotgun: [],
    },
    rules,
    PROJECT,
  );

  assert.ok("problem" in checked, "a report written against yesterday's list is not acceptable");
  assert.match(checked.problem, /left unjudged: Constructors are pure\./u);
});

test("a report against a standards section that has gone is a stop, not an empty list", () => {
  const withoutSection = "# Agents\n\n## Something else\n\n1. **Not a rule.**\n";

  assert.throws(() => readRules(withoutSection, PROJECT), new RegExp(`no "## ${PROJECT.standards.section}" section`, "u"));
});

test("a title that continues past the bold is answered by the words the file gives it", () => {
  const markdown = STANDARDS.replace(
    "3. **No magic numbers.** Name the constant.",
    "3. **No magic numbers.** Name the constant.\n8. **Clean** code style.",
  );
  const rules = readRules(markdown, PROJECT);
  assert.deepEqual(rules[3], { position: 8, title: "Clean code style", aliases: ["Clean"] });

  const checked = validateReport(
    {
      rules: [
        { rule: "Document public surfaces.", verdict: "PASS", evidence: "src/sudoku.zig:12" },
        { rule: "DRY", verdict: "PASS", evidence: "src/host/host.zig:40" },
        { rule: "No magic numbers.", verdict: "PASS", evidence: "src/board/board.zig:7" },
        { rule: "Clean code style", verdict: "PASS", evidence: "src/board/cell.zig:9" },
      ],
      shotgun: [],
    },
    rules,
    PROJECT,
  );
  assert.ok(!("problem" in checked), "the reviewer's wording is the standard's own");

  // The bold alone is the same standard: a reviewer may name it either way.
  const short = validateReport(
    {
      rules: [
        { rule: "Document public surfaces.", verdict: "PASS", evidence: "src/sudoku.zig:12" },
        { rule: "DRY", verdict: "PASS", evidence: "src/host/host.zig:40" },
        { rule: "No magic numbers.", verdict: "PASS", evidence: "src/board/board.zig:7" },
        { rule: "Clean", verdict: "PASS", evidence: "src/board/cell.zig:9" },
      ],
      shotgun: [],
    },
    rules,
    PROJECT,
  );
  assert.ok(!("problem" in short), "the bold wording names the same rule");
});

/** Punctuation inside a bold title is decoration: a report may name the rule without it. */
test("a trailing colon or full stop does not split a report's wording from the rule's", () => {
  const markdown = STANDARDS.replace(
    "3. **No magic numbers.** Name the constant.",
    "3. **SOLID principles:** One reason to change.\n4. **Constructors are pure.** Only set fields.",
  );
  const rules = readRules(markdown, PROJECT);

  const checked = validateReport(
    {
      rules: [
        { rule: "Document public surfaces.", verdict: "PASS", evidence: "src/sudoku.zig:12" },
        { rule: "DRY", verdict: "PASS", evidence: "src/host/host.zig:40" },
        { rule: "SOLID principles", verdict: "PASS", evidence: "src/core/engine/bookmark.zig:22" },
        { rule: "Constructors are pure", verdict: "PASS", evidence: "src/board/board.zig:7" },
      ],
      shotgun: [],
    },
    rules,
    PROJECT,
  );
  assert.ok(!("problem" in checked), "the colon and the full stop are not part of the name");
});

/** The project's own standards file is the one every run answers for; reading it is the run's first proof. */
test("the project's own standards file parses into the rules a run must answer for", () => {
  const rules = readRules(readFileSync(PROJECT.standards.file, "utf8"), PROJECT);

  // The heading must be found (readRules throws otherwise); the continuation rule must turn
  // `**Clean** code style` into one title. If either regresses, a run silently answers fewer rules.
  assert.deepEqual(rules.find((rule) => rule.position === 8), {
    position: 8,
    title: "Clean code style",
    aliases: ["Clean"],
  });
  assert.ok(rules.length > 8, "the real file has more rules than the one rule this test names");
});
