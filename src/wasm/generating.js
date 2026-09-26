// generating.js — blocking “Generating…” modal; user dismisses via Continue when ready.

import {
  createGenProgressRowState,
  renderGenProgressRows,
  setProgressRowsVisible,
} from "./gen_progress_rows.js";

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
export function wireGeneratingModal({
  el,
  continueBtn,
  cancelBtn,
  spinnerEl,
  msgEl,
  progressRowsEl,
  createElement,
}) {
  let continueResolve = null;
  let cancelHandler = null;
  let progressRowState = createGenProgressRowState();
  const mkEl =
    createElement ??
    (typeof document !== "undefined" ? (tag) => document.createElement(tag) : null);

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
      if (progressRowsEl && mkEl) {
        progressRowState = createGenProgressRowState();
        renderGenProgressRows(progressRowsEl, progressRowState, mkEl);
        setProgressRowsVisible(progressRowsEl, true);
      }
    },
    close() {
      el.hidden = true;
      cancelHandler = null;
      setButtonsDisabled(true);
      showSpinner(false);
      setMessage(GENERATING_MSG_BUSY);
      if (progressRowsEl && mkEl) {
        setProgressRowsVisible(progressRowsEl, false);
        progressRowState = createGenProgressRowState();
        renderGenProgressRows(progressRowsEl, progressRowState, mkEl);
      }
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
      if (progressRowsEl) setProgressRowsVisible(progressRowsEl, false);
    },
    renderProgressRows(state) {
      if (!progressRowsEl || !mkEl) return;
      progressRowState = state;
      renderGenProgressRows(progressRowsEl, progressRowState, mkEl);
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
