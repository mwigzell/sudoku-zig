// region.test.mjs — View region highlight toggle contract.

import assert from "node:assert/strict";
import * as regionMod from "./region.js";
import * as webSteps from "../flows/web_steps.js";
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

/** Element factory `renderBoard` draws with: classes, dataset and text only. */
function createElement() {
  const set = new Set();
  return {
    dataset: {},
    textContent: "",
    classList: { add: (...names) => names.forEach((n) => set.add(n)), contains: (name) => set.has(name) },
    setAttribute() {},
    appendChild() {},
  };
}

/** A bare play grid: `renderBoard` replaces its children. */
function makePlayGrid() {
  return {
    children: [],
    classList: { contains: (name) => name === "board-play" },
    replaceChildren(...nodes) {
      this.children = nodes;
    },
  };
}

{
  const controls = { viewRegion: makeToggleBtn() };
  regionMod.syncRegionMenu(controls, { show_region: true });
  assert.equal(controls.viewRegion.attrs["aria-checked"], "true");
}

{
  const board = makePlayGrid();
  const game = await loadGame();
  assert.equal(game.exec({ action: "select", row: 1, col: 1 }).ok, true);
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
    {
      createElement,
      steps: webSteps.webSteps(game, session, {
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
  const shaded = board.children.filter((c) => c.classList.contains("region")).map((c) => `${c.dataset.row},${c.dataset.col}`);
  assert.equal(shaded.length, 21, "the board shades the region core returns around its selected cell");
  assert.ok(shaded.includes("1,1") && shaded.includes("8,1") && shaded.includes("1,8") && shaded.includes("2,2"));
  assert.equal(persistCalls.length, 1, "core asks to persist after the region toggle");
  assert.equal(persistCalls[0].show_region, true);
}

console.log("region.test.mjs OK");
