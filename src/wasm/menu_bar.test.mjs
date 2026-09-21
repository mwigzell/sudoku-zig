// menu_bar.test.mjs — menu bar legend sync contract.

import assert from "node:assert/strict";
import { syncMenuBar, wireMenuBar, wireMenuDropdowns, collectMenuBarControls, MENU_BAR_MENUS } from "./menu_bar.js";

function makeBtn() {
  return { disabled: false };
}

function makeControls() {
  return {
    new: makeBtn(),
    open: makeBtn(),
    save: makeBtn(),
    saveAs: makeBtn(),
    undo: makeBtn(),
    redo: makeBtn(),
    solve: makeBtn(),
    viewLight: makeBtn(),
    viewDark: makeBtn(),
    viewRegion: makeBtn(),
    about: makeBtn(),
  };
}

// ── File + Edit items follow legend flags ──
{
  const controls = makeControls();
  syncMenuBar(
    {
      new: true,
      open: false,
      save: true,
      save_as: false,
      undo: true,
      redo: false,
    },
    controls,
  );
  assert.equal(controls.new.disabled, false);
  assert.equal(controls.open.disabled, true);
  assert.equal(controls.save.disabled, false);
  assert.equal(controls.saveAs.disabled, true);
  assert.equal(controls.undo.disabled, false);
  assert.equal(controls.redo.disabled, true);
  assert.equal(controls.solve.disabled, true);
}

{
  const controls = makeControls();
  syncMenuBar(
    { new: true, open: true, save: true, save_as: true, undo: false, redo: false, solve: true },
    controls,
  );
  assert.equal(controls.solve.disabled, false);
}

// ── View + Help stay enabled (no legend flags) ──
{
  const controls = makeControls();
  controls.viewLight.disabled = true;
  controls.viewDark.disabled = true;
  controls.viewRegion.disabled = true;
  controls.about.disabled = true;
  syncMenuBar({ new: false, open: false, save: false, save_as: false, undo: false, redo: false }, controls);
  assert.equal(controls.viewLight.disabled, false);
  assert.equal(controls.viewDark.disabled, false);
  assert.equal(controls.about.disabled, false);
}

// ── no Quit on web ──
{
  const labels = MENU_BAR_MENUS.flatMap((menu) => menu.items.map((item) => item.label));
  assert.ok(!labels.some((label) => /quit/i.test(label)));
}

// ── wireMenuBar syncs from session legend on init ──
{
  const controls = makeControls();
  const session = {
    legend: { new: true, open: true, save: true, save_as: true, undo: false, redo: false },
  };
  wireMenuBar(controls, session);
  assert.equal(controls.undo.disabled, true);
  assert.equal(controls.redo.disabled, true);
  assert.equal(controls.new.disabled, false);
}

// ── collectMenuBarControls resolves menu buttons ──
{
  const root = {
    querySelector(id) {
      return { id, disabled: false };
    },
  };
  const controls = collectMenuBarControls(root);
  assert.equal(controls.new.id, "#file-new");
  assert.equal(controls.undo.id, "#edit-undo");
  assert.equal(controls.about.id, "#help-about");
}

// ── dropdown panels hidden until menu opened ──
{
  const panels = [];
  const triggers = [];
  const root = {
    querySelectorAll(selector) {
      if (selector !== "#menu-bar .menu") return [];
      return [
        {
          dataset: { open: "false" },
          querySelector(sel) {
            if (sel === ".menu-panel") return panels[0];
            if (sel === ".menu-trigger") return triggers[0];
            return null;
          },
        },
      ];
    },
    addEventListener() {},
  };
  const panel = { _hidden: false };
  Object.defineProperty(panel, "hidden", {
    get() {
      return this._hidden;
    },
    set(v) {
      this._hidden = v;
    },
  });
  panels.push(panel);
  triggers.push({
    attrs: {},
    setAttribute(name, value) {
      this.attrs[name] = value;
    },
    addEventListener() {},
  });

  const dropdowns = wireMenuDropdowns(root);
  assert.equal(panels[0].hidden, true);
  dropdowns.openMenu(root.querySelectorAll("#menu-bar .menu")[0]);
  assert.equal(panels[0].hidden, false);
  assert.equal(triggers[0].attrs["aria-expanded"], "true");
}

console.log("menu_bar.test.mjs OK");
