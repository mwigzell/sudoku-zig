// board.test.mjs — DOM board shell contract (#37).

import assert from "node:assert/strict";
import {
  cellIndex,
  cellClasses,
  formatDigit,
  boardCellDescriptors,
  renderBoard,
  setStatus,
} from "./board.js";

assert.equal(cellIndex(2, 4), 22);
assert.equal(cellIndex(0, 0), 0);
assert.equal(cellIndex(8, 8), 80);

{
  const given = { value: 7, given: true, conflict: false };
  const classes = cellClasses(0, 0, given);
  assert.ok(classes.includes("cell"));
  assert.ok(classes.includes("given"));
  assert.ok(!classes.includes("conflict"));
  assert.ok(!classes.includes("player"));
}

{
  const conflict = { value: 3, given: false, conflict: true };
  const classes = cellClasses(1, 1, conflict);
  assert.ok(classes.includes("conflict"));
  assert.ok(classes.includes("player"));
}

{
  const classes = cellClasses(2, 5, { value: 0, given: false, conflict: false });
  assert.ok(classes.includes("empty"));
  assert.ok(classes.includes("box-right"));
  assert.ok(classes.includes("box-bottom"));
}

assert.equal(formatDigit({ value: 0 }), "");
assert.equal(formatDigit({ value: 9 }), "9");

{
  const state = {
    cells: [
      { value: 5, given: true, conflict: false },
      { value: 0, given: false, conflict: false },
    ].concat(Array(79).fill({ value: 0, given: false, conflict: false })),
  };
  const desc = boardCellDescriptors(state);
  assert.equal(desc.length, 81);
  assert.equal(desc[0].text, "5");
  assert.ok(desc[0].classes.includes("given"));
  assert.equal(desc[1].text, "");
  assert.ok(desc[1].classes.includes("empty"));
}

{
  const boardEl = { _children: [], replaceChildren(...nodes) { this._children = nodes; } };
  const state = {
    cells: Array.from({ length: 81 }, (_, i) =>
      i === 0 ? { value: 1, given: true, conflict: false } : { value: 0, given: false, conflict: false },
    ),
  };
  renderBoard(boardEl, state, (tag) => {
    const el = { tag, className: "", textContent: "", dataset: {}, attrs: {} };
    el.setAttribute = (name, value) => {
      el.attrs[name] = value;
    };
    el.classList = {
      _set: new Set(),
      add(...names) {
        names.forEach((n) => this._set.add(n));
        el.className = [...this._set].join(" ");
      },
    };
    return el;
  });
  assert.equal(boardEl._children.length, 81);
  assert.equal(boardEl._children[0].textContent, "1");
  assert.ok(boardEl._children[0].className.includes("given"));
}

{
  const el = { textContent: "", className: "", classList: { add() {}, remove() {} } };
  setStatus(el, "Ready");
  assert.equal(el.textContent, "Ready");
  assert.equal(el.className, "");
  setStatus(el, "bad move", { error: true });
  assert.equal(el.textContent, "bad move");
  assert.equal(el.className, "error");
  setStatus(el, "ok again");
  assert.equal(el.className, "");
}

console.log("board.test.mjs OK");
