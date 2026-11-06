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

// ── overflow: `data-more` while text is hidden below; a new message starts from its first line ──
{
  const handlers = {};
  let observed;
  const win = {
    addEventListener(type, fn) {
      handlers[`win:${type}`] = fn;
    },
    MutationObserver: class {
      constructor(fn) {
        observed = fn;
      }
      observe() {}
    },
  };
  const status = {
    dataset: {},
    scrollTop: 0,
    clientHeight: 20,
    scrollHeight: 20,
    addEventListener(type, fn) {
      handlers[type] = fn;
    },
  };
  statusBar.wireStatusOverflow(status, win);
  assert.equal(status.dataset.more, "false", "one line: nothing hidden");

  status.scrollHeight = 60;
  status.scrollTop = 25;
  observed();
  assert.equal(status.scrollTop, 0, "a new message is shown from its first line");
  assert.equal(status.dataset.more, "true", "a longer message shows the fade");

  status.scrollTop = 40;
  handlers.scroll();
  assert.equal(status.dataset.more, "false", "scrolled to the end: the fade goes");

  status.scrollTop = 10;
  handlers["win:resize"]();
  assert.equal(status.dataset.more, "true");
}

console.log("status_bar.test.mjs OK");
