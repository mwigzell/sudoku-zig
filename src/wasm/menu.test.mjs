// menu.test.mjs — Edit menu undo/redo contract.

import assert from "node:assert/strict";
import { applySelection } from "./board.js";
import {
  syncEditMenu,
  parseEditShortcut,
  handleEditAction,
  handleDeselect,
  anyMenuOpen,
  wireEditMenu,
} from "./menu.js";

function makeBtn() {
  const handlers = {};
  return {
    disabled: false,
    addEventListener(type, fn) {
      handlers[type] = fn;
    },
    click() {
      handlers.click?.();
    },
  };
}

function emptyState() {
  return {
    cells: Array.from({ length: 81 }, () => ({ value: 0, given: false, conflict: false })),
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

function makeMockBoard() {
  return {
    children: [],
    replaceChildren(...nodes) {
      this.children.length = 0;
      this.children.push(...nodes);
    },
  };
}

// ── legend sync ──
{
  const undoBtn = makeBtn();
  const redoBtn = makeBtn();
  const deselectBtn = makeBtn();
  syncEditMenu({ undo: false, redo: true }, { undo: undoBtn, redo: redoBtn, deselect: deselectBtn }, {
    getSelection: () => ({ row: 0, col: 0 }),
  });
  assert.equal(undoBtn.disabled, true);
  assert.equal(redoBtn.disabled, false);
  assert.equal(deselectBtn.disabled, false);

  syncEditMenu({ undo: false, redo: true }, { undo: undoBtn, redo: redoBtn, deselect: deselectBtn }, {
    getSelection: () => null,
  });
  assert.equal(deselectBtn.disabled, true);
}

// ── deselect ──
{
  let selected = { row: 1, col: 2 };
  const selection = {
    getSelection: () => selected,
    deselect() {
      selected = null;
    },
  };
  assert.equal(handleDeselect(selection).handled, true);
  assert.equal(selected, null);
  assert.equal(handleDeselect(selection).handled, false);
}

// ── keyboard shortcuts ──
assert.equal(parseEditShortcut({ ctrlKey: true, altKey: false, key: "z", shiftKey: false }), "undo");
assert.equal(parseEditShortcut({ ctrlKey: true, altKey: false, key: "z", shiftKey: true }), "redo");
assert.equal(parseEditShortcut({ ctrlKey: false, key: "z", shiftKey: false }), null);

// ── undo exec + board refresh ──
{
  const board = makeMockBoard();
  const status = { textContent: "", className: "" };
  const errorModal = { el: { hidden: true }, msgEl: { textContent: "" } };
  const selection = { getSelection: () => ({ row: 0, col: 2 }), select(r, c) { applySelection(board, r, c); } };
  const session = {
    state: emptyState(),
    legend: { undo: true, redo: false },
  };
  session.state.cells[18] = { value: 7, given: false, conflict: false };

  const game = {
    exec(action) {
      assert.equal(action.action, "undo");
      session.state = emptyState();
      return { ok: true, state: session.state, msg: null, is_quit: false };
    },
    getLegend() {
      return { undo: false, redo: true };
    },
  };

  const outcome = handleEditAction(
    "undo",
    game,
    board,
    selection,
    status,
    errorModal,
    session,
    makeRenderElement(),
  );
  assert.equal(outcome.handled, true);
  assert.equal(session.state.cells[18].value, 0);
  assert.equal(session.legend.redo, true);
}

// ── disabled when legend false ──
{
  const session = { state: emptyState(), legend: { undo: false, redo: false } };
  let execCalls = 0;
  const outcome = handleEditAction(
    "undo",
    { exec: () => { execCalls += 1; return { ok: true, state: session.state }; }, getLegend: () => session.legend },
    makeMockBoard(),
    { getSelection: () => ({ row: 0, col: 0 }), select() {} },
    { textContent: "", className: "" },
    { el: { hidden: true }, msgEl: { textContent: "" } },
    session,
    makeRenderElement(),
  );
  assert.equal(outcome.handled, false);
  assert.equal(execCalls, 0);
}

// ── wireEditMenu click updates enablement ──
{
  const undoBtn = makeBtn();
  const redoBtn = makeBtn();
  const deselectBtn = makeBtn();
  const session = { state: emptyState(), legend: { undo: true, redo: false } };
  const listeners = {};
  const root = {
    querySelectorAll(selector) {
      if (selector === "#menu-bar .menu") return [{ dataset: { open: "false" } }];
      return [];
    },
    addEventListener(type, fn) {
      listeners[type] = fn;
    },
  };

  const game = {
    exec(action) {
      assert.equal(action.action, "undo");
      session.legend = { undo: false, redo: true };
      return { ok: true, state: session.state, msg: null, is_quit: false };
    },
    getLegend() {
      return session.legend;
    },
  };

  let selected = { row: 0, col: 0 };
  const selection = {
    getSelection: () => selected,
    deselect() {
      selected = null;
    },
    select() {},
  };

  wireEditMenu(
    undoBtn,
    redoBtn,
    deselectBtn,
    game,
    makeMockBoard(),
    selection,
    { textContent: "", className: "" },
    { el: { hidden: true }, msgEl: { textContent: "" } },
    session,
    makeRenderElement(),
    root,
  );

  assert.equal(undoBtn.disabled, false);
  assert.equal(redoBtn.disabled, true);
  assert.equal(deselectBtn.disabled, false);
  undoBtn.click();
  assert.equal(undoBtn.disabled, true);
  assert.equal(redoBtn.disabled, false);

  let prevented = false;
  listeners.keydown({
    ctrlKey: true,
    altKey: false,
    key: "z",
    shiftKey: false,
    preventDefault() {
      prevented = true;
    },
  });
  assert.equal(prevented, false, "shortcut should not fire when undo disabled");

  selected = { row: 3, col: 3 };
  deselectBtn.click();
  assert.equal(selected, null);
  assert.equal(deselectBtn.disabled, true);

  selected = { row: 1, col: 1 };
  let escPrevented = false;
  listeners.keydown({
    key: "Escape",
    preventDefault() {
      escPrevented = true;
    },
  });
  assert.equal(escPrevented, true);
  assert.equal(selected, null);

  selected = { row: 2, col: 2 };
  root.querySelectorAll = () => [{ dataset: { open: "true" } }];
  escPrevented = false;
  listeners.keydown({
    key: "Escape",
    preventDefault() {
      escPrevented = true;
    },
  });
  assert.equal(escPrevented, false, "Escape with menu open should not deselect");
  assert.deepEqual(selected, { row: 2, col: 2 });
}

assert.equal(anyMenuOpen({ querySelectorAll: () => [] }), false);

console.log("menu.test.mjs OK");
