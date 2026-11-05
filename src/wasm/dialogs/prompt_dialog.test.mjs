// prompt_dialog.test.mjs — the shared prompt dialog: type badge, title, text, core's buttons in order;
// the rightmost is focused; pressing or dismissing answers the button's index.

import assert from "node:assert/strict";
import * as promptDialogMod from "./prompt_dialog.js";

function fakeElement(tag = "div") {
  const listeners = new Map();
  return {
    tag,
    hidden: true,
    textContent: "",
    className: "",
    id: "",
    dataset: {},
    children: [],
    focused: false,
    addEventListener(type, fn) {
      listeners.set(type, fn);
    },
    dispatch(type, event = {}) {
      listeners.get(type)?.({ target: this, stopPropagation() {}, preventDefault() {}, ...event });
    },
    click() {
      this.dispatch("click");
    },
    focus() {
      this.focused = true;
    },
    replaceChildren(...children) {
      this.children = children;
    },
  };
}

function wire() {
  const els = {
    el: fakeElement(),
    badgeEl: fakeElement(),
    titleEl: fakeElement(),
    textEl: fakeElement(),
    buttonsEl: fakeElement(),
  };
  const opens = [];
  const dialog = promptDialogMod.wirePromptDialog({
    ...els,
    doc: { createElement: (tag) => fakeElement(tag) },
    onOpenChange: (open) => opens.push(open),
  });
  return { ...els, dialog, opens };
}

/** @returns {import("../types").PromptStep} */
function prompt(fields) {
  return { step: "prompt_message", type: "warning", title: "Title", text: "Text", buttons: ["One"], default: 0, dismiss: 0, ...fields };
}

const THREE = prompt({ type: "information", buttons: ["Left", "Middle", "Right"], default: 2, dismiss: 0 });

{
  // Three buttons show left to right with the type badge and title; the rightmost is the focused default.
  const ui = wire();
  const answer = ui.dialog.show(THREE);
  assert.equal(ui.el.hidden, false);
  assert.equal(ui.badgeEl.textContent, promptDialogMod.TYPE_BADGES.information);
  assert.equal(ui.titleEl.textContent, "Title");
  assert.equal(ui.textEl.textContent, "Text");
  assert.deepEqual(ui.buttonsEl.children.map((b) => b.textContent), ["Left", "Middle", "Right"]);
  assert.deepEqual(ui.buttonsEl.children.map((b) => b.id), [0, 1, 2].map((i) => `${promptDialogMod.BUTTON_ID_PREFIX}${i}`));
  assert.deepEqual(ui.buttonsEl.children.map((b) => b.focused), [false, false, true]);
  assert.equal(ui.buttonsEl.children[2].className, promptDialogMod.DEFAULT_BUTTON_CLASS);
  ui.buttonsEl.children[1].click();
  assert.equal(await answer, 1, "pressing the middle button answers its index");
  assert.equal(ui.el.hidden, true);
  assert.deepEqual(ui.opens, [true, false]);
}

{
  // Escape and a tap outside answer the cancel button core named.
  const ui = wire();
  const escaped = ui.dialog.show(THREE);
  ui.el.dispatch("keydown", { key: "Escape" });
  assert.equal(await escaped, 0);
  const tapped = ui.dialog.show(THREE);
  ui.el.dispatch("click");
  assert.equal(await tapped, 0);
  const backed = ui.dialog.show(THREE);
  ui.dialog.dismiss();
  assert.equal(await backed, 0, "Android Back dismisses the same way");
}

{
  // With no cancel named, dismissing does nothing; a button still answers.
  const ui = wire();
  const answer = ui.dialog.show(prompt({ buttons: ["A", "B"], default: 1, dismiss: null }));
  ui.el.dispatch("keydown", { key: "Escape" });
  ui.el.dispatch("click");
  ui.dialog.dismiss();
  assert.equal(ui.el.hidden, false, "still open");
  ui.buttonsEl.children[1].click();
  assert.equal(await answer, 1);
}

{
  // Every type renders its own badge: its mark, and the type the page styles the badge by.
  const marks = new Set();
  for (const type of ["information", "warning", "error"]) {
    const ui = wire();
    void ui.dialog.show(prompt({ type }));
    assert.equal(ui.badgeEl.textContent, promptDialogMod.TYPE_BADGES[type]);
    assert.equal(ui.el.dataset.type, type);
    marks.add(ui.badgeEl.textContent);
  }
  assert.equal(marks.size, 3, "each type has its own mark");
}

console.log("prompt_dialog.test.mjs OK");
