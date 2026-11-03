// generating.js — blocking “Generating…” modal; user dismisses via Continue when ready.

import * as genProgressRows from "../gen/gen_progress_rows.js";

/** Let the browser paint modal open/close before sync wasm work blocks the main thread. */
function waitForDialogPaint() {
  if (typeof requestAnimationFrame !== "function") return Promise.resolve();
  return new Promise((resolve) => {
    requestAnimationFrame(() => requestAnimationFrame(resolve));
  });
}

/**
 * Wire Continue dismiss; disabled until `setReady(true)`.
 * `genText` is core's dialog text (`game.getGenText()`).
 */
export function wireGeneratingModal({
  genText,
  el,
  titleEl,
  continueBtn,
  cancelBtn,
  spinnerEl,
  msgEl,
  progressRowsEl,
  createElement,
}) {
  let continueResolve = null;
  let cancelHandler = null;
  let progressRowState = genProgressRows.createGenProgressRowState();
  const mkEl =
    createElement ??
    (typeof document !== "undefined" ? (tag) => document.createElement(tag) : null);

  const showSpinner = (visible) => {
    if (spinnerEl) spinnerEl.hidden = !visible;
  };

  const setMessage = (text) => {
    if (msgEl) msgEl.textContent = text;
  };

  if (titleEl) titleEl.textContent = genText.title;

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
      setMessage(genText.busy);
      if (progressRowsEl && mkEl) {
        progressRowState = genProgressRows.createGenProgressRowState();
        genProgressRows.renderGenProgressRows(progressRowsEl, progressRowState, mkEl, genText);
        genProgressRows.setProgressRowsVisible(progressRowsEl, true);
      }
    },
    close() {
      el.hidden = true;
      cancelHandler = null;
      setButtonsDisabled(true);
      showSpinner(false);
      setMessage(genText.busy);
      if (progressRowsEl && mkEl) {
        genProgressRows.setProgressRowsVisible(progressRowsEl, false);
        progressRowState = genProgressRows.createGenProgressRowState();
        genProgressRows.renderGenProgressRows(progressRowsEl, progressRowState, mkEl, genText);
      }
    },
    setReady(ready) {
      continueBtn.disabled = !ready;
      if (cancelBtn) cancelBtn.disabled = true;
      if (ready) {
        showSpinner(false);
        setMessage(genText.done);
      }
    },
    setCancelling() {
      setButtonsDisabled(true);
      showSpinner(false);
      setMessage(genText.cancelling);
      if (progressRowsEl) genProgressRows.setProgressRowsVisible(progressRowsEl, false);
    },
    renderProgressRows(state) {
      if (!progressRowsEl || !mkEl) return;
      progressRowState = state;
      genProgressRows.renderGenProgressRows(progressRowsEl, progressRowState, mkEl, genText);
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

/** Open modal, run gen task, enable Continue on success, close after Continue. */
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
