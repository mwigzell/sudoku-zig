// report.mts — turn the reviewer's verdict files into something a person can read in a
// terminal. The raw transcript stays on disk for the cases that need it.
import { readFile } from "node:fs/promises";
import { decide, decideFinal, readFinalVerdict, readVerdict, type FinalVerdict, type StepVerdict } from "./verdict.mts";

/** Width a field's text is wrapped to, so a long verdict reads down the page, not off it. */
const WRAP_WIDTH = 96;

/** `text` broken at spaces into lines no longer than `width`, never splitting a word. */
export function wrap(text: string, width: number = WRAP_WIDTH): string[] {
  const out: string[] = [];
  let line = "";
  for (const word of text.split(/\s+/u)) {
    if (line.length === 0) line = word;
    else if (line.length + 1 + word.length <= width) line += ` ${word}`;
    else {
      out.push(line);
      line = word;
    }
  }
  if (line.length > 0) out.push(line);
  return out;
}

/** `label` and its wrapped `value`: the first line beside the label, the rest indented under it.
 *  The text is wrapped to what is left of the width after the label, so no line runs past it. */
function field(label: string, value: string): string[] {
  const [first, ...rest] = wrap(value, WRAP_WIDTH - label.length);
  return [`  ${label}${first ?? ""}`, ...rest.map((line) => `  ${" ".repeat(label.length)}${line}`)];
}

/** One verdict's lines: the decision, then the evidence a person checks it by. */
function formatVerdict(verdict: StepVerdict): string[] {
  const decision = decide(verdict, verdict.step);
  const lines = [
    `step ${verdict.step}: ${decision.kind === "tick" ? "PASS" : `STOP — ${decision.reason}`}`,
    ...field("test added:    ", verdict.test_added || "(none)"),
    `  verify:        exit ${verdict.verify_exit}`,
    ...field("standards:     ", verdict.standards),
    ...field("red on revert: ", verdict.red_on_revert || "(none)"),
  ];
  for (const concern of verdict.concerns) lines.push(...field("concern:       ", concern));
  for (const risk of verdict.ac_at_risk) lines.push(...field("ac at risk:    ", risk));
  return lines;
}

/** The report body for one verdict file's contents. `step` is the step it is expected to judge. */
export function formatReport(step: number, raw: string): string[] {
  const read = readVerdict(raw);
  if ("problem" in read) return [`step ${step}: STOP — ${read.problem}`];
  if (read.verdict.step !== step) return [`step ${step}: STOP — the verdict names step ${read.verdict.step}`];
  return formatVerdict(read.verdict);
}

/** The whole-branch report: the decision first, then the matrix a person reads it by. */
function formatFinalVerdict(verdict: FinalVerdict): string[] {
  const decision = decideFinal(verdict);
  const lines = [`whole branch: ${decision.kind === "pass" ? "PASS" : `STOP — ${decision.reason}`}`];

  // Every criterion is listed, passing or not: a matrix with the failures left out is not a matrix.
  for (const entry of verdict.criteria) {
    const mark = entry.status === "PASS" ? "PASS  " : "FAIL  ";
    lines.push(...field(`${mark} `, entry.criterion));
    if (entry.evidence.trim().length > 0) lines.push(...field("  evidence:      ", entry.evidence));
  }
  if (verdict.standards !== undefined) lines.push(...field("standards:     ", verdict.standards));
  for (const concern of verdict.concerns) lines.push(...field("concern:       ", concern));
  return lines;
}

/** The whole-branch report body for a verdict file's contents. */
export function formatFinalReport(raw: string): string[] {
  const read = readFinalVerdict(raw);
  if ("problem" in read) return [`whole branch: STOP — ${read.problem}`];
  return formatFinalVerdict(read.verdict);
}

if (import.meta.main) {
  const [stepArg, path] = process.argv.slice(2);
  const raw = await readFile(path, "utf8");
  // `--final` prints the whole-branch matrix; a number prints that step's verdict.
  const lines = stepArg === "--final" ? formatFinalReport(raw) : formatReport(Number(stepArg), raw);
  process.stdout.write(`${lines.join("\n")}\n`);
}
