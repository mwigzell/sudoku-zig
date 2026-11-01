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
import { LEGEND_WIRE_COPY, LEGEND_WIRE_PASTE } from "./menu_bar.js";
import { hostFetch, loadGame, postedCurrentFile, settleFlow, startNewGame, withCoreFlow } from "./test_support.mjs";


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

const statusStub = (text = "") => ({ textContent: text, className: "" });
const errorModalStub = () => ({ el: { hidden: true }, msgEl: { textContent: "" } });

async function editGame(config = {}) {
  const game = await loadGame(config);
  startNewGame(game);
  return {
    game,
    session: {
      state: game.getState(),
      legend: game.getLegend(),
      config: game.getConfig(),
      default_save_filename: "sudoku.sud",
    },
  };
}

function runEdit(action, game, session, { selection = { getSelection: () => null, select() {} }, status = statusStub() } = {}) {
  return handleEditAction(action, game, makeMockBoard(), selection, status, errorModalStub(), session, makeRenderElement());
}

// ── undo exec + board refresh ──
{
  const { game, session } = await editGame();
  assert.equal(game.exec({ action: "fill", row: 0, col: 2, digit: 4 }).ok, true);
  session.legend = game.getLegend();
  const outcome = runEdit("undo", game, session);
  assert.equal(outcome.handled, true);
  await outcome.done;
  assert.equal(session.state.cells[2].value, 0);
  assert.equal(session.legend.redo, true);
}

// ── solve and hint with auto-save persist the current game ──
for (const action of ["solve", "hint"]) {
  const { game, session } = await editGame({ auto_save: true });
  const host = hostFetch();
  const prevFetch = globalThis.fetch;
  globalThis.fetch = host.fetchFn;
  const outcome = runEdit(action, game, session);
  assert.equal(outcome.handled, true);
  await outcome.done;
  globalThis.fetch = prevFetch;
  assert.equal(postedCurrentFile(host.calls)?.init?.method, "POST", `${action} autosaves`);
}

// ── hint: core picks a cell when deselected, targets the selected cell otherwise ──
{
  const { game, session } = await editGame();
  const status = statusStub();
  await runEdit("hint", game, session, { status }).done;
  assert.match(status.textContent, /takes [1-9] \(placement\)/);
  await runEdit("hint", game, session, { status, selection: { getSelection: () => ({ row: 1, col: 2 }), select() {} } }).done;
  assert.match(status.textContent, /^C2 takes [1-9] \(placement\)/);
}

// ── wireEditMenu Hint menuitem click shows status ──
{
  const hintBtn = makeBtn();
  hintBtn.id = "edit-hint";
  let closedMenus = 0;
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
  const { game, session } = await editGame();
  const status = statusStub("keep");
  wireEditMenu(
    makeBtn(),
    makeBtn(),
    makeBtn(),
    game,
    makeMockBoard(),
    { getSelection: () => ({ row: 2, col: 3 }), select() {} },
    status,
    errorModalStub(),
    session,
    makeRenderElement(),
    root,
    { closeMenus: () => { closedMenus += 1; } },
  );
  hintBtn.click();
  await settleFlow();
  assert.match(status.textContent, /^D3 takes [1-9] \(placement\)/);
  assert.equal(closedMenus, 1);
}

// ── disabled when legend false ──
{
  const { game, session } = await editGame();
  const before = JSON.stringify(game.getState());
  const outcome = runEdit("undo", game, session);
  assert.equal(outcome.handled, false);
  assert.equal(JSON.stringify(game.getState()), before);
}

// ── wireEditMenu click updates enablement ──
{
  const undoBtn = makeBtn();
  undoBtn.id = "edit-undo";
  const redoBtn = makeBtn();
  redoBtn.id = "edit-redo";
  const deselectBtn = makeBtn();
  deselectBtn.id = "edit-deselect";
  const { game, session } = await editGame();
  assert.equal(game.exec({ action: "fill", row: 0, col: 2, digit: 4 }).ok, true);
  session.legend = game.getLegend();
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
    statusStub(),
    errorModalStub(),
    session,
    makeRenderElement(),
    root,
  );

  assert.equal(undoBtn.disabled, false);
  assert.equal(redoBtn.disabled, true);
  assert.equal(deselectBtn.disabled, false);
  undoBtn.click();
  await settleFlow();
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
  const game = await withCoreFlow({
    exportPuzzle() {
      return { ok: true, bytes: new TextEncoder().encode(line) };
    },
  });
  const status = { textContent: "", className: "" };
  const errorModal = { el: { hidden: true }, msgEl: { textContent: "" } };
  const result = await handleCopyPuzzle(game, session, status, errorModal, {
    clipboard: { writeText: async (text) => { written = text; } },
  });
  assert.equal(result.ok, true);
  assert.equal(written, line, "clipboard gets exportPuzzle one-line string");
  assert.equal(status.textContent, "copy: puzzle line copied", "core owns the copy status");
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
  const game = await withCoreFlow({
    exportPuzzle() {
      return { ok: true, bytes: new TextEncoder().encode("2".repeat(81)) };
    },
  });
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
    await withCoreFlow({
      exportPuzzle() {
        return { ok: true, bytes: lineBytes };
      },
    }),
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
  await settleFlow();
  assert.equal(written, "1".repeat(81));
}

const GOLDEN_PUZZLE_LINE =
  "003020600900305001001806400008102900700000008006708200002609500800203009005010300";

// ── Paste reads clipboard → pastePuzzle; session updates ──
{
  let pastedWith = null;
  const session = {
    legend: { [LEGEND_WIRE_PASTE]: true },
    state: { cells: [{ value: 1, given: true, conflict: false }] },
    fileHandle: { name: "bound.sud" },
    boundFilename: "bound.sud",
  };
  const nextState = { cells: [{ value: 3, given: false, conflict: false }] };
  const game = await withCoreFlow({
    pastePuzzle(text) {
      pastedWith = text;
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
  });
  const status = { textContent: "", className: "" };
  const errorModal = { el: { hidden: true }, msgEl: { textContent: "" } };
  const result = await handlePastePuzzle(game, session, status, errorModal, {
    clipboard: { readText: async () => GOLDEN_PUZZLE_LINE },
  });
  assert.equal(result.ok, true);
  assert.equal(pastedWith, GOLDEN_PUZZLE_LINE);
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
    pastePuzzle() {
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
  let pasteCalled = false;
  const result = await handlePastePuzzle(
    { pastePuzzle() { pasteCalled = true; return { ok: true }; } },
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
  assert.equal(pasteCalled, false);
  assert.equal(errorModal.el.hidden, false);
  assert.match(errorModal.msgEl.textContent, /clipboard/i);
  assert.equal(JSON.stringify(session.state), before);
}

// ── Paste no-op when legend.paste is off ──
{
  let readCalled = false;
  const session = { legend: {}, state: { cells: [] } };
  const result = await handlePastePuzzle(
    { pastePuzzle() { return { ok: true }; } },
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
  const game = await withCoreFlow({
    pastePuzzle(text) {
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
  });
  wireEditMenu(
    makeBtn(),
    makeBtn(),
    makeBtn(),
    game,
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
  const host = hostFetch();
  const prevFetch = globalThis.fetch;
  globalThis.fetch = host.fetchFn;
  const game = await withCoreFlow({
      pastePuzzle() {
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
  }, { autoSave: true });
  wireEditMenu(
    makeBtn(),
    makeBtn(),
    makeBtn(),
    game,
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
  await settleFlow();
  globalThis.fetch = prevFetch;
  assert.equal(postedCurrentFile(host.calls)?.init?.method, "POST");
}

console.log("menu.test.mjs OK");
