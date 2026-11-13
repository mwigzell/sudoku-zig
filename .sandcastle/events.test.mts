// events.test.mts — the run's log: the same events in two files, one for a program and one for a person.

import test from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { appendEvent, eventsPath, formatRunLogLine, readEvents, runLogPath } from "./events.mts";

test("every event lands in both halves of the log, in order", () => {
  const dir = mkdtempSync(join(tmpdir(), "sandcastle-events-"));
  try {
    const runsDir = join(dir, "runs", "1");
    appendEvent(runsDir, { at: "t1", kind: "run", message: "branch cut" });
    appendEvent(runsDir, { at: "t2", kind: "tick", message: "a tick landed" });

    assert.deepEqual(readEvents(runsDir), [
      { at: "t1", kind: "run", message: "branch cut" },
      { at: "t2", kind: "tick", message: "a tick landed" },
    ]);
    assert.equal(
      readFileSync(runLogPath(runsDir), "utf8"),
      "t1 [run] branch cut\nt2 [tick] a tick landed\n",
    );
    assert.equal(readFileSync(eventsPath(runsDir), "utf8").trim().split("\n").length, 2, "one JSON line per event");
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("a run that logged nothing reads as no events, not as a broken log", () => {
  const dir = mkdtempSync(join(tmpdir(), "sandcastle-events-"));
  try {
    assert.deepEqual(readEvents(dir), []);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("a run.log line carries the time, the kind and the message", () => {
  assert.equal(
    formatRunLogLine({ at: "t1", kind: "stop", message: "the step added no test" }),
    "t1 [stop] the step added no test",
  );
});
