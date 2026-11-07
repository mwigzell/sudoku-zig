// board.test.mjs — DOM board shell contract.

import assert from "node:assert/strict";
import * as boardMod from "./board.js";
import * as webSteps from "./flows/web_steps.js";
import { hostFetch, loadGame, postedCurrentFile, promptDialogStub, settleFlow, startNewGame, coreText, fillText } from "./test_support.mjs";



assert.equal(boardMod.cellIndex(2, 4), 22);
assert.equal(boardMod.cellIndex(0, 0), 0);
assert.equal(boardMod.cellIndex(8, 8), 80);

{
  const given = { value: 7, given: true, conflict: false };
  const classes = boardMod.cellClasses(0, 0, given);
  assert.ok(classes.includes("cell"));
  assert.ok(classes.includes("given"));
  assert.ok(!classes.includes("conflict"));
  assert.ok(!classes.includes("player"));
}

{
  const conflict = { value: 3, given: false, conflict: true };
  const classes = boardMod.cellClasses(1, 1, conflict);
  assert.ok(classes.includes("conflict"));
  assert.ok(classes.includes("player"));
}

{
  const classes = boardMod.cellClasses(2, 5, { value: 0, given: false, conflict: false });
  assert.ok(classes.includes("empty"));
  assert.ok(classes.includes("box-right"));
  assert.ok(classes.includes("box-bottom"));
}

assert.equal(boardMod.formatDigit({ value: 0 }), "");
assert.equal(boardMod.formatDigit({ value: 9 }), "9");

{
  const state = {
    cells: [
      { value: 5, given: true, conflict: false },
      { value: 0, given: false, conflict: false },
    ].concat(Array(79).fill({ value: 0, given: false, conflict: false })),
  };
  const desc = boardMod.boardCellDescriptors(state);
  assert.equal(desc.length, 81);
  assert.equal(desc[0].text, "5");
  assert.ok(desc[0].classes.includes("given"));
  assert.equal(desc[1].text, "");
  assert.ok(desc[1].classes.includes("empty"));
}

// ── framed board ──

assert.equal(boardMod.FRAME_SIZE, 11);
assert.equal(boardMod.PLAY_OFFSET, 1);
assert.equal(boardMod.GUTTER_FR, 1);
assert.equal(boardMod.PLAY_FR, 2);
assert.equal(boardMod.COLUMN_LETTERS, "ABCDEFGHI");

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
  const playEl = boardMod.ensureBoardFrame(frameEl, createElement);
  assert.ok(frameEl.classList.contains("board-frame"));
  assert.ok(playEl.classList.contains("board-play"));
  assert.equal(boardMod.getPlayGrid(frameEl), playEl);

  const colLabels = frameEl._children.filter((c) => c.classList.contains("col-label"));
  assert.equal(colLabels.length, 18);
  assert.deepEqual(
    colLabels.map((c) => c.textContent),
    [...boardMod.COLUMN_LETTERS, ...boardMod.COLUMN_LETTERS],
  );

  const rowLabels = frameEl._children.filter((c) => c.classList.contains("row-label"));
  assert.equal(rowLabels.length, 18);
  assert.deepEqual(
    rowLabels.map((c) => c.textContent),
    ["1", "1", "2", "2", "3", "3", "4", "4", "5", "5", "6", "6", "7", "7", "8", "8", "9", "9"],
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
  assert.ok(colLabels.some((c) => c.style.gridRow === "1"), "column labels in top gutter");
  assert.ok(colLabels.some((c) => c.style.gridRow === "11"), "column labels in bottom gutter");
  assert.ok(rowLabels.some((c) => c.style.gridColumn === "1"), "row labels in left gutter");
  assert.ok(rowLabels.some((c) => c.style.gridColumn === "11"), "row labels in right gutter");
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
  boardMod.renderBoard(frameEl, state, createElement);
  const playEl = boardMod.getPlayGrid(frameEl);
  assert.equal(playEl._children.length, 81);
  assert.equal(playEl._children[0].textContent, "1");
  assert.ok(playEl._children[0].classList.contains("given"));
  assert.ok(playEl._children[0].classList.contains("cell"));
}

// ── marks: drawn in nine fixed slots, only in an empty cell and only when core says they are visible ──
{
  assert.deepEqual(boardMod.markDigits(0), []);
  assert.deepEqual(boardMod.markDigits(0b1_0000_0101), [1, 3, 9]);

  const cells = Array.from({ length: 81 }, () => ({ value: 0, given: false, conflict: false, marks: 0 }));
  cells[1] = { value: 0, given: false, conflict: false, marks: 0b1_0000_0101 };
  cells[2] = { value: 6, given: false, conflict: false, marks: 0b10 };
  const render = (marksVisible) => {
    const frameEl = makeFrameElement();
    boardMod.renderBoard(frameEl, { cells, marks_visible: marksVisible }, makeRenderElement());
    return boardMod.getPlayGrid(frameEl)._children;
  };

  const shown = render(true);
  const grid = shown[1]._children[0];
  assert.ok(grid.classList.contains("marks"));
  assert.deepEqual(grid._children.map((slot) => slot.textContent), ["1", "", "3", "", "", "", "", "", "9"]);
  assert.equal(shown[0]._children.length, 0, "a cell with no marks is blank");
  assert.equal(shown[2]._children.length, 0, "a filled cell shows only its digit");
  assert.equal(shown[2].textContent, "6");

  assert.equal(render(false)[1]._children.length, 0, "hidden marks are not drawn");
}

{
  const el = { textContent: "", className: "", classList: { add() {}, remove() {} } };
  boardMod.setStatus(el, "Ready");
  assert.equal(el.textContent, "Ready");
  assert.equal(el.className, "");
  boardMod.setStatus(el, "bad move", { error: true });
  assert.equal(el.textContent, "bad move");
  assert.equal(el.className, "error");
  boardMod.setStatus(el, "ok again");
  assert.equal(el.className, "");
}

// ── selection ──

assert.deepEqual(boardMod.moveSelection(4, 4, "ArrowUp"), { row: 3, col: 4 });
assert.deepEqual(boardMod.moveSelection(0, 0, "ArrowUp"), { row: 0, col: 0 });
assert.deepEqual(boardMod.moveSelection(8, 8, "ArrowDown"), { row: 8, col: 8 });
assert.deepEqual(boardMod.moveSelection(2, 5, "ArrowLeft"), { row: 2, col: 4 });
assert.deepEqual(boardMod.moveSelection(2, 8, "ArrowRight"), { row: 2, col: 8 });

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
    contains(node) {
      return this.children.includes(node);
    },
    querySelector(sel) {
      if (sel !== ".selected[data-row][data-col]") return null;
      return cells.find((c) => c.classList.contains("selected")) ?? null;
    },
    replaceChildren(...nodes) {
      this.children.length = 0;
      this.children.push(...nodes);
    },
    _docListeners: {},
    ownerDocument: null,
  };
  play.ownerDocument = {
    addEventListener(type, fn) {
      play._docListeners[type] = fn;
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

/** The rendered cell at (row, col) on a mock board. */
function cellAt(board, row, col) {
  return board.play.children.find((c) => Number(c.dataset.row) === row && Number(c.dataset.col) === col);
}

/** Cells drawn with `name` on a mock board, as "row,col". */
function cellsWith(board, name) {
  return board.play.children.filter((c) => c.classList.contains(name)).map((c) => `${c.dataset.row},${c.dataset.col}`);
}

{
  const board = makeMockBoard();
  const state = { cells: Array.from({ length: 81 }, () => ({ value: 0, given: false, conflict: false, marks: 0 })), selected: { row: 1, col: 2 }, region: [0, 1, 11] };
  boardMod.renderBoard(board, state, makeRenderElement());
  assert.deepEqual(cellsWith(board, "selected"), ["1,2"], "the selected cell comes from core's snapshot");
  assert.deepEqual(cellsWith(board, "region"), ["0,0", "0,1", "1,2"], "the region is the cells core lists");
  boardMod.renderBoard(board, { ...state, selected: null, region: null }, makeRenderElement());
  assert.deepEqual(cellsWith(board, "selected"), []);
  assert.deepEqual(cellsWith(board, "region"), []);
}

{
  const { handleEditAction } = await import("./menus/menu.js");
  const game = await loadGame();
  startNewGame(game);
  const session = { state: game.getState(), legend: game.getLegend() };
  const board = makeMockBoard();
  const status = { textContent: "", className: "" };
  const outcome = handleEditAction(
    "hint",
    game,
    board,
    { getSelection: () => ({ row: 1, col: 2 }), select() {} },
    session,
    makeRenderElement(),
    { steps: webSteps.webSteps(game, session, { statusEl: status }) },
  );
  await outcome.done;
  assert.match(status.textContent, /^C2 /, "hint targets the selected cell");
}

// ── play loop ──

assert.deepEqual(boardMod.parsePlayKey("5"), { type: "fill", digit: 5 });
assert.equal(boardMod.parsePlayKey("ArrowUp"), null);
assert.deepEqual(boardMod.parsePlayKey("Backspace"), { type: "clear" });
assert.deepEqual(boardMod.parsePlayKey(" "), { type: "clear" });
assert.deepEqual(boardMod.parsePlayKey("", "Space"), { type: "clear" });
assert.deepEqual(boardMod.parsePlayKey("", "Backspace"), { type: "clear" });
assert.deepEqual(boardMod.parsePlayKey("", "Delete"), { type: "clear" });

const statusStub = () => ({ textContent: "", className: "" });

async function playGame(config = {}) {
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

function selectedAt(board, row, col) {
  return { getSelection: () => ({ row, col }), select() {} };
}

{
  const { game, session } = await playGame({ show_region: true });
  const board = makeMockBoard();
  const createElement = makeRenderElement();
  boardMod.renderBoard(board, session.state, createElement);
  const steps = webSteps.webSteps(game, session, { statusEl: statusStub() });
  let selects = 0;
  const controller = boardMod.wireSelection(board, { game, session, steps, createElement, onSelect: () => (selects += 1) });
  assert.equal(board.tabIndex, 0);
  assert.equal(controller.getSelection(), null);

  board.play._docListeners.keydown?.({ key: "ArrowRight", preventDefault() {}, target: board.play });
  await settleFlow();
  assert.equal(controller.getSelection(), null, "an arrow with nothing selected does nothing");

  const clickCell = (row, col, pressRow = row, pressCol = col) => {
    board.play._listeners.pointerdown?.({ target: { closest: () => cellAt(board, pressRow, pressCol) } });
    board.play._listeners.click({ target: { closest: () => cellAt(board, row, col) } });
    return settleFlow();
  };
  await clickCell(5, 5);
  assert.deepEqual(controller.getSelection(), { row: 5, col: 5 }, "a tap selects in core");
  assert.deepEqual(session.state.selected, { row: 5, col: 5 });
  assert.deepEqual(cellsWith(board, "selected"), ["5,5"]);
  assert.equal(cellsWith(board, "region").length, 21, "Show Region shades core's row, column and box");

  await clickCell(5, 5);
  assert.equal(controller.getSelection(), null, "tapping the selected cell again deselects");
  assert.deepEqual(cellsWith(board, "selected"), []);
  assert.deepEqual(cellsWith(board, "region"), []);

  await clickCell(1, 2, 0, 2);
  assert.deepEqual(controller.getSelection(), { row: 1, col: 2 }, "a click whose press began elsewhere selects");

  await controller.select(0, 0);
  board.play._docListeners.keydown?.({ key: "ArrowRight", preventDefault() {}, target: board.play });
  await settleFlow();
  assert.deepEqual(controller.getSelection(), { row: 0, col: 1 }, "an arrow moves core's selection");

  await controller.deselect();
  assert.equal(controller.getSelection(), null);
  assert.equal(selects, 6, "every select and deselect reports once the board is redrawn");
}

{
  const board = makeMockBoard();
  const status = statusStub();
  const { game, session } = await playGame();
  const outcome = boardMod.handlePlayKey(game, board, selectedAt(board, 0, 2), "4", makeRenderElement(), "", { steps: webSteps.webSteps(game, session, { statusEl: status, promptDialog: promptDialogStub() }) });
  assert.equal(outcome.handled, true);
  await outcome.done;
  assert.equal(session.state.cells[boardMod.cellIndex(0, 2)].value, 4);
  assert.equal(cellAt(board, 0, 2).textContent, "4");
  assert.ok(cellAt(board, 0, 2).classList.contains("selected"), "a fill selects its cell in core");
  assert.equal(session.legend.undo, true);
}

{
  const board = makeMockBoard();
  const status = statusStub();
  const prompts = promptDialogStub();
  const { game, session } = await playGame();
  status.textContent = "before";
  const outcome = boardMod.handlePlayKey(game, board, selectedAt(board, 0, 0), "5", makeRenderElement(), "", { steps: webSteps.webSteps(game, session, { statusEl: status, promptDialog: prompts }) });
  assert.equal(outcome.handled, true);
  await outcome.done;
  assert.equal(status.textContent, "before");
  assert.match(prompts.lastText, /puzzle/i);
  assert.equal(prompts.shown.length, 1);
}

{
  const { game, session } = await playGame();
  const outcome = boardMod.handlePlayKey(
    game,
    makeMockBoard(),
    { getSelection: () => null, select() {} },
    "5",
    makeRenderElement(),
    "",
    { steps: webSteps.webSteps(game, session) },
  );
  assert.equal(outcome.handled, false);
}

{
  const board = makeMockBoard();
  const prompts = promptDialogStub();
  const { game, session } = await playGame({ auto_save: true });
  const host = hostFetch({ exists: false });
  const prevFetch = globalThis.fetch;
  globalThis.fetch = host.fetchFn;
  const outcome = boardMod.handlePlayKey(game, board, selectedAt(board, 0, 2), "4", makeRenderElement(), "", { steps: webSteps.webSteps(game, session, { statusEl: statusStub(), promptDialog: prompts }) });
  await outcome.done;
  globalThis.fetch = prevFetch;
  assert.equal(postedCurrentFile(host.calls)?.init?.method, "POST", "first autosave with nothing on disk writes the host file");
  assert.equal(prompts.shown.length, 0);
}

{
  const board = makeMockBoard();
  const prompts = promptDialogStub();
  const { game, session } = await playGame({ auto_save: true });
  const host = hostFetch({ exists: true });
  const prevFetch = globalThis.fetch;
  globalThis.fetch = host.fetchFn;
  const outcome = boardMod.handlePlayKey(game, board, selectedAt(board, 0, 2), "4", makeRenderElement(), "", { steps: webSteps.webSteps(game, session, { statusEl: statusStub(), promptDialog: prompts }) });
  await outcome.done;
  globalThis.fetch = prevFetch;
  assert.equal(prompts.shown.length, 1, "detached autosave onto an existing file asks once, and declining is not an error");
  const [question] = prompts.shown;
  assert.equal(question.type, "warning");
  assert.equal(question.title, coreText.REPLACE_CONFIRM_TITLE);
  assert.equal(question.text, fillText(coreText.REPLACE_CONFIRM_FMT, "sudoku.sud"));
  assert.deepEqual(question.buttons, [coreText.REPLACE_CONFIRM_CANCEL_LABEL, coreText.REPLACE_CONFIRM_OK_LABEL]);
  assert.equal(postedCurrentFile(host.calls), undefined, "declined question writes nothing");
}

{
  const board = makeMockBoard();
  const { game, session } = await playGame();
  const digitBtnHandlers = {};
  const pad = {
    querySelectorAll(selector) {
      if (selector !== "[data-play-key]") return [];
      return [
        {
          dataset: { playKey: "4", playCode: "" },
          addEventListener(type, fn) {
            digitBtnHandlers[type] = fn;
          },
        },
      ];
    },
  };
  let shownLegend = null;
  boardMod.wirePlayLoop(board, game, selectedAt(board, 0, 2), session, {
    steps: webSteps.webSteps(game, session, { statusEl: statusStub(), promptDialog: promptDialogStub() }),
    playPadEl: pad,
    createElement: makeRenderElement(),
    onLegendChange: (legend) => {
      shownLegend = legend;
    },
  });
  digitBtnHandlers.click?.();
  await settleFlow();
  assert.equal(game.getState().cells[boardMod.cellIndex(0, 2)].value, 4);
  assert.equal(shownLegend?.undo, true);
}

console.log("board.test.mjs OK");
