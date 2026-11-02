// gen_progress_rows.test.mjs — progressive generating modal row model.

import assert from "node:assert/strict";
import * as genProgressRows from "./gen_progress_rows.js";

{
  const s = genProgressRows.createGenProgressRowState();
  assert.equal(genProgressRows.GEN_PROGRESS_ROW_COUNT, 5);
  assert.deepEqual(s.rows, ["", "", "", "", ""]);
  assert.equal(s.method, "");
}

{
  let s = genProgressRows.createGenProgressRowState();
  s = genProgressRows.applyGenProgressRowEvent(s, 0, "progress line 1");
  assert.equal(s.rows[0], "progress line 1");
  assert.deepEqual(s.rows.slice(1), ["", "", "", ""]);
}

{
  let s = genProgressRows.createGenProgressRowState();
  s = genProgressRows.applyGenProgressRowEvent(s, 2, "progress line 2");
  assert.equal(s.rows[1], "progress line 2");
  assert.deepEqual(s.rows.slice(2), ["", "", ""]);
  s = genProgressRows.applyGenProgressRowEvent(s, 2, "progress line 3");
  assert.equal(s.rows[1], "progress line 3");
}

{
  let s = genProgressRows.createGenProgressRowState();
  s = genProgressRows.applyGenProgressRowEvent(s, 2, "progress line 4");
  s = genProgressRows.applyGenProgressRowEvent(s, 1, "progress line 5");
  assert.equal(s.rows[1], "progress line 5");
  assert.deepEqual(s.rows.slice(2), ["", "", ""]);
}

{
  let s = genProgressRows.createGenProgressRowState();
  s = genProgressRows.applyGenProgressRowEvent(s, 3, "progress line 6");
  assert.equal(s.rows[2], "progress line 6");
  assert.deepEqual(s.rows.slice(3), ["", ""]);
  s = genProgressRows.applyGenProgressRowEvent(s, 4, "progress line 7");
  assert.equal(s.rows[2], "progress line 7");
  assert.equal(s.rows[3], "");
}

{
  let s = genProgressRows.createGenProgressRowState();
  s = genProgressRows.applyGenProgressRowEvent(s, 5, "progress line 8");
  assert.equal(s.rows[3], "progress line 8");
  assert.equal(s.rows[4], "");
  s = genProgressRows.applyGenProgressRowEvent(s, 5, "progress line 9");
  assert.equal(s.rows[3], "progress line 9");
}

{
  let s = genProgressRows.createGenProgressRowState();
  s = genProgressRows.applyGenProgressRowEvent(s, 2, "progress line 10");
  s = genProgressRows.applyGenProgressRowEvent(s, 3, "progress line 11");
  s = genProgressRows.applyGenProgressRowEvent(s, 0, "progress line 1");
  assert.equal(s.rows[0], "progress line 1");
  assert.deepEqual(s.rows.slice(1), ["", "", "", ""]);
  assert.equal(s.method, "");
}

{
  let s = genProgressRows.createGenProgressRowState();
  s = genProgressRows.applyGenProgressRowEvent(s, 0, "progress line 1");
  assert.equal(s.method, "");
  s = genProgressRows.applyGenProgressRowEvent(s, 2, "progress line 10");
  assert.equal(s.method, genProgressRows.GEN_METHOD_FAST);
  s = genProgressRows.applyGenProgressRowEvent(s, 2, "progress line 12");
  assert.equal(s.method, genProgressRows.GEN_METHOD_FAST);
}

{
  let s = genProgressRows.createGenProgressRowState();
  s = genProgressRows.applyGenProgressRowEvent(s, 2, "progress line 13");
  s = genProgressRows.applyGenProgressRowEvent(s, 1, "progress line 5");
  assert.equal(s.method, genProgressRows.GEN_METHOD_DIG_HOLE);
  assert.equal(s.rows[1], "progress line 5");
}

{
  let s = genProgressRows.createGenProgressRowState();
  s = genProgressRows.applyGenProgressRowEvent(s, 1, "progress line 5");
  s = genProgressRows.applyGenProgressRowEvent(s, 3, "progress line 14");
  assert.equal(s.method, genProgressRows.GEN_METHOD_DIG_HOLE);
  s = genProgressRows.applyGenProgressRowEvent(s, 0, "progress line 1");
  assert.equal(s.method, "");
}
