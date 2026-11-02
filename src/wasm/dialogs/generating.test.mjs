// generating.test.mjs — generating modal + Continue gate.

import assert from "node:assert/strict";
import * as generating from "./generating.js";
import { GEN_METHOD_FAST } from "../gen/gen_progress_rows.js";
import { genText } from "../test_support.mjs";

/** Match runWithGeneratingDialog paint yield (Node 22+ has requestAnimationFrame). */
async function flushDialogPaint() {
  if (typeof requestAnimationFrame === "function") {
    await new Promise((resolve) => {
      requestAnimationFrame(() => requestAnimationFrame(resolve));
    });
  }
  await Promise.resolve();
}

function makeContinueBtn() {
  return {
    disabled: false,
    handlers: {},
    addEventListener(type, fn) {
      this.handlers[type] = fn;
    },
    click() {
      this.handlers.click?.();
    },
  };
}

{
  const el = { hidden: true };
  const spinnerEl = { hidden: true };
  const msgEl = { textContent: "" };
  const continueBtn = makeContinueBtn();
  const modal = generating.wireGeneratingModal({ genText, el, continueBtn, spinnerEl, msgEl });

  modal.open();
  assert.equal(el.hidden, false);
  assert.equal(continueBtn.disabled, true);
  assert.equal(spinnerEl.hidden, false, "spinner visible while generating");
  assert.equal(msgEl.textContent, genText.busy);

  modal.setReady(true);
  assert.equal(continueBtn.disabled, false);
  assert.equal(spinnerEl.hidden, true, "spinner hidden when ready");
  assert.equal(msgEl.textContent, genText.done);

  const waiting = modal.waitForContinue();
  continueBtn.click();
  await waiting;

  modal.close();
  assert.equal(el.hidden, true);
}

{
  const el = { hidden: true };
  const spinnerEl = { hidden: true };
  const msgEl = { textContent: "" };
  const continueBtn = makeContinueBtn();
  const modal = generating.wireGeneratingModal({ genText, el, continueBtn, spinnerEl, msgEl });

  const running = generating.runWithGeneratingDialog(modal, async () => ({ ok: true, value: 42 }));
  await flushDialogPaint();
  assert.equal(continueBtn.disabled, false);
  assert.equal(spinnerEl.hidden, true, "runWithGeneratingDialog hides spinner when done");
  assert.equal(msgEl.textContent, genText.done);
  continueBtn.click();
  const out = await running;
  assert.equal(out.ok, true);
  assert.equal(out.value, 42);
  assert.equal(el.hidden, true);
}

{
  const el = { hidden: true };
  const continueBtn = makeContinueBtn();
  const modal = generating.wireGeneratingModal({ genText, el, continueBtn });

  const out = await generating.runWithGeneratingDialog(modal, async () => ({
    ok: false,
    error: "nope",
  }));
  assert.equal(out.ok, false);
  assert.equal(out.error, "nope");
  assert.equal(el.hidden, true, "failure closes without Continue");
}

{
  const el = { hidden: true };
  const spinnerEl = { hidden: true };
  const msgEl = { textContent: "" };
  const continueBtn = makeContinueBtn();
  const cancelBtn = makeContinueBtn();
  const modal = generating.wireGeneratingModal({ genText, el, continueBtn, cancelBtn, spinnerEl, msgEl });

  modal.setCancelling();
  assert.equal(msgEl.textContent, genText.cancelling);
  assert.equal(spinnerEl.hidden, true);
  assert.equal(cancelBtn.disabled, true);
  assert.equal(continueBtn.disabled, true);
}

{
  const el = { hidden: true };
  const continueBtn = makeContinueBtn();
  const modal = generating.wireGeneratingModal({ genText, el, continueBtn });

  const out = await generating.runWithGeneratingDialog(modal, async () => ({ ok: false, cancelled: true }));
  assert.equal(out.cancelled, true);
  assert.equal(el.hidden, true, "cancelled closes without Continue");
}

{
  function makeRowEl() {
    return {
      className: "",
      textContent: "",
      hidden: false,
      classList: { _set: new Set(), add(...n) { n.forEach((x) => this._set.add(x)); }, contains(n) { return this._set.has(n); } },
    };
  }
  const progressRowsEl = {
    style: { display: "none" },
    _children: [],
    appendChild(c) {
      this._children.push(c);
    },
    replaceChildren(...n) {
      this._children = n.length ? n : [];
    },
    querySelectorAll(sel) {
      if (sel === ".gen-progress-row") {
        return this._children.filter((c) => c.classList._set.has("gen-progress-row"));
      }
      return this._children;
    },
    querySelector(sel) {
      if (sel === ".gen-progress-attempt-hint") {
        return this._children.find((c) => c.classList._set.has("gen-progress-attempt-hint"));
      }
      return undefined;
    },
    insertBefore(node, ref) {
      const idx = ref ? this._children.indexOf(ref) : this._children.length;
      this._children.splice(idx >= 0 ? idx : this._children.length, 0, node);
    },
  };
  const el = { hidden: true };
  const continueBtn = makeContinueBtn();
  const modal = generating.wireGeneratingModal({
    genText,
    el,
    continueBtn,
    progressRowsEl,
    createElement: () => makeRowEl(),
  });
  modal.open();
  assert.equal(progressRowsEl.style.display, "block");
  assert.equal(progressRowsEl.querySelectorAll(".gen-progress-row").length, 4);
  assert.equal(progressRowsEl._children.length, 5);
  modal.renderProgressRows({
    rows: [
      "progress line 1",
      "progress line 2",
      "progress line 3",
      "progress line 4",
      "",
    ],
    method: GEN_METHOD_FAST,
  });
  modal.setReady(true);
  assert.equal(progressRowsEl.style.display, "block", "progress stays visible until Continue");
  assert.equal(
    progressRowsEl.querySelectorAll(".gen-progress-row")[3].textContent,
    "progress line 4",
  );
  modal.close();
  assert.equal(progressRowsEl.style.display, "none");
}
