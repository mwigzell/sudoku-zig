// app_wire.test.mjs — the page's own wiring: a Config change made in Settings reaches the View item that reads it.

import assert from "node:assert/strict";
import * as appWire from "./app_wire.js";
import * as sessionMod from "./flows/session.js";
import { configTable, loadGame, promptDialogStub, startNewGame } from "./test_support.mjs";

const NO_OP = () => {};

/** Every menu item id the page shell wires a click on, from `page.html`'s menubar. */
const LEGEND_KEYS = [
  "file-new",
  "file-open",
  "file-import",
  "file-export",
  "file-save",
  "file-save-as",
  "file-auto-save",
  "file-settings",
  "edit-undo",
  "edit-redo",
  "edit-bookmark",
  "edit-rewind",
  "edit-copy",
  "edit-paste",
  "edit-solve",
  "edit-hint",
  "edit-deselect",
  "view-system",
  "view-light",
  "view-dark",
  "view-region",
  "help-about",
];

/**
 * An element the wiring can listen to, click and read. Only the members this test reaches are real;
 * the rest are inert, because the wiring under test never calls them.
 */
function makeEl(tag = "div") {
  const handlers = {};
  return {
    tagName: tag.toUpperCase(),
    hidden: false,
    disabled: false,
    textContent: "",
    value: "",
    checked: false,
    dataset: {},
    attrs: {},
    className: "",
    style: {},
    children: [],
    classList: { toggle: NO_OP, add: NO_OP, remove: NO_OP, contains: () => false },
    setAttribute(name, value) {
      this.attrs[name] = value;
    },
    getAttribute(name) {
      return this.attrs[name];
    },
    append(...nodes) {
      this.children.push(...nodes);
    },
    appendChild(node) {
      this.children.push(node);
      return node;
    },
    replaceChildren(...nodes) {
      this.children = nodes;
    },
    querySelector: () => null,
    querySelectorAll: () => [],
    closest: () => null,
    focus: NO_OP,
    addEventListener(type, fn) {
      handlers[type] = fn;
      // Dialogs hand back the listener as `on<type>`, as a browser element exposes it.
      this[`on${type}`] = fn;
    },
    click() {
      handlers.click?.({ stopPropagation: NO_OP, preventDefault: NO_OP });
    },
  };
}

/**
 * The page shell `wireSudokuApp` reaches for: every element it looks up by id, the Config table's
 * Settings controls, and the two View items that read the setting.
 * @returns {{ doc: any, win: any, viewMarks: any, field: (name: string) => any }}
 */
function makeShell() {
  const byId = new Map();
  for (const id of [
    "status-bar",
    "board",
    "play-pad",
    "about-modal",
    "about-modal-title",
    "about-summary",
    "about-copyright",
    "about-modal-dismiss",
    "new-difficulty-modal",
    "new-difficulty-buttons",
    "new-difficulty-cancel",
    "settings-modal-dismiss",
    "prompt-dialog",
    "prompt-dialog-badge",
    "prompt-dialog-title",
    "prompt-dialog-text",
    "prompt-dialog-buttons",
    "menu-bar",
  ]) {
    byId.set(id, makeEl());
  }

  // Settings dialog: the page's own shell hands `buildSettingsFields` an empty field list, and the
  // dialog fills it from core's table.
  const fieldsEl = makeEl();
  byId.set("settings-modal", makeEl());
  byId.set("settings-fields", fieldsEl);

  // Every menu item the shell looks up by id, the View item under test among them: the menubar wires
  // them by `querySelector`, so one element per id stands for both the dropdown and the lookup.
  const menuButtons = new Map(LEGEND_KEYS.map((id) => [`#${id}`, makeEl("button")]));
  const viewMarks = makeEl("button");
  menuButtons.set("#view-marks", viewMarks);

  // The board frame with its play grid, as the shell builds it on the page.
  const boardEl = byId.get("board");
  const playGrid = makeEl();
  playGrid.classList.add("board-play");
  boardEl.querySelector = (selector) => (selector === ".board-play" ? playGrid : null);

  // The menubar's dropdowns, each holding its items; the shell opens and closes them by dataset.
  const menus = [...menuButtons.keys()].map(() => makeEl());
  const menuBarEl = byId.get("menu-bar");
  menuBarEl.querySelectorAll = (selector) => (selector === "#menu-bar .menu" ? menus : []);

  const doc = {
    getElementById: (id) => byId.get(id) ?? null,
    querySelector: (selector) => menuButtons.get(selector) ?? null,
    querySelectorAll: () => [],
    createElement: (tag) => makeEl(tag),
    addEventListener: NO_OP,
    documentElement: makeEl("html"),
    body: makeEl("body"),
  };
  const win = {
    navigator: {},
    matchMedia: () => ({ matches: false, addEventListener: NO_OP }),
    document: doc,
    fetch: async () => ({ ok: true, status: 204, json: async () => ({}) }),
  };
  doc.defaultView = win;

  // Board, shortcut and step-handler wiring fall back to the browser's own globals. Node has a global
  // `fetch` of its own that rejects a relative URL, so the host's stands in for it here.
  globalThis.document = doc;
  globalThis.window = win;
  globalThis.fetch = win.fetch;

  /** The control the dialog generated for one table field. */
  const field = (name) => {
    for (const label of fieldsEl.children) {
      const input = label.children.find((child) => child.dataset?.field === name);
      if (input) return input;
    }
    throw new Error(`no Settings control for ${name}`);
  };
  return { doc, win, viewMarks, field };
}

const game = await loadGame();
startNewGame(game);
const session = sessionMod.createWebSessionFromStartup({
  state: game.getState(),
  legend: game.getLegend(),
  config: game.getConfig(),
  config_table: configTable,
  default_save_filename: "sudoku.sud",
});
const { doc, win, viewMarks, field } = makeShell();
const fetchFn = async () => ({ ok: true, status: 204, json: async () => ({}) });

appWire.wireSudokuApp({
  game,
  session,
  generatingModal: { waitForContinue: async () => {} },
  genWorker: {},
  root: doc,
  win,
  fetchFn,
  promptDialog: promptDialogStub(),
});

assert.equal(viewMarks.disabled, false, "Show Pencil Marks is free with Auto Pencil off");

// The player turns Auto Pencil on in Settings. Nothing here calls the page's sync hooks by hand:
// the wiring under test has to carry the new Config to the View item itself.
const row = field("auto_pencil");
row.checked = true;
await row.onchange();
assert.equal(session.config.auto_pencil, true, "the dialog's row sets the setting");
assert.equal(viewMarks.disabled, true, "Show Pencil Marks is unavailable while Auto Pencil is on");

// Flipping it back off gives the item its pick again.
row.checked = false;
await row.onchange();
assert.equal(session.config.auto_pencil, false);
assert.equal(viewMarks.disabled, false, "Show Pencil Marks is free again with Auto Pencil off");

console.log("app_wire.test.mjs OK");
