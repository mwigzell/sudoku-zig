// gen_progress_rows_dom.test.mjs — render progressive row state into the generating modal.

import assert from "node:assert/strict";
import {
  GEN_PROGRESS_ATTEMPT_HINT_CLASS,
  GEN_PROGRESS_ROW_CLASS,
  GEN_PROGRESS_HINT_FAST,
  applyGenProgressRowEvent,
  createGenProgressRowState,
  ensureProgressRowSlots,
  renderGenProgressRows,
  setProgressRowsVisible,
} from "./gen_progress_rows.js";

function makeElement(tag = "div") {
  const el = {
    tag,
    _children: [],
    className: "",
    textContent: "",
    hidden: false,
    style: { display: "none" },
    classList: {
      _set: new Set(),
      add(...names) {
        names.forEach((n) => this._set.add(n));
        el.className = [...this._set].join(" ");
      },
      remove(...names) {
        names.forEach((n) => this._set.delete(n));
      },
      contains(name) {
        return this._set.has(name);
      },
    },
    appendChild(node) {
      el._children.push(node);
    },
    replaceChildren(...nodes) {
      el._children = nodes.length ? nodes : [];
    },
    querySelector(sel) {
      if (sel === `.${GEN_PROGRESS_ATTEMPT_HINT_CLASS}`) {
        return el._children.find((c) => c.classList.contains(GEN_PROGRESS_ATTEMPT_HINT_CLASS));
      }
      return undefined;
    },
    querySelectorAll(sel) {
      if (sel === `.${GEN_PROGRESS_ROW_CLASS}`) {
        return el._children.filter((c) => c.classList.contains(GEN_PROGRESS_ROW_CLASS));
      }
      return [];
    },
    insertBefore(node, ref) {
      const idx = ref ? el._children.indexOf(ref) : el._children.length;
      el._children.splice(idx >= 0 ? idx : el._children.length, 0, node);
    },
  };
  return el;
}

function makeCreateElement() {
  return (tag) => makeElement(tag);
}

{
  const container = makeElement();
  const createElement = makeCreateElement();
  const slots = ensureProgressRowSlots(container, createElement);
  assert.equal(slots.length, 4);
  assert.equal(container._children.length, 5);
  assert.ok(container.querySelector(`.${GEN_PROGRESS_ATTEMPT_HINT_CLASS}`));
  const again = ensureProgressRowSlots(container, createElement);
  assert.equal(again.length, 4);
  assert.equal(container._children.length, 5);
}

{
  const container = makeElement();
  let state = createGenProgressRowState();
  state = applyGenProgressRowEvent(state, 0, 0, 0);
  state = applyGenProgressRowEvent(state, 2, 4, 256);
  renderGenProgressRows(container, state, makeCreateElement());
  const rows = container.querySelectorAll(`.${GEN_PROGRESS_ROW_CLASS}`);
  assert.equal(rows[0].textContent, "Generating: new attempt…");
  assert.equal(rows[0].hidden, false);
  assert.equal(rows[1].textContent, "Generating: try 4/256");
  assert.equal(rows[1].hidden, false);
  assert.equal(rows[2].hidden, true);
  assert.equal(rows[3].hidden, true);
}

{
  const container = makeElement();
  setProgressRowsVisible(container, true);
  assert.equal(container.style.display, "block");
  setProgressRowsVisible(container, false);
  assert.equal(container.style.display, "none");
}

{
  const container = makeElement();
  let state = createGenProgressRowState();
  state = applyGenProgressRowEvent(state, 0, 0, 0);
  state = applyGenProgressRowEvent(state, 2, 3, 256);
  renderGenProgressRows(container, state, makeCreateElement());
  const hint = container.querySelector(`.${GEN_PROGRESS_ATTEMPT_HINT_CLASS}`);
  assert.ok(hint);
  assert.equal(hint.textContent, GEN_PROGRESS_HINT_FAST);
  assert.equal(hint.hidden, false);
  const rows = container.querySelectorAll(`.${GEN_PROGRESS_ROW_CLASS}`);
  assert.equal(container._children.indexOf(hint), container._children.indexOf(rows[0]) + 1);
}
