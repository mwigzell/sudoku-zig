// generating.js — blocking “Generating…” modal; user dismisses via Continue when ready.

export const GENERATING_MSG_BUSY = "Generating…";
export const GENERATING_MSG_DONE = "Generating… Done";

/** Let the browser paint modal open/close before sync wasm work blocks the main thread. */
function waitForDialogPaint() {
  if (typeof requestAnimationFrame !== "function") return Promise.resolve();
  return new Promise((resolve) => {
    requestAnimationFrame(() => requestAnimationFrame(resolve));
  });
}

/** Wire Continue dismiss; disabled until `setReady(true)`. */
export function wireGeneratingModal({ el, continueBtn, spinnerEl, msgEl }) {
  let continueResolve = null;

  const showSpinner = (visible) => {
    if (spinnerEl) spinnerEl.hidden = !visible;
  };

  const setMessage = (text) => {
    if (msgEl) msgEl.textContent = text;
  };

  continueBtn.addEventListener("click", () => {
    if (continueBtn.disabled) return;
    if (continueResolve) {
      continueResolve();
      continueResolve = null;
    }
  });

  return {
    el,
    continueBtn,
    open() {
      el.hidden = false;
      continueBtn.disabled = true;
      showSpinner(true);
      setMessage(GENERATING_MSG_BUSY);
    },
    close() {
      el.hidden = true;
      continueBtn.disabled = true;
      showSpinner(false);
      setMessage(GENERATING_MSG_BUSY);
    },
    setReady(ready) {
      continueBtn.disabled = !ready;
      if (ready) {
        showSpinner(false);
        setMessage(GENERATING_MSG_DONE);
      }
    },
    waitForContinue() {
      return new Promise((resolve) => {
        continueResolve = resolve;
      });
    },
  };
}

/** Open modal, run gen task, enable Continue on success, close after user continues. */
export async function runWithGeneratingDialog(modal, task) {
  modal.open();
  await waitForDialogPaint();
  const result = await task();
  if (!result.ok) {
    modal.close();
    return result;
  }
  modal.setReady(true);
  await modal.waitForContinue();
  modal.close();
  return result;
}
