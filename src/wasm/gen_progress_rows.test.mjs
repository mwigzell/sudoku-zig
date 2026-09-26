// gen_progress_rows.test.mjs — progressive generating modal row model.

import assert from "node:assert/strict";
import {
  GEN_PROGRESS_ROW_COUNT,
  GEN_PROGRESS_HINT_DIG_HOLE,
  GEN_PROGRESS_HINT_FAST,
  createGenProgressRowState,
  applyGenProgressRowEvent,
} from "./gen_progress_rows.js";

{
  const s = createGenProgressRowState();
  assert.equal(GEN_PROGRESS_ROW_COUNT, 5);
  assert.deepEqual(s.rows, ["", "", "", "", ""]);
  assert.equal(s.attemptHint, "");
}

{
  let s = createGenProgressRowState();
  s = applyGenProgressRowEvent(s, 0, 0, 0);
  assert.equal(s.rows[0], "Generating: new attempt…");
  assert.deepEqual(s.rows.slice(1), ["", "", "", ""]);
}

{
  let s = createGenProgressRowState();
  s = applyGenProgressRowEvent(s, 2, 3, 256);
  assert.equal(s.rows[1], "Generating: try 3/256");
  assert.deepEqual(s.rows.slice(2), ["", "", ""]);
  s = applyGenProgressRowEvent(s, 2, 4, 256);
  assert.equal(s.rows[1], "Generating: try 4/256");
}

{
  let s = createGenProgressRowState();
  s = applyGenProgressRowEvent(s, 2, 10, 256);
  s = applyGenProgressRowEvent(s, 1, 0, 0);
  assert.equal(s.rows[1], "Generating: carving clues…");
  assert.deepEqual(s.rows.slice(2), ["", "", ""]);
}

{
  let s = createGenProgressRowState();
  s = applyGenProgressRowEvent(s, 3, 40, 45);
  assert.equal(s.rows[2], "Generating: 40 givens (target ≤45)");
  assert.deepEqual(s.rows.slice(3), ["", ""]);
  s = applyGenProgressRowEvent(s, 4, 32, 35);
  assert.equal(s.rows[2], "Generating: 32 givens → ≤35");
  assert.equal(s.rows[3], "");
}

{
  let s = createGenProgressRowState();
  s = applyGenProgressRowEvent(s, 5, 28, 0);
  assert.equal(s.rows[3], "Generating: checking uniqueness (28 givens)…");
  assert.equal(s.rows[4], "");
  s = applyGenProgressRowEvent(s, 5, 27, 0);
  assert.equal(s.rows[3], "Generating: checking uniqueness (27 givens)…");
}

{
  let s = createGenProgressRowState();
  s = applyGenProgressRowEvent(s, 2, 1, 256);
  s = applyGenProgressRowEvent(s, 3, 36, 40);
  s = applyGenProgressRowEvent(s, 0, 0, 0);
  assert.equal(s.rows[0], "Generating: new attempt…");
  assert.deepEqual(s.rows.slice(1), ["", "", "", ""]);
  assert.equal(s.attemptHint, "");
}

{
  let s = createGenProgressRowState();
  s = applyGenProgressRowEvent(s, 0, 0, 0);
  assert.equal(s.attemptHint, "");
  s = applyGenProgressRowEvent(s, 2, 1, 256);
  assert.equal(s.attemptHint, GEN_PROGRESS_HINT_FAST);
  s = applyGenProgressRowEvent(s, 2, 2, 256);
  assert.equal(s.attemptHint, GEN_PROGRESS_HINT_FAST);
}

{
  let s = createGenProgressRowState();
  s = applyGenProgressRowEvent(s, 2, 50, 256);
  s = applyGenProgressRowEvent(s, 1, 0, 0);
  assert.equal(s.attemptHint, GEN_PROGRESS_HINT_DIG_HOLE);
  assert.equal(s.rows[1], "Generating: carving clues…");
}

{
  let s = createGenProgressRowState();
  s = applyGenProgressRowEvent(s, 1, 0, 0);
  s = applyGenProgressRowEvent(s, 3, 30, 35);
  assert.equal(s.attemptHint, GEN_PROGRESS_HINT_DIG_HOLE);
  s = applyGenProgressRowEvent(s, 0, 0, 0);
  assert.equal(s.attemptHint, "");
}
