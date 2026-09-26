// generating.test.mjs — generating modal + Continue gate (issue #57 step 1).

import assert from "node:assert/strict";
import {
  GENERATING_MSG_BUSY,
  GENERATING_MSG_DONE,
  wireGeneratingModal,
  runWithGeneratingDialog,
} from "./generating.js";

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
  const modal = wireGeneratingModal({ el, continueBtn, spinnerEl, msgEl });

  modal.open();
  assert.equal(el.hidden, false);
  assert.equal(continueBtn.disabled, true);
  assert.equal(spinnerEl.hidden, false, "spinner visible while generating");
  assert.equal(msgEl.textContent, GENERATING_MSG_BUSY);

  modal.setReady(true);
  assert.equal(continueBtn.disabled, false);
  assert.equal(spinnerEl.hidden, true, "spinner hidden when ready");
  assert.equal(msgEl.textContent, GENERATING_MSG_DONE);

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
  const modal = wireGeneratingModal({ el, continueBtn, spinnerEl, msgEl });

  const running = runWithGeneratingDialog(modal, async () => ({ ok: true, value: 42 }));
  await flushDialogPaint();
  assert.equal(continueBtn.disabled, false);
  assert.equal(spinnerEl.hidden, true, "runWithGeneratingDialog hides spinner when done");
  assert.equal(msgEl.textContent, GENERATING_MSG_DONE);
  continueBtn.click();
  const out = await running;
  assert.equal(out.ok, true);
  assert.equal(out.value, 42);
  assert.equal(el.hidden, true);
}

{
  const el = { hidden: true };
  const continueBtn = makeContinueBtn();
  const modal = wireGeneratingModal({ el, continueBtn });

  const out = await runWithGeneratingDialog(modal, async () => ({
    ok: false,
    error: "nope",
  }));
  assert.equal(out.ok, false);
  assert.equal(out.error, "nope");
  assert.equal(el.hidden, true, "failure closes without Continue");
}
