// board.test.mjs — DOM board shell contract (#37).

import assert from "node:assert/strict";
import {
  cellIndex,
  cellClasses,
  formatDigit,
  boardCellDescriptors,
  renderBoard,
  setStatus,
  moveSelection,
  findCellElement,
  applySelection,
  wireSelection,
  parsePlayKey,
  handlePlayKey,
  wirePlayLoop,
} from "./board.js";
import { applyEventStatus, applyExecResult, showErrorModal } from "./shell.js";

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

// ── selection (#38) ──

assert.deepEqual(moveSelection(4, 4, "ArrowUp"), { row: 3, col: 4 });
assert.deepEqual(moveSelection(0, 0, "ArrowUp"), { row: 0, col: 0 });
assert.deepEqual(moveSelection(8, 8, "ArrowDown"), { row: 8, col: 8 });
assert.deepEqual(moveSelection(2, 5, "ArrowLeft"), { row: 2, col: 4 });
assert.deepEqual(moveSelection(2, 8, "ArrowRight"), { row: 2, col: 8 });

function makeMockCell(row, col) {
  const el = {
    dataset: { row: String(row), col: String(col) },
    classList: {
      _set: new Set(),
      add(...names) {
        names.forEach((n) => this._set.add(n));
      },
      remove(...names) {
        names.forEach((n) => this._set.delete(n));
      },
      contains(name) {
        return this._set.has(name);
      },
    },
  };
  return el;
}

function makeMockBoard() {
  const cells = [];
  for (let row = 0; row < 9; row += 1) {
    for (let col = 0; col < 9; col += 1) {
      cells.push(makeMockCell(row, col));
    }
  }
  return {
    children: cells,
    tabIndex: undefined,
    _listeners: {},
    addEventListener(type, fn) {
      this._listeners[type] = fn;
    },
    replaceChildren(...nodes) {
      this.children.length = 0;
      this.children.push(...nodes);
    },
  };
}

function makeRenderElement() {
  return (tag) => {
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
      remove(...names) {
        names.forEach((n) => this._set.delete(n));
      },
      contains(name) {
        return this._set.has(name);
      },
    };
    return el;
  };
}

{
  const board = makeMockBoard();
  applySelection(board, 1, 2);
  assert.ok(findCellElement(board, 1, 2).classList.contains("selected"));
  assert.equal(
    board.children.filter((c) => c.classList.contains("selected")).length,
    1,
  );
  applySelection(board, 4, 4);
  assert.ok(!findCellElement(board, 1, 2).classList.contains("selected"));
  assert.ok(findCellElement(board, 4, 4).classList.contains("selected"));
}

{
  const board = makeMockBoard();
  const controller = wireSelection(board, { row: 0, col: 0 });
  assert.equal(board.tabIndex, 0);
  assert.deepEqual(controller.getSelection(), { row: 0, col: 0 });
  assert.ok(findCellElement(board, 0, 0).classList.contains("selected"));

  board._listeners.keydown({ key: "ArrowRight", preventDefault() {} });
  assert.deepEqual(controller.getSelection(), { row: 0, col: 1 });
  assert.ok(findCellElement(board, 0, 1).classList.contains("selected"));

  const target = findCellElement(board, 5, 5);
  board._listeners.click({ target });
  assert.deepEqual(controller.getSelection(), { row: 5, col: 5 });
  assert.ok(target.classList.contains("selected"));
}

// ── play loop (#39) ──

assert.deepEqual(parsePlayKey("5"), { type: "fill", digit: 5 });
assert.equal(parsePlayKey("ArrowUp"), null);
assert.deepEqual(parsePlayKey("Backspace"), { type: "clear" });
assert.deepEqual(parsePlayKey(" "), { type: "clear" });
assert.deepEqual(parsePlayKey("", "Space"), { type: "clear" });
assert.deepEqual(parsePlayKey("", "Backspace"), { type: "clear" });
assert.deepEqual(parsePlayKey("", "Delete"), { type: "clear" });

function emptyState() {
  return {
    cells: Array.from({ length: 81 }, () => ({ value: 0, given: false, conflict: false })),
  };
}

const openLegend = { fill: true, clear: true, undo: false, redo: false };

{
  const board = makeMockBoard();
  const status = { textContent: "", className: "" };
  const errorModal = { el: { hidden: true }, msgEl: { textContent: "" } };
  const selection = { getSelection: () => ({ row: 0, col: 2 }), select(r, c) { applySelection(board, r, c); } };
  const session = { state: emptyState(), legend: openLegend };
  const game = {
    exec(action) {
      assert.equal(action.action, "fill");
      assert.equal(action.row, 0);
      assert.equal(action.col, 2);
      assert.equal(action.digit, 4);
      session.state = emptyState();
      session.state.cells[cellIndex(0, 2)] = { value: 4, given: false, conflict: false };
      return { ok: true, state: session.state, msg: null, is_quit: false };
    },
    getLegend() {
      return { fill: true, clear: true, undo: true, redo: false };
    },
  };

  const outcome = handlePlayKey(
    game,
    board,
    selection,
    status,
    errorModal,
    "4",
    session,
    makeRenderElement(),
  );
  assert.equal(outcome.handled, true);
  assert.equal(session.state.cells[cellIndex(0, 2)].value, 4);
  assert.equal(findCellElement(board, 0, 2).textContent, "4");
  assert.ok(findCellElement(board, 0, 2).classList.contains("selected"));
  assert.equal(outcome.legend.undo, true);
}

{
  const board = makeMockBoard();
  const status = { textContent: "", className: "" };
  const errorModal = { el: { hidden: true }, msgEl: { textContent: "" } };
  const selection = { getSelection: () => ({ row: 0, col: 0 }) };
  const session = { state: emptyState(), legend: openLegend };
  session.state.cells[0] = { value: 1, given: true, conflict: false };

  const outcome = handlePlayKey(
    { exec: () => ({ ok: false, error: "cannot modify a puzzle cell" }) },
    board,
    selection,
    status,
    errorModal,
    "5",
    session,
    makeRenderElement(),
  );
  assert.equal(outcome.handled, true);
  assert.equal(status.textContent, "");
  assert.match(errorModal.msgEl.textContent, /puzzle/i);
  assert.equal(errorModal.el.hidden, false);
}

{
  const status = { textContent: "saved to: foo", className: "" };
  applyEventStatus(status, { ok: true, msg: null });
  assert.equal(status.textContent, "");

  applyEventStatus(status, { ok: true, msg: "opened: bar" });
  assert.equal(status.textContent, "opened: bar");
  assert.equal(status.className, "");

  const errorModal = { el: { hidden: true }, msgEl: { textContent: "" } };
  applyExecResult(status, errorModal, { ok: false, error: "cannot modify a puzzle cell" });
  assert.equal(status.textContent, "opened: bar");
  showErrorModal(errorModal, "cannot modify a puzzle cell");
  assert.equal(errorModal.msgEl.textContent, "cannot modify a puzzle cell");
  assert.equal(errorModal.el.hidden, false);
}

console.log("board.test.mjs OK");
