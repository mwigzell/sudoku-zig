// menu.test.mjs — Edit menu undo/redo contract.

import assert from "node:assert/strict";
import * as board from "../board.js";
import * as menu from "./menu.js";
import * as menuBar from "./menu_bar.js";
import { hostFetch, loadGame, postedCurrentFile, settleFlow, startNewGame, withCoreFlow, coreText } from "../test_support.mjs";


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
  menu.syncEditMenu({ undo: false, redo: true }, { undo: undoBtn, redo: redoBtn, deselect: deselectBtn }, {
    getSelection: () => ({ row: 0, col: 0 }),
  });
  assert.equal(undoBtn.disabled, true);
  assert.equal(redoBtn.disabled, false);
  assert.equal(deselectBtn.disabled, false);

  menu.syncEditMenu({ undo: false, redo: true }, { undo: undoBtn, redo: redoBtn, deselect: deselectBtn }, {
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
  assert.equal(menu.handleDeselect(selection).handled, true);
  assert.equal(selected, null);
  assert.equal(menu.handleDeselect(selection).handled, false);
}

// ── keyboard shortcuts ──
assert.equal(menu.parseEditShortcut({ ctrlKey: true, altKey: false, key: "z", shiftKey: false }), "undo");
assert.equal(menu.parseEditShortcut({ ctrlKey: true, altKey: false, key: "z", shiftKey: true }), "redo");
assert.equal(menu.parseEditShortcut({ ctrlKey: false, key: "z", shiftKey: false }), null);

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
  return menu.handleEditAction(action, game, makeMockBoard(), selection, status, errorModalStub(), session, makeRenderElement());
}

// ── hint: core picks a cell when deselected, targets the selected cell otherwise ──
{
  const { game, session } = await editGame();
  const status = statusStub();
  await runEdit("hint", game, session, { status }).done;
  assert.match(status.textContent, /takes [1-9]\./);
  await runEdit("hint", game, session, { status, selection: { getSelection: () => ({ row: 1, col: 2 }), select() {} } }).done;
  assert.match(status.textContent, /^C2 takes [1-9]\./);
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
  menu.wireEditMenu(
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
  assert.match(status.textContent, /^D3 takes [1-9]\./);
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

  menu.wireEditMenu(
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

assert.equal(menu.anyMenuOpen({ querySelectorAll: () => [] }), false);

// ── Copy sends exportPuzzle bytes as clipboard text ──
{
  const line = "003020600900305001001806400008102900700000008006708200002609500800203009005010300";
  let written = null;
  const session = {
    legend: { [menuBar.LEGEND_WIRE_COPY]: true },
    state: { cells: [{ value: 3, given: false, conflict: false }] },
  };
  const game = await withCoreFlow({
    exportPuzzle() {
      return { ok: true, bytes: new TextEncoder().encode(line) };
    },
  });
  const status = { textContent: "", className: "" };
  const errorModal = { el: { hidden: true }, msgEl: { textContent: "" } };
  const result = await menu.handleCopyPuzzle(game, session, status, errorModal, {
    clipboard: { writeText: async (text) => { written = text; } },
  });
  assert.equal(result.ok, true);
  assert.equal(written, line, "clipboard gets exportPuzzle one-line string");
  assert.equal(status.textContent, coreText.COPIED_MSG, "core owns the copy status");
  assert.equal(errorModal.el.hidden, true);
}

// ── Copy clipboard denied → error modal; board unchanged ──
{
  const session = {
    legend: { [menuBar.LEGEND_WIRE_COPY]: true },
    state: { cells: [{ value: 2, given: true, conflict: false }] },
  };
  const before = JSON.stringify(session.state);
  const errorModal = { el: { hidden: true }, msgEl: { textContent: "" } };
  const game = await withCoreFlow({
    exportPuzzle() {
      return { ok: true, bytes: new TextEncoder().encode("2".repeat(81)) };
    },
  });
  const result = await menu.handleCopyPuzzle(
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
  assert.equal(errorModal.msgEl.textContent, coreText.COPY_FAILED_MSG);
  assert.equal(JSON.stringify(session.state), before);
}

// ── Copy no-op when legend.copy is off ──
{
  let called = false;
  const session = { legend: {}, state: { cells: [] } };
  const result = await menu.handleCopyPuzzle(
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
  const session = { state: emptyState(), legend: { [menuBar.LEGEND_WIRE_COPY]: true } };
  let written = null;
  const lineBytes = new TextEncoder().encode("1".repeat(81));
  menu.wireEditMenu(
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

const clipboardWith = (text) => ({ readText: async () => text });

// ── Paste with the clipboard denied → error modal; board unchanged ──
{
  const { game, session } = await editGame();
  const before = JSON.stringify(game.getState());
  const errorModal = errorModalStub();
  const clipboard = { readText: async () => { throw new Error("denied"); } };
  await menu.handlePastePuzzle(game, session, statusStub(), errorModal, { clipboard }).done;
  assert.equal(errorModal.el.hidden, false);
  assert.match(errorModal.msgEl.textContent, /clipboard/i);
  assert.equal(JSON.stringify(game.getState()), before);
}

// ── Paste no-op when legend.paste is off ──
{
  let readCalled = false;
  const { game } = await editGame();
  const result = menu.handlePastePuzzle(game, { legend: {} }, statusStub(), errorModalStub(), {
    clipboard: { readText: async () => { readCalled = true; return GOLDEN_PUZZLE_LINE; } },
  });
  assert.equal(result.handled, false);
  assert.equal(readCalled, false);
}

// ── wireEditMenu Paste click redraws the board; with Auto Save on it writes the default file ──
{
  const pasteBtn = makeBtn();
  const { game, session } = await editGame({ auto_save: true });
  const boardEl = makeMockBoard();
  const host = hostFetch();
  const prevFetch = globalThis.fetch;
  globalThis.fetch = host.fetchFn;
  menu.wireEditMenu(
    makeBtn(),
    makeBtn(),
    makeBtn(),
    game,
    boardEl,
    { getSelection: () => null, deselect() {} },
    statusStub(),
    errorModalStub(),
    session,
    makeRenderElement(),
    { querySelectorAll: () => [], addEventListener() {} },
    { pasteBtn, clipboard: clipboardWith(GOLDEN_PUZZLE_LINE) },
  );
  pasteBtn.click();
  await settleFlow();
  globalThis.fetch = prevFetch;
  assert.equal(boardEl.children.length, 81, "board re-rendered after paste");
  assert.equal(session.state.cells[2].value, 3);
  assert.equal(postedCurrentFile(host.calls)?.init?.method, "POST");
}

console.log("menu.test.mjs OK");
