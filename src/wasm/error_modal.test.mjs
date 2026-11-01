// error_modal.test.mjs — error dialog shows core's error text.

import assert from "node:assert/strict";
import * as errorModalMod from "./error_modal.js";

{
  const errorModal = { el: { hidden: true }, msgEl: { textContent: "" } };
  errorModalMod.showErrorModal(errorModal, "cannot modify a puzzle cell");
  assert.equal(errorModal.msgEl.textContent, "cannot modify a puzzle cell");
  assert.equal(errorModal.el.hidden, false);
}

console.log("error_modal.test.mjs OK");
