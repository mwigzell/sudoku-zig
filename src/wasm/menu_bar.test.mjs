// menu_bar.test.mjs — menu bar legend sync contract.

import assert from "node:assert/strict";
import {
  syncMenuBar,
  wireMenuBar,
  wireMenuDropdowns,
  collectMenuBarControls,
  MENU_BAR_MENUS,
  LEGEND_WIRE_EXPORT,
  LEGEND_WIRE_COPY,
  LEGEND_WIRE_PASTE,
} from "./menu_bar.js";

function makeBtn() {
  return { disabled: false, textContent: "", setAttribute() {} };
}

function makeControls() {
  return {
    new: makeBtn(),
    open: makeBtn(),
    import: makeBtn(),
    export: makeBtn(),
    save: makeBtn(),
    saveAs: makeBtn(),
    autoSave: makeBtn(),
    settings: makeBtn(),
    undo: makeBtn(),
    redo: makeBtn(),
    copy: makeBtn(),
    paste: makeBtn(),
    solve: makeBtn(),
    deselect: makeBtn(),
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
    { auto_save: false },
  );
  assert.equal(controls.new.disabled, false);
  assert.equal(controls.open.disabled, true);
  assert.equal(controls.save.disabled, false);
  assert.equal(controls.saveAs.disabled, true);
  assert.equal(controls.undo.disabled, false);
  assert.equal(controls.redo.disabled, true);
  assert.equal(controls.solve.disabled, true);
  // Import mirrors legend.import.
  syncMenuBar({ import: true }, controls);
  assert.equal(controls.import.disabled, false);
  syncMenuBar({ import: false }, controls);
  assert.equal(controls.import.disabled, true);
  syncMenuBar({ [LEGEND_WIRE_EXPORT]: true }, controls);
  assert.equal(controls.export.disabled, false);
  syncMenuBar({ [LEGEND_WIRE_EXPORT]: false }, controls);
  assert.equal(controls.export.disabled, true);
  syncMenuBar({ [LEGEND_WIRE_COPY]: true }, controls);
  assert.equal(controls.copy.disabled, false);
  syncMenuBar({ [LEGEND_WIRE_COPY]: false }, controls);
  assert.equal(controls.copy.disabled, true);
  syncMenuBar({ [LEGEND_WIRE_PASTE]: true }, controls);
  assert.equal(controls.paste.disabled, false);
  syncMenuBar({ [LEGEND_WIRE_PASTE]: false }, controls);
  assert.equal(controls.paste.disabled, true);
}

{
  const controls = makeControls();
  syncMenuBar({ save: true }, controls, { auto_save: true });
  assert.equal(controls.save.disabled, true);
  assert.equal(controls.autoSave.textContent, "Auto Save (On)");
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
  assert.ok(labels.includes("Deselect Cell"));
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
  assert.equal(controls.deselect.id, "#edit-deselect");
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
          addEventListener() {},
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
  const triggerListeners = {};
  triggers.push({
    attrs: {},
    setAttribute(name, value) {
      this.attrs[name] = value;
    },
    addEventListener(type, fn) {
      triggerListeners[type] = fn;
    },
  });

  const dropdowns = wireMenuDropdowns(root);
  assert.equal(panels[0].hidden, true);
  dropdowns.openMenu(root.querySelectorAll("#menu-bar .menu")[0]);
  assert.equal(panels[0].hidden, false);
  assert.equal(triggers[0].attrs["aria-expanded"], "true");

  panels[0].hidden = true;
  triggers[0].attrs["aria-expanded"] = "false";
  let prevented = false;
  triggerListeners.mousedown({
    preventDefault() {
      prevented = true;
    },
    stopPropagation() {},
  });
  assert.equal(prevented, true);
  assert.equal(panels[0].hidden, false);
}

// ── drag across menu triggers while mouse down ──
{
  const menus = [
    { id: "file", dataset: { open: "false" }, panel: { _hidden: true }, trigger: { attrs: {} } },
    { id: "edit", dataset: { open: "false" }, panel: { _hidden: true }, trigger: { attrs: {} } },
  ];
  for (const menu of menus) {
    Object.defineProperty(menu.panel, "hidden", {
      get() {
        return this._hidden;
      },
      set(v) {
        this._hidden = v;
      },
    });
    menu.querySelector = (sel) => {
      if (sel === ".menu-panel") return menu.panel;
      if (sel === ".menu-trigger") return menu.trigger;
      return null;
    };
    menu.trigger.setAttribute = (name, value) => {
      menu.trigger.attrs[name] = value;
    };
    menu.listeners = {};
    menu.addEventListener = (type, fn) => {
      menu.listeners[type] = fn;
    };
  }

  const triggerListeners = [{}, {}];
  for (let i = 0; i < menus.length; i += 1) {
    menus[i].trigger.addEventListener = (type, fn) => {
      triggerListeners[i][type] = fn;
    };
  }

  const docListeners = {};
  const doc = {
    elementFromPoint() {
      return null;
    },
    addEventListener(type, fn, opts) {
      if (type === "mouseup" && opts?.capture) docListeners.mouseup = fn;
    },
  };
  const root = {
    ownerDocument: doc,
    querySelectorAll(selector) {
      if (selector === "#menu-bar .menu") return menus;
      return [];
    },
    addEventListener() {},
  };

  wireMenuDropdowns(root);

  triggerListeners[0].mousedown({ preventDefault() {}, stopPropagation() {}, button: 0 });
  assert.equal(menus[0].panel.hidden, false);
  assert.equal(menus[0].dataset.open, "true");

  menus[1].listeners.mouseenter();
  assert.equal(menus[0].panel.hidden, true);
  assert.equal(menus[1].panel.hidden, false);
  assert.equal(menus[1].dataset.open, "true");

  docListeners.mouseup({ button: 0, target: menus[1].trigger, clientX: 0, clientY: 0 });
  assert.equal(menus[1].panel.hidden, false, "menu stays open after mouseup on trigger");
}

// ── drag File → New: release over item runs its click handler ──
{
  let newClicks = 0;
  const fileTrigger = {
    attrs: {},
    closest(sel) {
      return sel === ".menu-trigger" ? fileTrigger : null;
    },
    setAttribute(name, value) {
      this.attrs[name] = value;
    },
  };
  let fileMenuEl;
  const filePanel = {
    _hidden: false,
    closest(sel) {
      if (sel === ".menu") return fileMenuEl;
      return null;
    },
  };
  Object.defineProperty(filePanel, "hidden", {
    get() {
      return this._hidden;
    },
    set(v) {
      this._hidden = v;
    },
  });
  fileMenuEl = {
    dataset: { open: "false" },
    querySelector(sel) {
      if (sel === ".menu-panel") return filePanel;
      if (sel === ".menu-trigger") return fileTrigger;
      return null;
    },
    addEventListener() {},
  };
  const newBtn = {
    disabled: false,
    closest(sel) {
      if (typeof sel === "string" && sel.includes("menu-panel button")) return newBtn;
      if (sel === ".menu-panel") return filePanel;
      if (sel === ".menu") return fileMenuEl;
      return null;
    },
    click() {
      newClicks += 1;
    },
  };
  const triggerListeners = {};
  fileTrigger.addEventListener = (type, fn) => {
    triggerListeners[type] = fn;
  };
  const docListeners = {};
  const doc = {
    elementFromPoint() {
      return newBtn;
    },
    addEventListener(type, fn, opts) {
      if (type === "mouseup" && opts?.capture) docListeners.mouseup = fn;
    },
  };
  const root = {
    ownerDocument: doc,
    querySelectorAll(sel) {
      return sel === "#menu-bar .menu" ? [fileMenuEl] : [];
    },
    addEventListener() {},
  };
  wireMenuDropdowns(root);
  triggerListeners.mousedown({ preventDefault() {}, stopPropagation() {}, button: 0 });
  filePanel._hidden = false;
  docListeners.mouseup({
    button: 0,
    clientX: 10,
    clientY: 10,
    target: fileTrigger,
  });
  assert.equal(newClicks, 1);
}

console.log("menu_bar.test.mjs OK");
