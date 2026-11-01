// region.test.mjs — View region highlight toggle contract.

import assert from "node:assert/strict";
import * as regionMod from "./region.js";
import * as boardMod from "../board.js";
import * as commandFlowMod from "../flows/command_flow.js";
import { loadGame, settleFlow } from "../test_support.mjs";

function makeToggleBtn() {
  return {
    className: "",
    attrs: {},
    classList: {
      _set: new Set(),
      toggle(name, on) {
        if (on) this._set.add(name);
        else this._set.delete(name);
      },
      contains(name) {
        return this._set.has(name);
      },
    },
    setAttribute(name, value) {
      this.attrs[name] = value;
    },
    addEventListener() {},
  };
}

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

{
  const controls = { viewRegion: makeToggleBtn() };
  regionMod.syncRegionMenu(controls, { show_region: true });
  assert.equal(controls.viewRegion.attrs["aria-checked"], "true");
}

{
  const region = boardMod.cellsInRegion(4, 4);
  assert.ok(region.has(4 * 9 + 4));
  assert.ok(!region.has(0));
}

{
  const cells = [];
  for (let row = 0; row < 9; row += 1) {
    for (let col = 0; col < 9; col += 1) cells.push(makeMockCell(row, col));
  }
  const board = { children: cells };
  const game = await loadGame();
  const session = { config: game.getConfig(), legend: game.getLegend(), state: game.getState() };
  const controls = {
    viewRegion: {
      ...makeToggleBtn(),
      addEventListener(_, fn) {
        this.click = fn;
      },
    },
  };
  const persistCalls = [];
  const menu = regionMod.wireRegionMenu(
    controls,
    game,
    session,
    board,
    () => ({ row: 1, col: 1 }),
    {
      commandFlow: commandFlowMod.commandHandlers(game, session, {
        fetchFn: async (url, init) => {
          persistCalls.push(JSON.parse(init.body));
          return { ok: true, status: 204 };
        },
      }),
    },
  );
  assert.equal(menu.isEnabled(), false);
  controls.viewRegion.click();
  await settleFlow();
  assert.equal(menu.isEnabled(), true);
  assert.ok(board.children.find((c) => c.dataset.row === "1" && c.dataset.col === "1").classList.contains("region"));
  assert.equal(persistCalls.length, 1, "core asks to persist after the region toggle");
  assert.equal(persistCalls[0].show_region, true);
}

console.log("region.test.mjs OK");
