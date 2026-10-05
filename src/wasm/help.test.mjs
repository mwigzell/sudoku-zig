// help.test.mjs — Help/About dialog contract.

import assert from "node:assert/strict";
import { showAboutModal, wireHelpAbout, wireAboutModal } from "./help.js";

const sampleInfo = {
  name: "sudoku-zig",
  version: "0.1.0",
  commit: "6737f7",
  build_date: "2026-09-20",
  copyright: "© 2026 Mark Wigzell",
  licence: "MIT",
  summary: "sudoku-zig 0.1.0 (6737f7) — built 2026-09-20 — MIT",
  logo: ["  ╔═══╗", "  ║ S ║", "  ╚═══╝"],
};

function makeModal() {
  return {
    el: { hidden: true },
    titleEl: { textContent: "" },
    summaryEl: { textContent: "" },
    copyrightEl: { textContent: "" },
  };
}

{
  const modal = makeModal();
  showAboutModal(modal, sampleInfo);
  assert.equal(modal.el.hidden, false);
  assert.equal(modal.titleEl.textContent, sampleInfo.name);
  assert.equal(modal.summaryEl.textContent, "sudoku-zig 0.1.0 (6737f7)\nbuilt 2026-09-20");
  assert.equal(modal.copyrightEl.textContent, "© 2026 Mark Wigzell MIT");
}

{
  const aboutBtn = {
    addEventListener(type, fn) {
      assert.equal(type, "click");
      this.click = fn;
    },
  };
  const modal = makeModal();
  wireHelpAbout(aboutBtn, { getAbout: () => sampleInfo }, modal);
  aboutBtn.click();
  assert.equal(modal.titleEl.textContent, sampleInfo.name);
}

{
  const el = { hidden: false };
  const dismiss = {
    addEventListener(type, fn) {
      assert.equal(type, "click");
      this.click = fn;
    },
  };
  wireAboutModal(el, dismiss);
  dismiss.click();
  assert.equal(el.hidden, true);
}

console.log("help.test.mjs OK");
