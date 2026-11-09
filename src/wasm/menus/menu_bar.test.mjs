// menu_bar.test.mjs — menu bar legend sync contract.

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import * as menuBar from "./menu_bar.js";
import * as settings from "./settings.js";
import { configTable } from "../test_support.mjs";

const rowLabel = (field) => settings.configRow(configTable, field).label;
const choiceLabel = (field, name) => settings.choiceLabel(configTable, field, name);

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
    viewSystem: makeBtn(),
    viewLight: makeBtn(),
    viewDark: makeBtn(),
    viewRegion: makeBtn(),
    viewMarks: makeBtn(),
    about: makeBtn(),
  };
}

// ── File + Edit items follow legend flags ──
{
  const controls = makeControls();
  menuBar.syncMenuBar(
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
  menuBar.syncMenuBar({ import: true }, controls);
  assert.equal(controls.import.disabled, false);
  menuBar.syncMenuBar({ import: false }, controls);
  assert.equal(controls.import.disabled, true);
  menuBar.syncMenuBar({ [menuBar.LEGEND_WIRE_EXPORT]: true }, controls);
  assert.equal(controls.export.disabled, false);
  menuBar.syncMenuBar({ [menuBar.LEGEND_WIRE_EXPORT]: false }, controls);
  assert.equal(controls.export.disabled, true);
  menuBar.syncMenuBar({ [menuBar.LEGEND_WIRE_COPY]: true }, controls);
  assert.equal(controls.copy.disabled, false);
  menuBar.syncMenuBar({ [menuBar.LEGEND_WIRE_COPY]: false }, controls);
  assert.equal(controls.copy.disabled, true);
  menuBar.syncMenuBar({ [menuBar.LEGEND_WIRE_PASTE]: true }, controls);
  assert.equal(controls.paste.disabled, false);
  menuBar.syncMenuBar({ [menuBar.LEGEND_WIRE_PASTE]: false }, controls);
  assert.equal(controls.paste.disabled, true);
}

{
  const controls = makeControls();
  menuBar.syncMenuBar({ save: false }, controls);
  assert.equal(controls.save.disabled, true, "core's legend turns Save off while Auto Save is on");
}

// ── Auto Save shows its row label and core's word for its value ──
{
  const controls = makeControls();
  menuBar.syncAutoSave(controls, { auto_save: true }, configTable);
  assert.equal(controls.autoSave.textContent, `${rowLabel("auto_save")} (${configTable.on})`);
  menuBar.syncAutoSave(controls, { auto_save: false }, configTable);
  assert.equal(controls.autoSave.textContent, `${rowLabel("auto_save")} (${configTable.off})`);
}

// ── View items that set a Config field carry the table's labels ──
{
  const controls = makeControls();
  menuBar.labelConfigItems(controls, configTable);
  assert.equal(controls.viewSystem.textContent, choiceLabel("theme", "system"));
  assert.equal(controls.viewLight.textContent, choiceLabel("theme", "light"));
  assert.equal(controls.viewDark.textContent, choiceLabel("theme", "dark"));
  assert.equal(controls.viewRegion.textContent, rowLabel("show_region"));
  assert.equal(controls.viewMarks.textContent, rowLabel("show_marks"));
}

{
  const controls = makeControls();
  menuBar.syncMenuBar(
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
  menuBar.syncMenuBar({ new: false, open: false, save: false, save_as: false, undo: false, redo: false }, controls);
  assert.equal(controls.viewLight.disabled, false);
  assert.equal(controls.viewDark.disabled, false);
  assert.equal(controls.about.disabled, false);
}

// ── no Quit on web ──
{
  const labels = menuBar.MENU_BAR_MENUS.flatMap((menu) => menu.items.map((item) => item.label));
  assert.ok(!labels.some((label) => /quit/i.test(label)));
  assert.ok(labels.includes("Deselect Cell"));
}

// ── wireMenuBar syncs from session legend on init ──
{
  const controls = makeControls();
  const session = {
    legend: { new: true, open: true, save: true, save_as: true, undo: false, redo: false },
    config: { auto_save: true },
    configTable,
  };
  menuBar.wireMenuBar(controls, session);
  assert.equal(controls.autoSave.textContent, `${rowLabel("auto_save")} (${configTable.on})`);
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
  const controls = menuBar.collectMenuBarControls(root);
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

  const dropdowns = menuBar.wireMenuDropdowns(root);
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

  menuBar.wireMenuDropdowns(root);

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
  menuBar.wireMenuDropdowns(root);
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

// ── clicking a menu action closes the open dropdown ──
{
  const trigger = {
    attrs: {},
    setAttribute(name, value) {
      this.attrs[name] = value;
    },
  };
  const panelListeners = {};
  const panel = {
    _hidden: true,
    addEventListener(type, fn) {
      panelListeners[type] = fn;
    },
  };
  Object.defineProperty(panel, "hidden", {
    get() {
      return this._hidden;
    },
    set(v) {
      this._hidden = v;
    },
  });
  const menu = {
    dataset: { open: "false" },
    querySelector(sel) {
      if (sel === ".menu-panel") return panel;
      if (sel === ".menu-trigger") return trigger;
      return null;
    },
    addEventListener() {},
  };
  trigger.addEventListener = () => {};
  const root = {
    querySelectorAll(sel) {
      return sel === "#menu-bar .menu" ? [menu] : [];
    },
    addEventListener() {},
  };
  const dropdowns = menuBar.wireMenuDropdowns(root);
  dropdowns.openMenu(menu);
  assert.equal(menu.dataset.open, "true");
  assert.equal(panel.hidden, false);
  const action = {
    disabled: false,
    closest(sel) {
      if (typeof sel === "string" && sel.includes("menu-panel button")) return action;
      return null;
    },
  };
  panelListeners.click({ stopPropagation() {}, target: action });
  assert.equal(menu.dataset.open, "false");
  assert.equal(panel.hidden, true);
}

// ── File menu groups: New/Open/Save, then Import/Export, then Settings ──
{
  const html = readFileSync(new URL("../artifacts/page.html", import.meta.url), "utf8");
  const panel = html.match(/<div class="menu-panel" id="menu-file-panel"[^>]*>([\s\S]*?)\n\s*<\/div>\n/)?.[1];
  assert.ok(panel, "page.html has the File menu panel");
  const entries = [...panel.matchAll(/<button[^>]*id="([^"]+)"|role="separator"/g)].map((m) => m[1] ?? "|");
  assert.deepEqual(entries, [
    "file-new", "file-open", "file-save", "file-save-as", "file-auto-save",
    "|", "file-import", "file-export",
    "|", "file-settings",
  ]);
  // A separator is a plain div, so the item selectors that drive clicks and drag-release never match it.
  assert.ok(!/<button[^>]*role="separator"/.test(panel));
}

// ── The menubar is opaque: page content must never show through it ──
{
  const html = readFileSync(new URL("../artifacts/page.html", import.meta.url), "utf8");
  const rule = html.match(/\n\s*#menu-bar \{([\s\S]*?)\n\s*\}/)?.[1];
  assert.ok(rule, "page.html has the #menu-bar rule");
  const background = rule.match(/(?:^|\s)background(?:-color)?:\s*([^;]+);/)?.[1].trim();
  assert.ok(background, "#menu-bar declares a background");
  const transparent = /^(?:transparent|none|initial|unset)$/i.test(background) || /rgba?\([^)]*,\s*0(?:\.0+)?\s*\)$/.test(background);
  assert.ok(!transparent, `#menu-bar background must not be transparent (got ${background})`);
}

console.log("menu_bar.test.mjs OK");
