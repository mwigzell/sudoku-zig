// report_cli.mts — the terminal command behind `npm run sandcastle:verdict`.
//
// The report itself (`report.mts`) is project-neutral and reads a verdict on its own evidence.

import { readFile } from "node:fs/promises";
import { formatFinalReport, formatReport } from "./report.mts";

const [stepArg, path] = process.argv.slice(2);
const raw = await readFile(path, "utf8");
// `--final` prints the whole-branch matrix; a number prints that step's verdict.
const lines = stepArg === "--final" ? formatFinalReport(raw) : formatReport(Number(stepArg), raw);
process.stdout.write(`${lines.join("\n")}\n`);
