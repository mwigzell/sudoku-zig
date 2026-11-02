// status_bar.test.mjs — status bar shows core's text and clears on an empty message.

import assert from "node:assert/strict";
import * as statusBar from "./status_bar.js";
import { coreText, fillText } from "./test_support.mjs";

{
  const status = { textContent: fillText(coreText.SAVED_TO_FMT, "foo"), className: "" };
  statusBar.applyEventStatus(status, { ok: true, msg: null });
  assert.equal(status.textContent, "");

  statusBar.applyEventStatus(status, { ok: true, msg: fillText(coreText.OPENED_FMT, "bar") });
  assert.equal(status.textContent, fillText(coreText.OPENED_FMT, "bar"));
  assert.equal(status.className, "");
}

console.log("status_bar.test.mjs OK");
