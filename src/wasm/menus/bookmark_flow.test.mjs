// bookmark_flow.test.mjs — web seam: Edit → Set Bookmark / Rewind to Bookmark against real wasm.
// The bookmark rides the save file, so a reopen brings Rewind back without re-pinning.

import assert from "node:assert/strict";
import * as menu from "./menu.js";
import * as webSteps from "../flows/web_steps.js";
import * as stepRunner from "../flows/step_runner.js";
import { coreText, fillText, loadGame, openAs, startNewGame } from "../test_support.mjs";

function makeMockBoard() {
  return {
    children: [],
    replaceChildren(...nodes) {
      this.children.length = 0;
      this.children.push(...nodes);
    },
  };
}

function makeRenderElement() {
  return (tag) => {
    const el = { tag, className: "", textContent: "", dataset: {}, attrs: {}, children: [] };
    el.setAttribute = (name, value) => {
      el.attrs[name] = value;
    };
    el.appendChild = (child) => {
      el.children.push(child);
    };
    el.classList = {
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
    };
    return el;
  };
}

/** A started game and the session the page keeps for it; menu actions and moves run through core's flow. */
async function bookmarkGame() {
  const game = await loadGame();
  startNewGame(game);
  const status = { textContent: coreText.NEW_GAME_STARTED_MSG, className: "" };
  const session = {
    state: game.getState(),
    legend: game.getLegend(),
    config: game.getConfig(),
    default_save_filename: "sudoku.sud",
  };
  const steps = webSteps.webSteps(game, session, { statusEl: status });
  const boardEl = makeMockBoard();
  const selection = { getSelection: () => null, select() {} };
  return {
    game,
    session,
    status,
    boardEl,
    selection,
    /** One Edit menu activation, exactly as the wired item runs it. */
    runMenu: (action) =>
      menu.handleEditAction(action, game, boardEl, selection, session, makeRenderElement(), { steps }),
    /** One player move through the core command flow. */
    move: (action) => stepRunner.runCommand(game, action, steps),
  };
}

{
  const { game, session, status, runMenu, move } = await bookmarkGame();

  // ── no bookmark: Rewind is greyed, and a rewind that is not offered changes and says nothing ──
  assert.equal(session.legend.rewind, false, "no bookmark means Rewind is not offered");
  const atStart = JSON.stringify(session.state.cells);
  status.textContent = "keep";
  assert.equal(runMenu("rewind").handled, false);
  assert.equal(status.textContent, "keep", "a rewind that is not offered reports nothing");
  assert.equal(JSON.stringify(session.state.cells), atStart);

  // ── any position, move 0 included, can be pinned; core names the move ──
  assert.equal((await runMenu("bookmark").done).kind, stepRunner.STEP_DONE);
  assert.equal(status.textContent, fillText(coreText.BOOKMARK_SET_FMT, 0));
  const atBookmark = JSON.stringify(session.state.cells);
  assert.equal(session.legend.rewind, false, "a bookmark at the pointer leaves nothing to rewind to");
  status.textContent = "keep";
  assert.equal(runMenu("rewind").handled, false);
  assert.equal(status.textContent, "keep");
  assert.equal(JSON.stringify(session.state.cells), atBookmark);

  // ── a fill and a pencil mark put the bookmark behind the pointer ──
  assert.equal((await move({ action: "fill", row: 0, col: 2, digit: 4 })).kind, stepRunner.STEP_DONE);
  await move({ action: "toggle_pencil_mode" });
  await move({ action: "fill", row: 0, col: 3, digit: 6 });
  assert.notEqual(session.state.cells[3].marks, 0, "the pinned board draws pencil marks");
  assert.equal(session.legend.rewind, true);

  // ── save and reopen: the file's bookmark becomes the live one, with no re-pinning ──
  const saved = game.toSaveFormat();
  assert.equal(saved.ok, true);
  openAs(game, "bookmark.sud");
  session.state = game.getState();
  session.legend = game.getLegend();
  assert.equal(session.legend.rewind, true, "the reopened game offers Rewind without a new bookmark");

  // ── Rewind returns to the bookmarked move in one step, board and marks included ──
  const rewound = runMenu("rewind");
  assert.equal(rewound.handled, true);
  await rewound.done;
  assert.equal(status.textContent, fillText(coreText.REWOUND_FMT, 0));
  assert.equal(JSON.stringify(session.state.cells), atBookmark);
  assert.equal(session.legend.rewind, false);
  assert.equal(session.legend.redo, true);

  // ── Redo still replays the undone moves one at a time ──
  assert.equal((await move({ action: "redo" })).kind, stepRunner.STEP_DONE);
  assert.equal(session.state.cells[2].value, 4);
  assert.equal(session.state.cells[3].marks, 0, "only the first undone move is back");
  assert.equal(session.legend.redo, true);
  assert.equal(session.legend.rewind, true);

  // ── Bookmarking again moves the bookmark; a new move after it leaves it usable ──
  await runMenu("bookmark").done;
  assert.equal(status.textContent, fillText(coreText.BOOKMARK_SET_FMT, 1));
  assert.equal(session.legend.rewind, false);
  await move({ action: "fill", row: 0, col: 6, digit: 6 });
  assert.equal(session.legend.rewind, true, "the bookmark stays usable after a new move");
}

console.log("bookmark_flow.test.mjs OK");
