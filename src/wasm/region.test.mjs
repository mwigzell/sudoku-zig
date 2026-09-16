// region.test.mjs — View region highlight toggle contract (#8).

import assert from "node:assert/strict";
import {
  readRegionEnabled,
  writeRegionEnabled,
  syncRegionMenu,
  wireRegionMenu,
  REGION_STORAGE_KEY,
} from "./region.js";
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
  const storage = new Map([[REGION_STORAGE_KEY, "true"]]);
  assert.equal(readRegionEnabled({ getItem: (k) => storage.get(k) ?? null }), true);
  writeRegionEnabled(false, {
    setItem(k, v) {
      storage.set(k, v);
    },
  });
  assert.equal(storage.get(REGION_STORAGE_KEY), "false");
}

{
  const controls = { viewRegion: makeToggleBtn() };
  syncRegionMenu(controls, true);
  assert.equal(controls.viewRegion.attrs["aria-checked"], "true");
  assert.ok(controls.viewRegion.classList.contains("selected"));
}

{
  const cells = [];
  for (let row = 0; row < 9; row += 1) {
    for (let col = 0; col < 9; col += 1) cells.push(makeMockCell(row, col));
  }
  const board = { children: cells };
  const region = cellsInRegion(4, 4);
  assert.ok(region.has(4 * 9 + 4));
  assert.ok(region.has(0 * 9 + 4));
  assert.ok(region.has(4 * 9 + 0));
  assert.ok(region.has(3 * 9 + 3));
  assert.ok(!region.has(0));

  applyRegionHighlight(board, 4, 4, true);
  assert.equal(board.children.filter((c) => c.classList.contains("region")).length, 21);
  applyRegionHighlight(board, 4, 4, false);
  assert.equal(board.children.filter((c) => c.classList.contains("region")).length, 0);
}

{
  const cells = [];
  for (let row = 0; row < 9; row += 1) {
    for (let col = 0; col < 9; col += 1) cells.push(makeMockCell(row, col));
  }
  const board = { children: cells };
  const controls = {
    viewRegion: {
      ...makeToggleBtn(),
      addEventListener(_, fn) {
        this.click = fn;
      },
    },
  };
  const storage = new Map();
  const menu = wireRegionMenu(controls, () => ({ row: 1, col: 1 }), board, {
    storage: {
      getItem: (k) => storage.get(k) ?? null,
      setItem: (k, v) => storage.set(k, v),
    },
  });
  assert.equal(menu.isEnabled(), false);
  controls.viewRegion.click();
  assert.equal(menu.isEnabled(), true);
  assert.equal(storage.get(REGION_STORAGE_KEY), "true");
  assert.ok(findCell(board, 1, 1).classList.contains("region"));
  assert.ok(findCell(board, 1, 0).classList.contains("region"));
  assert.ok(!findCell(board, 8, 8).classList.contains("region"));
}

function findCell(board, row, col) {
  return board.children.find((c) => Number(c.dataset.row) === row && Number(c.dataset.col) === col);
}

console.log("region.test.mjs OK");
