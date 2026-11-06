// play_pad.test.mjs — the pad shows core's legend and config and runs the same commands as the Edit and View menus.

import assert from "node:assert/strict";
import * as playPad from "./play_pad.js";
import * as board from "./board.js";
import * as menu from "./menus/menu.js";
import * as menuBar from "./menus/menu_bar.js";
import * as region from "./menus/region.js";
import * as webSteps from "./flows/web_steps.js";
import { FILL_MOVE, loadGame, promptDialogStub, settleFlow, startNewGame } from "./test_support.mjs";

function makeBtn() {
  const handlers = {};
  return {
    disabled: false,
    attrs: {},
    setAttribute(name, value) {
      this.attrs[name] = value;
    },
    classList: { toggle() {} },
    addEventListener(type, fn) {
      handlers[type] = fn;
    },
    click() {
      handlers.click?.({ stopPropagation() {} });
    },
  };
}

function makePadControls() {
  return {
    digits: [makeBtn(), makeBtn()],
    clear: makeBtn(),
    undo: makeBtn(),
    redo: makeBtn(),
    hint: makeBtn(),
    region: makeBtn(),
  };
}

// ── sync: digits follow the selection, Clear follows core's `clearable`, commands the legend, Region config ──
{
  const pad = makePadControls();
  playPad.syncPlayPad(pad, { undo: true, redo: false, hint: true }, { show_region: true }, null);
  assert.ok(pad.digits.every((key) => key.disabled), "digits are disabled without a selection");
  assert.equal(pad.clear.disabled, true, "Clear is disabled without a selection");
  assert.equal(pad.undo.disabled, false);
  assert.equal(pad.redo.disabled, true);
  assert.equal(pad.hint.disabled, false);
  assert.equal(pad.region.attrs["aria-pressed"], "true");

  playPad.syncPlayPad(pad, { undo: false, redo: true, hint: false }, { show_region: false }, { clearable: false });
  assert.ok(pad.digits.every((key) => !key.disabled), "digits are enabled with a selection");
  assert.equal(pad.clear.disabled, true, "Clear is disabled on a cell core says cannot be cleared");

  playPad.syncPlayPad(pad, { undo: false, redo: true, hint: false }, { show_region: false }, { clearable: true });
  assert.equal(pad.clear.disabled, false, "Clear is enabled on a cell core says can be cleared");
  assert.equal(pad.undo.disabled, true);
  assert.equal(pad.redo.disabled, false);
  assert.equal(pad.hint.disabled, true);
  assert.equal(pad.region.attrs["aria-pressed"], "false");
}

// ── wired to a real game: pad and menus run the same commands and always show the same state ──
{
  const game = await loadGame();
  startNewGame(game);
  const session = { state: game.getState(), legend: game.getLegend(), config: game.getConfig() };
  const status = { textContent: "", className: "" };
  const steps = webSteps.webSteps(game, session, { statusEl: status, promptDialog: promptDialogStub() });
  const boardEl = { children: [], replaceChildren() {} };
  const createElement = () => ({ dataset: {}, setAttribute() {}, classList: { add() {}, remove() {}, contains: () => false } });
  const selection = { getSelection: () => null, select() {}, deselect() {} };
  const menuControls = { undo: makeBtn(), redo: makeBtn(), hint: makeBtn(), viewRegion: makeBtn() };
  const pad = makePadControls();
  const cellAt = ({ row, col }) => session.state.cells[board.cellIndex(row, col)];
  const syncControls = () => {
    const sel = selection.getSelection();
    menuBar.syncMenuBar(session.legend, menuControls, session.config);
    playPad.syncPlayPad(pad, session.legend, session.config, sel ? cellAt(sel) : null);
  };
  const selectAndSync = (cell) => {
    selection.getSelection = () => cell;
    syncControls();
  };
  const givenCell = session.state.cells.findIndex((c) => c.given);
  selectAndSync({ row: Math.floor(givenCell / 9), col: givenCell % 9 });
  assert.equal(pad.clear.disabled, true, "Clear is disabled on a given");
  selectAndSync({ row: FILL_MOVE.row, col: FILL_MOVE.col });
  assert.equal(pad.clear.disabled, true, "Clear is disabled on an empty cell");
  selectAndSync(null);
  const root = { addEventListener() {}, querySelector: () => null };
  const editMenu = menu.wireEditMenu(menuControls.undo, menuControls.redo, null, game, boardEl, selection, session, createElement, root, {
    steps,
    syncLegend: syncControls,
  });
  const regionMenu = region.wireRegionMenu(menuControls, game, session, boardEl, () => null, { onChange: syncControls, steps });
  playPad.wirePlayPad(pad, { runEdit: editMenu.run, toggleRegion: regionMenu.toggle });

  await board.runBoardCommand(game, FILL_MOVE, { boardEl, selection, createElement, steps, onShown: syncControls });
  assert.equal(pad.undo.disabled, false, "a move enables Undo on the pad");
  assert.equal(menuControls.undo.disabled, pad.undo.disabled);
  assert.equal(pad.hint.disabled, false, "core's legend offers Hint");
  selectAndSync({ row: FILL_MOVE.row, col: FILL_MOVE.col });
  assert.equal(pad.clear.disabled, false, "Clear is enabled on a cell the player filled");
  selectAndSync(null);

  pad.undo.click();
  await settleFlow();
  assert.equal(session.state.cells[FILL_MOVE.row * 9 + FILL_MOVE.col].value, 0, "pad Undo takes the move back");
  assert.equal(pad.undo.disabled, true);
  assert.equal(pad.redo.disabled, false);
  assert.equal(menuControls.redo.disabled, pad.redo.disabled);

  pad.redo.click();
  await settleFlow();
  assert.equal(session.state.cells[FILL_MOVE.row * 9 + FILL_MOVE.col].value, FILL_MOVE.digit, "pad Redo replays the move");

  status.textContent = "";
  pad.hint.click();
  await settleFlow();
  assert.notEqual(status.textContent, "", "pad Hint runs core's hint, which shows its text");
  assert.equal(menuControls.hint.disabled, pad.hint.disabled);

  pad.region.click();
  await settleFlow();
  assert.equal(session.config.show_region, true);
  assert.equal(pad.region.attrs["aria-pressed"], "true");
  assert.equal(menuControls.viewRegion.attrs["aria-checked"], "true", "View menu shows the state the pad set");

  menuControls.viewRegion.click();
  await settleFlow();
  assert.equal(pad.region.attrs["aria-pressed"], "false", "the pad shows the state the View menu set");
  assert.equal(menuControls.viewRegion.attrs["aria-checked"], "false");
}

console.log("play_pad.test.mjs OK");
