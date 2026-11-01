// error_modal.test.mjs — error dialog shows core's error text.

import assert from "node:assert/strict";
import * as errorModalMod from "./error_modal.js";

{
  const errorModal = { el: { hidden: true }, msgEl: { textContent: "" } };
  errorModalMod.showErrorModal(errorModal, "That cell is part of the puzzle, so it can't be changed.");
  assert.equal(errorModal.msgEl.textContent, "That cell is part of the puzzle, so it can't be changed.");
  assert.equal(errorModal.el.hidden, false);
}

console.log("error_modal.test.mjs OK");
