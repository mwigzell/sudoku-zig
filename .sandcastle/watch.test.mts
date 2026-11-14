// watch.test.mts — following a run prints each event once and stops when the run does.

import test from "node:test";
import assert from "node:assert/strict";
import { newLines, newTextLines } from "./watch.mts";
import type { RunEvent } from "./events.mts";

const EVENTS: RunEvent[] = [
  { at: "t1", kind: "run", message: "on the step loop" },
  { at: "t2", kind: "step", message: "the first piece" },
  { at: "t3", kind: "tick", message: "ticked" },
];

test("a first read prints everything the run has logged", () => {
  const read = newLines(EVENTS, 0);

  assert.deepEqual(read.lines, ["t1 [run] on the step loop", "t2 [step] the first piece", "t3 [tick] ticked"]);
  assert.equal(read.seen, 3);
});

test("a later read prints only what was added, so an event is never shown twice", () => {
  const read = newLines(EVENTS, 2);

  assert.deepEqual(read.lines, ["t3 [tick] ticked"]);
  assert.equal(read.seen, 3);
});

test("a read with nothing new prints nothing and holds its place", () => {
  assert.deepEqual(newLines(EVENTS, 3), { lines: [], seen: 3 });
});

test("the agent's own transcript is followed by offset, so each line is printed once", () => {
  const text = "first line\nsecond line\nthird";
  const first = newTextLines(text, 0);

  assert.deepEqual(first.lines, ["first line", "second line"], "a half-written last line waits for its newline");
  assert.deepEqual(newTextLines(text, first.offset).lines, []);
  assert.deepEqual(newTextLines(`${text} line\n`, first.offset).lines, ["third line"]);
});
