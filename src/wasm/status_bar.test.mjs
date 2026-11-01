// status_bar.test.mjs — status bar shows core's text and clears on an empty message.

import assert from "node:assert/strict";
import * as statusBar from "./status_bar.js";

{
  const status = { textContent: "The game was saved to foo.", className: "" };
  statusBar.applyEventStatus(status, { ok: true, msg: null });
  assert.equal(status.textContent, "");

  statusBar.applyEventStatus(status, { ok: true, msg: "The file bar is open." });
  assert.equal(status.textContent, "The file bar is open.");
  assert.equal(status.className, "");
}

console.log("status_bar.test.mjs OK");
