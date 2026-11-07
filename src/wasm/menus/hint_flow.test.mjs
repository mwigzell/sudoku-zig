// hint_flow.test.mjs — web seam: new game → select C1, Hint → select C2, Hint (real wasm; Hint targets core's selection).

import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import assert from "node:assert/strict";
import * as glue from "../artifacts/glue.js";
import * as menu from "./menu.js";
import * as boardMod from "../board.js";
import * as webSteps from "../flows/web_steps.js";
import { coreText } from "../test_support.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const wasmBytes = readFileSync(join(here, "../artifacts/artifact.wasm"));

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

async function runHint(game, board, selection, session, status) {
  const outcome = menu.handleEditAction(
    "hint",
    game,
    board,
    selection,
    session,
    makeRenderElement(),
    { steps: webSteps.webSteps(game, session, { statusEl: status }) },
  );
  assert.equal(outcome.handled, true);
  await outcome.done;
}

{
  const game = await glue.loadArtifact(wasmBytes);
  assert.equal(game.init({ difficulty: 1, logLevel: 1 }).ok, true);

  const board = makeMockBoard();
  boardMod.renderBoard(board, game.getState(), makeRenderElement());
  const session = {
    state: game.getState(),
    legend: game.getLegend(),
  };
  const status = { textContent: coreText.NEW_GAME_STARTED_MSG, className: "" };
  const steps = webSteps.webSteps(game, session, { statusEl: status });
  const selection = boardMod.wireSelection(board, { game, session, steps, createElement: makeRenderElement() });

  await selection.select(0, 2);
  assert.deepEqual(selection.getSelection(), { row: 0, col: 2 });
  await runHint(game, board, selection, session, status);
  assert.match(status.textContent, /C1 takes [1-9]\./);
  const msgC1 = status.textContent;

  await selection.select(1, 2);
  assert.deepEqual(selection.getSelection(), { row: 1, col: 2 });
  await runHint(game, board, selection, session, status);
  assert.match(status.textContent, /C2 takes [1-9]\./);
  assert.notEqual(status.textContent, msgC1);
}

{
  const game = await glue.loadArtifact(wasmBytes);
  assert.equal(game.init({ difficulty: 1, logLevel: 1 }).ok, true);

  const board = makeMockBoard();
  boardMod.renderBoard(board, game.getState(), makeRenderElement());
  const session = {
    state: game.getState(),
    legend: game.getLegend(),
  };
  const modal = { el: { hidden: true }, msgEl: { textContent: "" } };
  const status = { textContent: "", className: "" };
  const steps = webSteps.webSteps(game, session, { statusEl: status });
  const selection = boardMod.wireSelection(board, { game, session, steps, createElement: makeRenderElement() });

  const deadFill = game.exec({ action: "fill", row: 1, col: 1, digit: 8 });
  assert.equal(deadFill.ok, true);
  session.state = deadFill.state;

  await runHint(game, board, selection, session, status);
  assert.match(status.textContent, /no solution/i);
  assert.equal(modal.el.hidden, true);
}

console.log("hint_flow.test.mjs OK");
