// hint_flow.test.mjs — web seam: new game → C1 Hint → C2 Hint (real wasm + selection DOM).

import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import assert from "node:assert/strict";
import { loadArtifact } from "./artifacts/glue.js";
import { handleEditAction } from "./menu.js";
import { findCellElement, renderBoard, wireSelection } from "./board.js";

const here = dirname(fileURLToPath(import.meta.url));
const wasmBytes = readFileSync(join(here, "artifacts/artifact.wasm"));

function makeMockCell(row, col) {
  return {
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
    _docListeners: {},
    classList: {
      _set: new Set(["board-play"]),
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
      contains(name) {
        return this._set.has(name);
      },
    },
    querySelector(sel) {
      return sel === ".board-play" ? play : null;
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

function makeRenderElement() {
  return (tag) => {
    const el = {
      tag,
      className: "",
      textContent: "",
      dataset: {},
      attrs: {},
      setAttribute(name, value) {
        el.attrs[name] = value;
      },
      classList: {
        _set: new Set(),
        add(...names) {
          names.forEach((n) => this._set.add(n));
          el.className = [...this._set].join(" ");
        },
        remove(...names) {
          names.forEach((n) => this._set.delete(n));
          el.className = [...this._set].join(" ");
        },
        contains(name) {
          return this._set.has(name);
        },
      },
    };
    return el;
  };
}

function clickCell(board, row, col) {
  const cell = findCellElement(board.play, row, col);
  const event = { target: { closest: () => cell } };
  board.play._listeners.pointerdown?.(event);
  board.play._listeners.click?.(event);
}

function runHint(game, board, selection, session, status) {
  const outcome = handleEditAction(
    "hint",
    game,
    board,
    selection,
    status,
    { el: { hidden: true }, msgEl: { textContent: "" } },
    session,
    makeRenderElement(),
  );
  assert.equal(outcome.handled, true);
}

{
  const game = await loadArtifact(wasmBytes);
  assert.equal(game.init({ difficulty: 1, logLevel: 1 }).ok, true);

  const board = makeMockBoard();
  renderBoard(board, game.getState(), makeRenderElement());
  const session = {
    state: game.getState(),
    legend: game.getLegend(),
  };
  const status = { textContent: "new game started", className: "" };
  const selection = wireSelection(board);

  clickCell(board, 0, 2);
  assert.deepEqual(selection.getSelection(), { row: 0, col: 2 });
  runHint(game, board, selection, session, status);
  assert.match(status.textContent, /C1 takes [1-9] \(placement\)/);
  const msgC1 = status.textContent;

  clickCell(board, 1, 2);
  assert.deepEqual(selection.getSelection(), { row: 1, col: 2 });
  runHint(game, board, selection, session, status);
  assert.match(status.textContent, /C2 takes [1-9] \(placement\)/);
  assert.notEqual(status.textContent, msgC1);
}

{
  const game = await loadArtifact(wasmBytes);
  assert.equal(game.init({ difficulty: 1, logLevel: 1 }).ok, true);

  const board = makeMockBoard();
  renderBoard(board, game.getState(), makeRenderElement());
  const session = {
    state: game.getState(),
    legend: game.getLegend(),
  };
  const modal = { el: { hidden: true }, msgEl: { textContent: "" } };
  const status = { textContent: "", className: "" };
  const selection = wireSelection(board);

  const deadFill = game.exec({ action: "fill", row: 1, col: 1, digit: 8 });
  assert.equal(deadFill.ok, true);
  session.state = deadFill.state;

  runHint(game, board, selection, session, status);
  assert.match(status.textContent, /\(no-solution\)/);
  assert.equal(modal.el.hidden, true);
}

console.log("hint_flow.test.mjs OK");
