// board.test.mjs — DOM board shell contract.

import assert from "node:assert/strict";
import {
  cellIndex,
  cellClasses,
  formatDigit,
  boardCellDescriptors,
  ensureBoardFrame,
  getPlayGrid,
  renderBoard,
  setStatus,
  moveSelection,
  findCellElement,
  applySelection,
  wireSelection,
  parsePlayKey,
  handlePlayKey,
  wirePlayLoop,
  COLUMN_LETTERS,
  FRAME_SIZE,
  PLAY_OFFSET,
  GUTTER_FR,
  PLAY_FR,
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

// ── framed board ──

assert.equal(FRAME_SIZE, 11);
assert.equal(PLAY_OFFSET, 1);
assert.equal(GUTTER_FR, 1);
assert.equal(PLAY_FR, 2);
assert.equal(COLUMN_LETTERS, "ABCDEFGHI");

function makeFrameElement() {
  return {
    className: "",
    classList: {
      _set: new Set(),
      add(...names) {
        names.forEach((n) => this._set.add(n));
      },
      contains(name) {
        return this._set.has(name);
      },
    },
    _children: [],
    attrs: {},
    style: {},
    replaceChildren(...nodes) {
      this._children = nodes;
    },
    appendChild(node) {
      this._children.push(node);
    },
    querySelector(sel) {
      if (sel === ".board-play") {
        return this._children.find((c) => c.classList?.contains("board-play")) ?? null;
      }
      return null;
    },
    setAttribute(name, value) {
      this.attrs[name] = value;
    },
  };
}

function makeRenderElement() {
  return (tag) => {
    const el = {
      tag,
      className: "",
      textContent: "",
      dataset: {},
      attrs: {},
      style: {},
      _children: [],
    };
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
    el.appendChild = (node) => {
      el._children.push(node);
    };
    el.replaceChildren = (...nodes) => {
      el._children = nodes;
    };
    return el;
  };
}

{
  const frameEl = makeFrameElement();
  const createElement = makeRenderElement();
  const playEl = ensureBoardFrame(frameEl, createElement);
  assert.ok(frameEl.classList.contains("board-frame"));
  assert.ok(playEl.classList.contains("board-play"));
  assert.equal(getPlayGrid(frameEl), playEl);

  const colLabels = frameEl._children.filter((c) => c.classList.contains("col-label"));
  assert.equal(colLabels.length, 9);
  assert.deepEqual(colLabels.map((c) => c.textContent), [...COLUMN_LETTERS]);

  const rowLabels = frameEl._children.filter((c) => c.classList.contains("row-label"));
  assert.equal(rowLabels.length, 9);
  assert.deepEqual(
    rowLabels.map((c) => c.textContent),
    ["1", "2", "3", "4", "5", "6", "7", "8", "9"],
  );

  for (const cell of frameEl._children) {
    if (cell.classList.contains("col-label") || cell.classList.contains("row-label")) {
      assert.ok(cell.classList.contains("label-cell"));
      assert.ok(!cell.classList.contains("cell"));
    }
    if (cell.classList.contains("gutter-cell")) {
      assert.ok(!cell.classList.contains("cell"));
    }
  }

  const gutter = frameEl._children.filter((c) => c.classList.contains("gutter-cell"));
  assert.ok(colLabels.every((c) => c.style.gridRow === "1"), "column labels in top gutter");
  assert.ok(rowLabels.every((c) => c.style.gridColumn === "1"), "row labels in left gutter");
  assert.ok(gutter.some((c) => c.style.gridRow === "11"), "bottom gutter band");
  assert.ok(
    gutter.some((c) => c.style.gridColumn === "11" && c.style.gridRow !== "11"),
    "right gutter band",
  );
  assert.equal(playEl.style.gridRow, "2 / 11");
  assert.equal(playEl.style.gridColumn, "2 / 11");
}

{
  const frameEl = makeFrameElement();
  const createElement = makeRenderElement();
  const state = {
    cells: Array.from({ length: 81 }, (_, i) =>
      i === 0 ? { value: 1, given: true, conflict: false } : { value: 0, given: false, conflict: false },
    ),
  };
  renderBoard(frameEl, state, createElement);
  const playEl = getPlayGrid(frameEl);
  assert.equal(playEl._children.length, 81);
  assert.equal(playEl._children[0].textContent, "1");
  assert.ok(playEl._children[0].classList.contains("given"));
  assert.ok(playEl._children[0].classList.contains("cell"));
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

// ── selection ──

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
  const play = {
    children: cells,
    tabIndex: undefined,
    _listeners: {},
    classList: {
      _set: new Set(["board-play"]),
      add(...names) {
        names.forEach((n) => this._set.add(n));
      },
      contains(name) {
        return this._set.has(name);
      },
    },
    addEventListener(type, fn) {
      this._listeners[type] = fn;
    },
    replaceChildren(...nodes) {
      this.children.length = 0;
      this.children.push(...nodes);
    },
  };
  return {
    classList: {
      _set: new Set(["board-frame"]),
      add(...names) {
        names.forEach((n) => this._set.add(n));
      },
      contains(name) {
        return this._set.has(name);
      },
    },
    querySelector(sel) {
      return sel === ".board-play" ? play : null;
    },
    get _listeners() {
      return play._listeners;
    },
    get tabIndex() {
      return play.tabIndex;
    },
    set tabIndex(value) {
      play.tabIndex = value;
    },
    play,
  };
}

{
  const board = makeMockBoard();
  applySelection(board, 1, 2);
  assert.ok(findCellElement(board, 1, 2).classList.contains("selected"));
  assert.equal(
    board.play.children.filter((c) => c.classList.contains("selected")).length,
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

  board.play._listeners.keydown({ key: "ArrowRight", preventDefault() {} });
  assert.deepEqual(controller.getSelection(), { row: 0, col: 1 });
  assert.ok(findCellElement(board, 0, 1).classList.contains("selected"));

  const target = findCellElement(board, 5, 5);
  board.play._listeners.click({ target });
  assert.deepEqual(controller.getSelection(), { row: 5, col: 5 });
  assert.ok(target.classList.contains("selected"));
}

// ── play loop ──

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
