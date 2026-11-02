// error_modal.test.mjs — error dialog shows core's error text.

import assert from "node:assert/strict";
import * as errorModalMod from "./error_modal.js";
import { coreText } from "../test_support.mjs";

{
  const errorModal = { el: { hidden: true }, msgEl: { textContent: "" } };
  errorModalMod.showErrorModal(errorModal, coreText.PUZZLE_CELL_MSG);
  assert.equal(errorModal.msgEl.textContent, coreText.PUZZLE_CELL_MSG);
  assert.equal(errorModal.el.hidden, false);
}

console.log("error_modal.test.mjs OK");
