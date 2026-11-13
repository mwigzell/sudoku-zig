// status.test.mts — where a run stands, told apart from a run that stopped saying anything.

import test from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { appendEvent } from "./events.mts";
import { ledgerPath, writeLedger } from "./ledger.mts";
import { writeRunRecord } from "./run_record.mts";
import { formatStatus, iteration, newestRunDir, phase, readStatus, STALLED_AFTER_MS } from "./status.mts";
import type { RunEvent } from "./events.mts";

const ISSUE = 116;
const STEP_AT = 2;
const STEP_OF = 3;
const STEP_LINE = `step ${STEP_AT}/${STEP_OF}`;
const START = Date.parse("2026-11-13T10:00:00.000Z");
const at = (seconds: number): string => new Date(START + seconds * 1000).toISOString();

const RUNNING: RunEvent[] = [
  { at: at(0), kind: "run", message: "on the step loop" },
  { at: at(5), kind: "step", message: `${STEP_LINE}: the second piece` },
  { at: at(6), kind: "agent-start", message: `${STEP_LINE} implementer` },
];

const FINISHED: RunEvent[] = [...RUNNING, { at: at(600), kind: "end", message: "every criterion is proven" }];

const status = (events: RunEvent[]) => ({
  stamp: "1",
  record: { issue: ISSUE, branch: "sandcastle/x/1", targetBranch: "develop", startedAt: at(0) },
  events,
  ledger: { issue: ISSUE, ticks: [{ position: 1, at: at(30) }], criteria: [{ position: 1, at: at(500) }] },
});

test("a run whose last event is recent is live, and one that went quiet is stalled", () => {
  const running = status(RUNNING);

  assert.equal(phase(running, START + 10_000), "live");
  assert.equal(phase(running, START + 6_000 + STALLED_AFTER_MS + 1), "stalled", "a working run says so with heartbeats");
});

test("a run that logged its end or a stop is finished, however old it is", () => {
  assert.equal(phase(status(FINISHED), START + 10_000_000), "finished");
  assert.equal(phase(status([...RUNNING, { at: at(9), kind: "stop", message: "the step added no test" }]), START), "finished");
  assert.equal(phase(status([]), START), "not started");
});

test("the iteration comes from the last step line the loop logged", () => {
  assert.deepEqual(iteration(RUNNING), { at: 2, of: 3 });
  assert.deepEqual(iteration([]), { at: 0, of: 0 });
});

test("the status names the run, its issue, its phase, its ticks and its last event", () => {
  const lines = formatStatus(status(RUNNING), START + 20_000).join("\n");

  assert.match(lines, /run:\s+1/u);
  assert.match(lines, new RegExp(`issue:\\s+#${ISSUE}`, "u"));
  assert.match(lines, /branch:\s+sandcastle\/x\/1/u);
  assert.match(lines, /phase:\s+live/u);
  assert.match(lines, /step:\s+2 of 3/u);
  assert.match(lines, /ticks:\s+1 step\(s\), 1 criterion\(s\)/u);
  assert.match(lines, /elapsed:\s+6s/u, "elapsed runs to the last event while the run is still going");
  assert.match(lines, new RegExp(`last:.*\\[agent-start\\] ${STEP_LINE} implementer`, "u"));
});

test("a run that never recorded its aim still reports what it does know", () => {
  const lines = formatStatus({ stamp: "9", record: null, events: [], ledger: null }, START).join("\n");

  assert.match(lines, /issue:\s+\(not recorded\)/u);
  assert.match(lines, /phase:\s+not started/u);
  assert.match(lines, /ticks:\s+0 step\(s\), 0 criterion\(s\)/u);
});

test("the newest run directory is picked by stamp, not by modification time", () => {
  const dir = newestRunDir(".sandcastle/logs");
  assert.equal(dir === null || /\d+$/u.test(dir), true);
});

test("reading a run's status needs nothing but its directory", () => {
  const root = mkdtempSync(join(tmpdir(), "sandcastle-status-"));
  try {
    const runsDir = join(root, "7");
    writeRunRecord(runsDir, { issue: ISSUE, branch: "sandcastle/x/7", targetBranch: "develop", startedAt: at(0) });
    appendEvent(runsDir, { at: at(1), kind: "run", message: "on the step loop" });
    writeLedger(ledgerPath(runsDir), { issue: ISSUE, ticks: [{ position: 1, at: at(2) }], criteria: [] });

    const read = readStatus(runsDir);

    assert.equal(read.stamp, "7");
    assert.equal(read.record?.issue, ISSUE);
    assert.equal(read.events.length, 1);
    assert.equal(read.ledger?.ticks.length, 1);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
