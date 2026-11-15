// standards.test.mts — the standards a run must answer for are read from AGENTS.md, not from the harness.

import test from "node:test";
import assert from "node:assert/strict";
import { readRules, validateReport } from "./standards.mts";

const STANDARDS = `# Agents

## Coding standards

1. **Document public surfaces.** Every public function needs a header comment.
   - **HARD RULE (MANDATORY):** No undocumented public symbol is allowed.
2. **DRY** — Don't repeat yourself.
 - **Shotgun plumbing is a smell — say so.** Carry one value end to end.
3. **No magic numbers.** Name the constant.

## Test / SUT colocated

- Test blocks are colocated with the code being tested.
`;

test("the rules are the numbered items under the standards heading, and nothing else", () => {
  assert.deepEqual(readRules(STANDARDS), [
    { position: 1, title: "Document public surfaces." },
    { position: 2, title: "DRY" },
    { position: 3, title: "No magic numbers." },
  ]);
});

test("a standard added to AGENTS.md is required by the next run, with no change to the harness", () => {
  const extended = STANDARDS.replace(
    "3. **No magic numbers.** Name the constant.",
    "3. **No magic numbers.** Name the constant.\n4. **Constructors are pure.** Only set fields.",
  );
  const rules = readRules(extended);
  assert.equal(rules.length, 4, "the added rule is a rule the moment AGENTS.md says it is");

  const checked = validateReport(
    {
      rules: [
        { rule: "Document public surfaces.", verdict: "PASS", evidence: "src/sudoku.zig:12" },
        { rule: "DRY", verdict: "PASS", evidence: "src/host/host.zig:40" },
        { rule: "No magic numbers.", verdict: "PASS", evidence: "src/board/board.zig:7" },
      ],
    },
    rules,
  );

  assert.ok("problem" in checked, "a report written against yesterday's list is not acceptable");
  assert.match(checked.problem, /left unjudged: Constructors are pure\./u);
});

test("a report against a standards section that has gone is a stop, not an empty list", () => {
  const withoutSection = "# Agents\n\n## Something else\n\n1. **Not a rule.**\n";

  assert.throws(() => readRules(withoutSection), /no "## Coding standards" section/u);
});

test("a title that continues past the bold is answered by the words AGENTS.md gives it", () => {
  const markdown = STANDARDS.replace(
    "3. **No magic numbers.** Name the constant.",
    "3. **No magic numbers.** Name the constant.\n8. **Clean** code style.",
  );
  const rules = readRules(markdown);
  assert.deepEqual(rules[3], { position: 8, title: "Clean code style", aliases: ["Clean"] });

  const checked = validateReport(
    {
      rules: [
        { rule: "Document public surfaces.", verdict: "PASS", evidence: "src/sudoku.zig:12" },
        { rule: "DRY", verdict: "PASS", evidence: "src/host/host.zig:40" },
        { rule: "No magic numbers.", verdict: "PASS", evidence: "src/board/board.zig:7" },
        { rule: "Clean code style", verdict: "PASS", evidence: "src/board/cell.zig:9" },
      ],
    },
    rules,
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
    },
    rules,
  );
  assert.ok(!("problem" in short), "the bold wording names the same rule");
});
