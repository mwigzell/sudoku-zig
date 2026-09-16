// region.test.mjs — View region highlight toggle contract (#8).

import assert from "node:assert/strict";
import { syncRegionMenu, wireRegionMenu } from "./region.js";
import { applyRegionHighlight, cellsInRegion } from "./board.js";

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
  syncRegionMenu(controls, { show_region: true });
  assert.equal(controls.viewRegion.attrs["aria-checked"], "true");
}

{
  const region = cellsInRegion(4, 4);
  assert.ok(region.has(4 * 9 + 4));
  assert.ok(!region.has(0));
}

{
  const cells = [];
  for (let row = 0; row < 9; row += 1) {
    for (let col = 0; col < 9; col += 1) cells.push(makeMockCell(row, col));
  }
  const board = { children: cells };
  const session = {
    config: { theme: "dark", show_region: false },
  };
  const game = {
    exec(action) {
      if (action.action === "set_region") {
        session.config = { ...session.config, show_region: action.enabled };
        return { ok: true };
      }
      return { ok: false };
    },
    getConfig() {
      return session.config;
    },
  };
  const controls = {
    viewRegion: {
      ...makeToggleBtn(),
      addEventListener(_, fn) {
        this.click = fn;
      },
    },
  };
  const menu = wireRegionMenu(
    controls,
    game,
    session,
    board,
    () => ({ row: 1, col: 1 }),
  );
  assert.equal(menu.isEnabled(), false);
  controls.viewRegion.click();
  assert.equal(menu.isEnabled(), true);
  assert.ok(board.children.find((c) => c.dataset.row === "1" && c.dataset.col === "1").classList.contains("region"));
}

console.log("region.test.mjs OK");
