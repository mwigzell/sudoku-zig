// transcript.test.mts — the run's log follows an agent's transcript as it is written.
//
// The mirror is a convenience, so what matters is that a line lands without a timer driving it and
// that stopping the watch stops the work: a run that kept waking after its agent finished would
// spend the machine on nothing.

import test from "node:test";
import assert from "node:assert/strict";
import { appendFileSync, mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { watchTranscript } from "./transcript.mts";

/** A transcript directory holding one agent's file, as sandcastle writes it. */
function transcriptDir(): { dir: string; file: string } {
  const dir = mkdtempSync(join(tmpdir(), "transcript-"));
  const file = join(dir, "sandcastle-probe-implementer-step-1of1.log");
  writeFileSync(file, "first line\n");
  return { dir, file };
}

/** Wait until `done` holds or the budget runs out, so a slow filesystem fails the test, not hangs it. */
async function until(done: () => boolean, budgetMs = 2_000): Promise<boolean> {
  const deadline = Date.now() + budgetMs;
  while (Date.now() < deadline) {
    if (done()) return true;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  return done();
}

test("a line written to the transcript wakes the mirror without a timer", async () => {
  const { dir, file } = transcriptDir();
  let calls = 0;
  const stop = watchTranscript(dir, () => {
    calls += 1;
  });
  try {
    assert.equal(calls, 1, "the watch reads what is already there before it waits");
    appendFileSync(file, "second line\n");
    assert.ok(await until(() => calls > 1), "a written line must wake the mirror");
  } finally {
    stop();
  }
});

test("stopping the watch stops the mirror, so a finished run wakes for nothing", async () => {
  const { dir, file } = transcriptDir();
  let calls = 0;
  const stop = watchTranscript(dir, () => {
    calls += 1;
  });
  stop();
  const afterStop = calls;
  appendFileSync(file, "written after the agent finished\n");
  await new Promise((resolve) => setTimeout(resolve, 200));
  assert.equal(calls, afterStop, "a stopped watch reports nothing");
});
