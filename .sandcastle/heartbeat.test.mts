// heartbeat.test.mts — a run that is still thinking keeps saying so, and stops saying so when it is done.

import test from "node:test";
import assert from "node:assert/strict";
import { heartbeatLine, withHeartbeat } from "./heartbeat.mts";

const work = (ms: number, value: string): Promise<string> => new Promise((resolve) => setTimeout(() => resolve(value), ms));

test("a wait longer than the beat interval beats more than once, and still returns the work's value", async () => {
  const beats: string[] = [];

  const result = await withHeartbeat("implementer", work(80, "done"), (line) => beats.push(line), 20);

  assert.equal(result, "done");
  assert.ok(beats.length >= 2, `expected at least two beats, got ${beats.length}`);
  assert.equal(beats[0]?.startsWith("implementer ("), true);
});

test("a wait shorter than the beat interval beats not at all", async () => {
  const beats: string[] = [];

  assert.equal(await withHeartbeat("reviewer", work(5, "done"), (line) => beats.push(line), 1_000), "done");
  assert.deepEqual(beats, []);
});

test("work that fails is still the caller's failure, and the beat has stopped", async () => {
  const beats: string[] = [];
  const failing = new Promise<string>((_, reject) => setTimeout(() => reject(new Error("agent died")), 30));

  await assert.rejects(withHeartbeat("implementer", failing, (line) => beats.push(line), 10), /agent died/u);
  const settled = beats.length;
  await new Promise((resolve) => setTimeout(resolve, 40));

  assert.equal(beats.length, settled, "nothing keeps beating after the work is over");
});

test("a heartbeat line names the wait and how long it has waited", () => {
  assert.equal(heartbeatLine("final reviewer", 61_000), "final reviewer (61s)");
});
