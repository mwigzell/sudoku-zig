// status_bar.test.mjs — status bar shows core's text and clears on an empty message.

import assert from "node:assert/strict";
import * as statusBar from "./status_bar.js";

{
  const status = { textContent: "saved to: foo", className: "" };
  statusBar.applyEventStatus(status, { ok: true, msg: null });
  assert.equal(status.textContent, "");

  statusBar.applyEventStatus(status, { ok: true, msg: "opened: bar" });
  assert.equal(status.textContent, "opened: bar");
  assert.equal(status.className, "");
}

console.log("status_bar.test.mjs OK");
