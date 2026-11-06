// shortcuts.test.mjs — each key presses its control; Cmd takes Ctrl's place on Mac; menu items show their key.

import assert from "node:assert/strict";
import * as shortcuts from "./shortcuts.js";
import * as playPad from "../play_pad.js";
import * as marks from "./marks.js";
import * as webSteps from "../flows/web_steps.js";
import { loadGame, promptDialogStub, settleFlow, startNewGame } from "../test_support.mjs";

const byTarget = (selector) => shortcuts.SHORTCUTS.find((s) => s.target === selector);
const PENCIL = '#play-pad [data-pad-command="pencil"]';

// ── matching: letters take no modifier; Ctrl (Cmd on Mac) and Shift pick the mod shortcuts ──
{
  const pc = false;
  const mac = true;
  assert.equal(shortcuts.matchShortcut({ key: "p" }, pc)?.target, PENCIL);
  assert.equal(shortcuts.matchShortcut({ key: "P", shiftKey: true }, pc), null, "Shift+P is not P");
  assert.equal(shortcuts.matchShortcut({ key: "p", altKey: true }, pc), null);
  assert.equal(shortcuts.matchShortcut({ key: "s", ctrlKey: true }, pc)?.target, "#file-save");
  assert.equal(shortcuts.matchShortcut({ key: "S", ctrlKey: true, shiftKey: true }, pc)?.target, "#file-save-as");
  assert.equal(shortcuts.matchShortcut({ key: "Z", ctrlKey: true, shiftKey: true }, pc)?.target, "#edit-redo");
  assert.equal(shortcuts.matchShortcut({ key: "s", metaKey: true }, pc), null, "Meta is not Ctrl off the Mac");
  assert.equal(shortcuts.matchShortcut({ key: "s", metaKey: true }, mac)?.target, "#file-save", "Cmd+S on Mac");
  assert.equal(shortcuts.matchShortcut({ key: "z", metaKey: true }, mac)?.target, "#edit-undo", "Cmd+Z on Mac");
  assert.equal(shortcuts.matchShortcut({ key: "s", ctrlKey: true }, mac), null, "Cmd replaces Ctrl on Mac");
  assert.equal(shortcuts.matchShortcut({ key: "p", ctrlKey: true }, pc), null, "a letter shortcut takes no modifier");

  assert.equal(shortcuts.shortcutLabel(byTarget("#file-save-as"), pc), "Ctrl+Shift+S");
  assert.equal(shortcuts.shortcutLabel(byTarget("#file-open"), mac), "Cmd+O");
  assert.equal(shortcuts.shortcutLabel(byTarget("#view-marks"), pc), "M");
  assert.equal(shortcuts.isMacPlatform({ platform: "MacIntel" }), true);
  assert.equal(shortcuts.isMacPlatform({ userAgentData: { platform: "macOS" } }), true, "Chromium names it macOS");
  assert.equal(shortcuts.isMacPlatform({ userAgentData: { platform: "Android" }, platform: "Linux armv8l" }), false);
}

function makeControl(role = null) {
  const handlers = {};
  return {
    disabled: false,
    clicks: 0,
    attrs: role ? { role } : {},
    children: [],
    setAttribute(name, value) {
      this.attrs[name] = value;
    },
    getAttribute(name) {
      return this.attrs[name] ?? null;
    },
    append(child) {
      this.children.push(child);
    },
    addEventListener(type, fn) {
      handlers[type] = fn;
    },
    click() {
      this.clicks += 1;
      handlers.click?.({ stopPropagation() {} });
    },
  };
}

/** A page with the given controls by selector; `modalOpen` stands in for an open dialog. */
function makeRoot(controls) {
  const listeners = {};
  const root = {
    modalOpen: false,
    addEventListener(type, fn) {
      listeners[type] = fn;
    },
    querySelector(selector) {
      if (selector.includes("aria-modal")) return root.modalOpen ? {} : null;
      return controls[selector] ?? null;
    },
    createElement: () => ({ className: "", textContent: "" }),
    press(event) {
      let prevented = false;
      listeners.keydown({ ...event, preventDefault: () => (prevented = true) });
      return prevented;
    },
  };
  return root;
}

// ── wiring: labels on menu items, keys press their control unless typing, a dialog or disabled ──
{
  const save = makeControl("menuitem");
  const marksItem = makeControl("menuitemcheckbox");
  const pencil = makeControl();
  const root = makeRoot({ "#file-save": save, "#view-marks": marksItem, [PENCIL]: pencil });
  shortcuts.wireShortcuts(/** @type {any} */ (root), { platform: "Win32" });

  assert.equal(save.children[0].textContent, "Ctrl+S", "a menu item shows its shortcut");
  assert.equal(save.children[0].className, shortcuts.SHORTCUT_LABEL_CLASS);
  assert.equal(save.attrs["aria-keyshortcuts"], "Control+S");
  assert.equal(marksItem.children[0].textContent, "M");
  assert.equal(pencil.children.length, 0, "a pad button gets no label");
  assert.equal(pencil.attrs["aria-keyshortcuts"], "P");

  assert.equal(root.press({ key: "p" }), true);
  assert.equal(pencil.clicks, 1, "P presses the Pencil button");
  root.press({ key: "p", repeat: true });
  assert.equal(pencil.clicks, 1, "a held key presses once");
  root.press({ key: "p", target: { closest: () => ({}) } });
  assert.equal(pencil.clicks, 1, "typing in a field is not a shortcut");
  root.modalOpen = true;
  root.press({ key: "p" });
  assert.equal(pencil.clicks, 1, "an open dialog takes no shortcuts");
  root.modalOpen = false;

  save.disabled = true;
  assert.equal(root.press({ key: "s", ctrlKey: true }), true, "Ctrl+S is taken even while Save is disabled");
  assert.equal(save.clicks, 0, "a disabled item is not pressed");
  assert.equal(root.press({ key: "x" }), false, "other keys are left alone");
}

// ── wired to a real game: P runs the Pencil button's command, so core's Pencil mode toggles ──
{
  const game = await loadGame();
  startNewGame(game);
  const session = { state: game.getState(), legend: game.getLegend(), config: game.getConfig() };
  const steps = webSteps.webSteps(game, session, { statusEl: { textContent: "", className: "" }, promptDialog: promptDialogStub() });
  const boardEl = { children: [], replaceChildren() {} };
  const createElement = () => ({ dataset: {}, setAttribute() {}, appendChild() {}, classList: { add() {}, remove() {}, contains: () => false } });
  const selection = { getSelection: () => null, select() {}, deselect() {} };
  const pencil = makeControl();
  const marksMenu = marks.wireMarks({}, game, session, boardEl, selection, { steps, createElement });
  playPad.wirePlayPad({ pencil }, { runEdit() {}, toggleRegion() {}, togglePencilMode: marksMenu.togglePencilMode });
  const root = makeRoot({ [PENCIL]: pencil });
  shortcuts.wireShortcuts(/** @type {any} */ (root), { platform: "Linux x86_64" });

  assert.equal(session.state.pencil_mode, false);
  root.press({ key: "p" });
  await settleFlow();
  assert.equal(session.state.pencil_mode, true, "P turns core's Pencil mode on");
  root.press({ key: "P" });
  await settleFlow();
  assert.equal(session.state.pencil_mode, false, "Caps Lock P turns it off again");
}

console.log("shortcuts.test.mjs OK");
