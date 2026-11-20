// report.test.mts — the readable report keeps the decision first and never hides an empty
// evidence field behind a line that looks like proof.
import assert from "node:assert/strict";
import test from "node:test";
import { PROJECT } from "./project.mts";
import { formatFinalReport, formatReport, wrap } from "./report.mts";

/** The step under test. Spelled out here so an assertion never reads like a citation. */
const STEP = 3;

/** A verdict that passes every stop rule, so only the field under test varies. */
function passingVerdict(step: number) {
  return {
    step,
    test_added: "a test that fails without the change",
    parity: "on",
    standards: "clean",
    on_track: true,
    concerns: [] as string[],
    red_on_revert: "reverted the change, the test failed",
    ac_at_risk: [] as string[],
    drift: false,
  };
}

test("a passing verdict reads PASS with its evidence underneath", () => {
  const lines = formatReport(STEP, JSON.stringify(passingVerdict(STEP)));
  assert.equal(lines[0], `step ${STEP}: PASS`);
  assert.ok(lines.some((line) => line.includes("test added:") && line.includes("fails without the change")));
});

test("a verdict that breaks a stop rule says STOP and why", () => {
  const lines = formatReport(STEP, JSON.stringify({ ...passingVerdict(STEP), on_track: false }));
  assert.equal(lines[0], `step ${STEP}: STOP — the step is not on track`);
});

test("a verdict for another step is a stop, not a pass for this one", () => {
  const later = STEP + 1;
  const lines = formatReport(STEP, JSON.stringify(passingVerdict(later)));
  assert.equal(lines[0], `step ${STEP}: STOP — the verdict names step ${later}`);
});

test("a verdict that cannot be read is reported, never passed", () => {
  const lines = formatReport(STEP, "{not json");
  assert.equal(lines.length, 1);
  assert.match(lines[0] ?? "", /^step /u);
  assert.match(lines[0] ?? "", /STOP — /u);
});

test("a long field wraps under the label and keeps every word", () => {
  const long = Array.from({ length: 40 }, (_, index) => `word${index}`).join(" ");
  const lines = formatReport(STEP, JSON.stringify({ ...passingVerdict(STEP), concerns: [long] }));
  const concern = lines.filter((line) => line.includes("concern:") || /^ {17}\S/u.test(line));
  assert.ok(concern.length > 1, "the concern occupies more than one line");
  for (const line of concern) assert.ok(line.length <= 110, `line too wide: ${line}`);
  const rejoined = concern.map((line) => line.replace(/^ {17}/u, "").replace(/^ {2}concern: {7}/u, "")).join(" ");
  assert.equal(rejoined, long, "no word was dropped or split");
});

test("a single word longer than the width is not split", () => {
  const word = "x".repeat(150);
  assert.deepEqual(wrap(word), [word]);
});

/** A whole-branch verdict with one proven criterion and one nobody could prove. */
const FINAL = {
  criteria: [
    { criterion: "the legend line reaches the terminal", status: "PASS", evidence: "the shell e2e test asserts the footer" },
    { criterion: "no core file imports a native adapter", status: "FAIL", evidence: "" },
  ],
  standards: "clean",
  concerns: ["the second criterion needs a human read"],
  drift: [],
};

test("the whole-branch report leads with the decision and shows every criterion", () => {
  const lines = formatFinalReport(JSON.stringify(FINAL));
  const text = lines.join("\n");

  assert.match(lines[0] ?? "", /^whole branch: STOP — unproven: no core file imports a native adapter$/u);
  assert.match(text, /^ {2}PASS +the legend line reaches the terminal$/mu);
  assert.match(text, /^ {2}FAIL +no core file imports a native adapter$/mu);
  assert.match(text, /concern: {7}the second criterion needs a human read/u);
});

test("a verdict with no standards text reports its criteria instead of crashing", () => {
  const withoutStandards = { criteria: FINAL.criteria, concerns: FINAL.concerns, drift: FINAL.drift };
  const text = formatFinalReport(JSON.stringify(withoutStandards)).join("\n");

  assert.match(text, /^ {2}PASS +the legend line reaches the terminal$/mu);
  assert.doesNotMatch(text, /standards:/u);
});

test("a whole-branch verdict that cannot be read says so instead of showing a pass", () => {
  assert.match(formatFinalReport("{ not json")[0] ?? "", /^whole branch: STOP — the verdict file is not valid JSON$/u);
});

test("the whole-branch report states the gate's parity claim in words", () => {
  const restored = { ...FINAL, parity_restored: true, parity_line: PROJECT.parity.sample };
  assert.match(formatFinalReport(JSON.stringify(restored)).join("\n"), /parity: +restored — /u);

  const unrestored = { ...FINAL, parity_restored: false, parity_line: PROJECT.parity.sample };
  assert.match(formatFinalReport(JSON.stringify(unrestored)).join("\n"), /parity: +not restored — /u);
});
