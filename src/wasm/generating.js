// generating.js — blocking “Generating…” modal; user dismisses via Continue when ready.

export const GENERATING_MSG_BUSY = "Generating…";
export const GENERATING_MSG_DONE = "Generating… Done";
export const GENERATING_MSG_CANCELLING = "Cancelling…";

/** Let the browser paint modal open/close before sync wasm work blocks the main thread. */
function waitForDialogPaint() {
  if (typeof requestAnimationFrame !== "function") return Promise.resolve();
  return new Promise((resolve) => {
    requestAnimationFrame(() => requestAnimationFrame(resolve));
  });
}

/** Wire Continue dismiss; disabled until `setReady(true)`. */
export function wireGeneratingModal({ el, continueBtn, cancelBtn, spinnerEl, msgEl }) {
  let continueResolve = null;
  let cancelHandler = null;

  const showSpinner = (visible) => {
    if (spinnerEl) spinnerEl.hidden = !visible;
  };

  const setMessage = (text) => {
    if (msgEl) msgEl.textContent = text;
  };

  const setButtonsDisabled = (disabled) => {
    continueBtn.disabled = disabled;
    if (cancelBtn) cancelBtn.disabled = disabled;
  };

  continueBtn.addEventListener("click", () => {
    if (continueBtn.disabled) return;
    if (continueResolve) {
      continueResolve();
      continueResolve = null;
    }
  });

  cancelBtn?.addEventListener("click", () => {
    if (cancelBtn.disabled) return;
    cancelHandler?.();
  });

  return {
    el,
    continueBtn,
    cancelBtn,
    open() {
      el.hidden = false;
      setButtonsDisabled(true);
      if (cancelBtn) cancelBtn.disabled = false;
      continueBtn.disabled = true;
      showSpinner(true);
      setMessage(GENERATING_MSG_BUSY);
    },
    close() {
      el.hidden = true;
      cancelHandler = null;
      setButtonsDisabled(true);
      showSpinner(false);
      setMessage(GENERATING_MSG_BUSY);
    },
    setReady(ready) {
      continueBtn.disabled = !ready;
      if (cancelBtn) cancelBtn.disabled = true;
      if (ready) {
        showSpinner(false);
        setMessage(GENERATING_MSG_DONE);
      }
    },
    setCancelling() {
      setButtonsDisabled(true);
      showSpinner(false);
      setMessage(GENERATING_MSG_CANCELLING);
    },
    setCancelHandler(fn) {
      cancelHandler = fn ?? null;
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
  const cancelRef = { fn: null };
  modal.setCancelHandler(() => {
    modal.setCancelling();
    cancelRef.fn?.();
  });
  await waitForDialogPaint();
  const result = await task(cancelRef);
  modal.setCancelHandler(null);
  if (result.cancelled) {
    modal.close();
    return result;
  }
  if (!result.ok) {
    modal.close();
    return result;
  }
  modal.setReady(true);
  await modal.waitForContinue();
  modal.close();
  return result;
}
