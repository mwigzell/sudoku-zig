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
  handleCopyPuzzle,
  handlePastePuzzle,
} from "./menu.js";
import { applyHintExecStatus } from "./shell.js";
import { LEGEND_WIRE_COPY, LEGEND_WIRE_PASTE } from "./menu_bar.js";

function makeBtn() {
  const handlers = {};
  return {
    disabled: false,
    addEventListener(type, fn) {
      handlers[type] = fn;
    },
    click() {
      const event = { stopPropagation() {} };
      handlers.click?.(event);
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

// ── solve with auto-save persists current snapshot ──
{
  const board = makeMockBoard();
  const status = { textContent: "", className: "" };
  const errorModal = { el: { hidden: true }, msgEl: { textContent: "" } };
  const selection = { getSelection: () => ({ row: 0, col: 0 }), select() {} };
  const session = {
    state: emptyState(),
    legend: { solve: true, undo: false, redo: false },
    config: { auto_save: true },
    default_save_filename: "sudoku.sud",
  };
  let posted = null;
  const prevFetch = globalThis.fetch;
  globalThis.fetch = async (url, init) => {
    posted = { url, init };
    return { ok: true, status: 204 };
  };
  const game = {
    exec(action) {
      assert.equal(action.action, "solve");
      return { ok: true, state: session.state, msg: "Solved", is_quit: false };
    },
    getLegend() {
      return { solve: true, undo: true, redo: false };
    },
    serialize() {
      return { ok: true, bytes: new Uint8Array([4, 5, 6]) };
    },
  };

  const outcome = handleEditAction(
    "solve",
    game,
    board,
    selection,
    status,
    errorModal,
    session,
    makeRenderElement(),
  );
  assert.equal(outcome.handled, true);
  await Promise.resolve();
  globalThis.fetch = prevFetch;
  assert.equal(posted?.url, "./current-file");
  assert.equal(posted?.init?.method, "POST");
}

// ── hint exec status: msg on bar; empty ok preserves bar, no modal ──
{
  const status = { textContent: "keep me", className: "" };
  const modal = { el: { hidden: true }, msgEl: { textContent: "" } };
  applyHintExecStatus(status, modal, { ok: true, msg: null });
  assert.equal(status.textContent, "keep me");
  assert.equal(modal.el.hidden, true);
  applyHintExecStatus(status, modal, { ok: true, msg: "B2 takes 6 (placement)" });
  assert.equal(status.textContent, "B2 takes 6 (placement)");
}

// ── hint: engine-pick when deselected ──
{
  const session = { state: emptyState(), legend: { undo: false, redo: false } };
  const game = {
    exec(action) {
      assert.deepEqual(action, { action: "hint" });
      return { ok: true, state: session.state, msg: "A1 takes 5 (placement)", is_quit: false };
    },
    getLegend() {
      return session.legend;
    },
  };
  const status = { textContent: "", className: "" };
  const outcome = handleEditAction(
    "hint",
    game,
    makeMockBoard(),
    { getSelection: () => null, select() {} },
    status,
    { el: { hidden: true }, msgEl: { textContent: "" } },
    session,
    makeRenderElement(),
  );
  assert.equal(outcome.handled, true);
  assert.match(status.textContent, /placement/);
}

// ── hint: targeted when cell selected ──
{
  const session = { state: emptyState(), legend: { undo: false, redo: false } };
  const game = {
    exec(action) {
      assert.deepEqual(action, { action: "hint", row: 1, col: 2 });
      return { ok: true, state: session.state, msg: "C2 takes 3 (placement)", is_quit: false };
    },
    getLegend() {
      return session.legend;
    },
  };
  const outcome = handleEditAction(
    "hint",
    game,
    makeMockBoard(),
    { getSelection: () => ({ row: 1, col: 2 }), select() {} },
    { textContent: "", className: "" },
    { el: { hidden: true }, msgEl: { textContent: "" } },
    session,
    makeRenderElement(),
  );
  assert.equal(outcome.handled, true);
}

// ── wireEditMenu Hint menuitem click shows status ──
{
  const hintBtn = makeBtn();
  hintBtn.id = "edit-hint";
  const root = {
    querySelector(sel) {
      if (sel === "#edit-hint") return hintBtn;
      return null;
    },
    querySelectorAll() {
      return [];
    },
    addEventListener() {},
  };
  const session = { state: emptyState(), legend: { undo: false, redo: false } };
  const status = { textContent: "keep", className: "" };
  const game = {
    exec(action) {
      assert.deepEqual(action, { action: "hint", row: 2, col: 3 });
      return { ok: true, state: session.state, msg: "D4 takes 7 (placement)", is_quit: false };
    },
    getLegend() {
      return session.legend;
    },
  };
  wireEditMenu(
    makeBtn(),
    makeBtn(),
    makeBtn(),
    game,
    makeMockBoard(),
    { getSelection: () => ({ row: 2, col: 3 }), select() {} },
    status,
    { el: { hidden: true }, msgEl: { textContent: "" } },
    session,
    makeRenderElement(),
    root,
  );
  hintBtn.click();
  assert.match(status.textContent, /D4 takes 7 \(placement\)/);
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
  undoBtn.id = "edit-undo";
  const redoBtn = makeBtn();
  redoBtn.id = "edit-redo";
  const deselectBtn = makeBtn();
  deselectBtn.id = "edit-deselect";
  const session = { state: emptyState(), legend: { undo: true, redo: false } };
  const listeners = {};
  const root = {
    querySelector() {
      return null;
    },
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

// ── Copy sends exportPuzzle bytes as clipboard text ──
{
  const line = "003020600900305001001806400008102900700000008006708200002609500800203009005010300";
  let written = null;
  const session = {
    legend: { [LEGEND_WIRE_COPY]: true },
    state: { cells: [{ value: 3, given: false, conflict: false }] },
  };
  const game = {
    exportPuzzle() {
      return { ok: true, bytes: new TextEncoder().encode(line) };
    },
  };
  const status = { textContent: "", className: "" };
  const errorModal = { el: { hidden: true }, msgEl: { textContent: "" } };
  const result = await handleCopyPuzzle(game, session, status, errorModal, {
    clipboard: { writeText: async (text) => { written = text; } },
  });
  assert.equal(result.ok, true);
  assert.equal(written, line, "clipboard gets exportPuzzle one-line string");
  assert.match(status.textContent, /copied puzzle/i);
  assert.equal(errorModal.el.hidden, true);
}

// ── Copy clipboard denied → error modal; board unchanged ──
{
  const session = {
    legend: { [LEGEND_WIRE_COPY]: true },
    state: { cells: [{ value: 2, given: true, conflict: false }] },
  };
  const before = JSON.stringify(session.state);
  const errorModal = { el: { hidden: true }, msgEl: { textContent: "" } };
  const game = {
    exportPuzzle() {
      return { ok: true, bytes: new TextEncoder().encode("2".repeat(81)) };
    },
  };
  const result = await handleCopyPuzzle(
    game,
    session,
    { textContent: "", className: "" },
    errorModal,
    {
      clipboard: {
        writeText: async () => {
          throw new Error("denied");
        },
      },
      doc: {
        createElement() {
          return {
            select() {},
            style: {},
            setAttribute() {},
          };
        },
        body: { appendChild() {}, removeChild() {} },
        execCommand() {
          return false;
        },
      },
    },
  );
  assert.equal(result.ok, false);
  assert.equal(errorModal.el.hidden, false);
  assert.match(errorModal.msgEl.textContent, /clipboard/i);
  assert.equal(JSON.stringify(session.state), before);
}

// ── Copy no-op when legend.copy is off ──
{
  let called = false;
  const session = { legend: {}, state: { cells: [] } };
  const result = await handleCopyPuzzle(
    { exportPuzzle() { called = true; return { ok: true, bytes: new Uint8Array(81) }; } },
    session,
    { textContent: "", className: "" },
    { el: { hidden: true }, msgEl: { textContent: "" } },
    { clipboard: { writeText: async () => {} } },
  );
  assert.equal(result.handled, false);
  assert.equal(called, false);
}

// ── wireEditMenu Copy click ──
{
  const copyBtn = makeBtn();
  const session = { state: emptyState(), legend: { [LEGEND_WIRE_COPY]: true } };
  let written = null;
  const lineBytes = new TextEncoder().encode("1".repeat(81));
  wireEditMenu(
    makeBtn(),
    makeBtn(),
    makeBtn(),
    {
      exportPuzzle() {
        return { ok: true, bytes: lineBytes };
      },
    },
    makeMockBoard(),
    { getSelection: () => null, deselect() {}, select() {} },
    { textContent: "", className: "" },
    { el: { hidden: true }, msgEl: { textContent: "" } },
    session,
    makeRenderElement(),
    { querySelectorAll: () => [], addEventListener() {} },
    {
      copyBtn,
      clipboard: { writeText: async (text) => { written = text; } },
    },
  );
  copyBtn.click();
  await new Promise((resolve) => setTimeout(resolve, 0));
  assert.equal(written, "1".repeat(81));
}

const GOLDEN_PUZZLE_LINE =
  "003020600900305001001806400008102900700000008006708200002609500800203009005010300";

// ── Paste reads clipboard → importPuzzle; session updates ──
{
  let importedWith = null;
  const session = {
    legend: { [LEGEND_WIRE_PASTE]: true },
    state: { cells: [{ value: 1, given: true, conflict: false }] },
    fileHandle: { name: "bound.sud" },
    boundFilename: "bound.sud",
  };
  const nextState = { cells: [{ value: 3, given: false, conflict: false }] };
  const game = {
    importPuzzle(text) {
      importedWith = text;
      return { ok: true, msg: "imported puzzle" };
    },
    getState() {
      return nextState;
    },
    getLegend() {
      return { [LEGEND_WIRE_PASTE]: true };
    },
    getConfig() {
      return { theme: "dark" };
    },
  };
  const status = { textContent: "", className: "" };
  const errorModal = { el: { hidden: true }, msgEl: { textContent: "" } };
  const result = await handlePastePuzzle(game, session, status, errorModal, {
    clipboard: { readText: async () => GOLDEN_PUZZLE_LINE },
  });
  assert.equal(result.ok, true);
  assert.equal(importedWith, GOLDEN_PUZZLE_LINE);
  assert.equal(session.state, nextState);
  assert.equal(session.fileHandle, null);
  assert.equal(session.boundFilename, null);
  assert.match(status.textContent, /imported puzzle/i);
  assert.equal(errorModal.el.hidden, true);
}

// ── Paste invalid line → error modal; board unchanged ──
{
  const session = {
    legend: { [LEGEND_WIRE_PASTE]: true },
    state: { cells: [{ value: 2, given: true, conflict: false }] },
  };
  const before = JSON.stringify(session.state);
  const errorModal = { el: { hidden: true }, msgEl: { textContent: "" } };
  const game = {
    importPuzzle() {
      return { ok: false, error: "import: invalid character in puzzle line" };
    },
  };
  const result = await handlePastePuzzle(
    game,
    session,
    { textContent: "", className: "" },
    errorModal,
    { clipboard: { readText: async () => "x".repeat(81) } },
  );
  assert.equal(result.ok, false);
  assert.equal(errorModal.el.hidden, false);
  assert.match(errorModal.msgEl.textContent, /invalid/i);
  assert.equal(JSON.stringify(session.state), before);
}

// ── Paste clipboard denied → error; state unchanged ──
{
  const session = {
    legend: { [LEGEND_WIRE_PASTE]: true },
    state: { cells: [{ value: 4, given: false, conflict: false }] },
  };
  const before = JSON.stringify(session.state);
  const errorModal = { el: { hidden: true }, msgEl: { textContent: "" } };
  let importCalled = false;
  const result = await handlePastePuzzle(
    { importPuzzle() { importCalled = true; return { ok: true }; } },
    session,
    { textContent: "", className: "" },
    errorModal,
    {
      clipboard: {
        readText: async () => {
          throw new Error("denied");
        },
      },
    },
  );
  assert.equal(result.ok, false);
  assert.equal(importCalled, false);
  assert.equal(errorModal.el.hidden, false);
  assert.match(errorModal.msgEl.textContent, /clipboard/i);
  assert.equal(JSON.stringify(session.state), before);
}

// ── Paste no-op when legend.paste is off ──
{
  let readCalled = false;
  const session = { legend: {}, state: { cells: [] } };
  const result = await handlePastePuzzle(
    { importPuzzle() { return { ok: true }; } },
    session,
    { textContent: "", className: "" },
    { el: { hidden: true }, msgEl: { textContent: "" } },
    {
      clipboard: {
        readText: async () => {
          readCalled = true;
          return GOLDEN_PUZZLE_LINE;
        },
      },
    },
  );
  assert.equal(result.handled, false);
  assert.equal(readCalled, false);
}

// ── wireEditMenu Paste click refreshes board ──
{
  const pasteBtn = makeBtn();
  const session = {
    state: emptyState(),
    legend: { [LEGEND_WIRE_PASTE]: true },
    config: { show_region: false },
  };
  const nextState = emptyState();
  nextState.cells[0] = { value: 5, given: true, conflict: false };
  const boardEl = makeMockBoard();
  wireEditMenu(
    makeBtn(),
    makeBtn(),
    makeBtn(),
    {
      importPuzzle(text) {
        assert.equal(text, GOLDEN_PUZZLE_LINE);
        return { ok: true };
      },
      getState() {
        return nextState;
      },
      getLegend() {
        return session.legend;
      },
      getConfig() {
        return session.config;
      },
    },
    boardEl,
    { getSelection: () => null, deselect() {} },
    { textContent: "", className: "" },
    { el: { hidden: true }, msgEl: { textContent: "" } },
    session,
    makeRenderElement(),
    { querySelectorAll: () => [], addEventListener() {} },
    {
      pasteBtn,
      clipboard: { readText: async () => GOLDEN_PUZZLE_LINE },
    },
  );
  pasteBtn.click();
  await new Promise((resolve) => setTimeout(resolve, 0));
  assert.equal(session.state, nextState);
  assert.equal(boardEl.children.length, 81, "board re-rendered after paste");
}

// ── wireEditMenu Paste click persists when auto-save is enabled ──
{
  const pasteBtn = makeBtn();
  const session = {
    state: emptyState(),
    legend: { [LEGEND_WIRE_PASTE]: true },
    config: { show_region: false, auto_save: true },
    default_save_filename: "sudoku.sud",
  };
  const nextState = emptyState();
  const boardEl = makeMockBoard();
  let posted = null;
  const prevFetch = globalThis.fetch;
  globalThis.fetch = async (url, init) => {
    posted = { url, init };
    return { ok: true, status: 204 };
  };
  wireEditMenu(
    makeBtn(),
    makeBtn(),
    makeBtn(),
    {
      importPuzzle() {
        return { ok: true };
      },
      getState() {
        return nextState;
      },
      getLegend() {
        return session.legend;
      },
      getConfig() {
        return session.config;
      },
      serialize() {
        return { ok: true, bytes: new Uint8Array([9, 9, 9]) };
      },
    },
    boardEl,
    { getSelection: () => null, deselect() {} },
    { textContent: "", className: "" },
    { el: { hidden: true }, msgEl: { textContent: "" } },
    session,
    makeRenderElement(),
    { querySelectorAll: () => [], addEventListener() {} },
    {
      pasteBtn,
      clipboard: { readText: async () => GOLDEN_PUZZLE_LINE },
    },
  );
  pasteBtn.click();
  await new Promise((resolve) => setTimeout(resolve, 0));
  globalThis.fetch = prevFetch;
  assert.equal(posted?.url, "./current-file");
  assert.equal(posted?.init?.method, "POST");
}

console.log("menu.test.mjs OK");
