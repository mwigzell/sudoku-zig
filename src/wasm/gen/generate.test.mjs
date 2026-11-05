// generate.test.mjs — generate step: worker line, cancel, main-thread progress rows, and New's progress from core.

import assert from "node:assert/strict";
import * as generate from "./generate.js";
import * as androidSteps from "../flows/android_steps.js";
import * as stepRunner from "../flows/step_runner.js";
import * as webSteps from "../flows/web_steps.js";
import { flushDialogPaint, generatingModalStub, genText, loadGame } from "../test_support.mjs";

function makeWorkerGenMock({ line, cooperativeCancel = true }) {
  const instances = [];
  class MockWorker {
    constructor(_url, _opts) {
      this.handlers = {};
      instances.push(this);
    }
    postMessage(data) {
      this.lastPost = data;
      if (data?.type === "run") {
        queueMicrotask(() => {
          this.handlers.message?.({ data: { type: "done", line } });
        });
        return;
      }
      if (data?.type === "cancel" && cooperativeCancel) {
        queueMicrotask(() => {
          this.handlers.message?.({ data: { type: "cancelled" } });
        });
      }
    }
    terminate() {
      this.terminated = true;
    }
    set onmessage(fn) {
      this.handlers.message = fn;
    }
    set onerror(fn) {
      this.handlers.error = fn;
    }
  }
  MockWorker.instances = instances;
  return MockWorker;
}

function makeProgressRowsEl() {
  return {
    style: { display: "none" },
    _children: [],
    appendChild(c) {
      this._children.push(c);
    },
    replaceChildren(...n) {
      this._children = n.length ? n : [];
    },
    querySelectorAll(sel) {
      if (sel === ".gen-progress-row") {
        return this._children.filter((c) => c.classList._set.has("gen-progress-row"));
      }
      return this._children;
    },
    querySelector(sel) {
      if (sel === ".gen-progress-attempt-hint") {
        return this._children.find((c) => c.classList._set.has("gen-progress-attempt-hint"));
      }
      return undefined;
    },
    insertBefore(node, ref) {
      const idx = ref ? this._children.indexOf(ref) : this._children.length;
      this._children.splice(idx >= 0 ? idx : this._children.length, 0, node);
    },
  };
}

{
  const line = "1".repeat(81);
  const MockWorker = makeWorkerGenMock({ line });
  const game = {
    getConfig() {
      return { difficulty: 1, log_level: 1, theme: "dark", show_region: false };
    },
  };
  const modal = generatingModalStub();
  const running = generate.generateWithWorker(game, modal, {
    genWorker: {
      workerUrl: "/gen_worker.js",
      wasmBytes: new Uint8Array([0]),
      WorkerCtor: MockWorker,
    },
  });
  await new Promise((r) => setTimeout(r, 0));
  modal.continueBtn.click();
  const out = await running;
  assert.deepEqual(out, { ok: true, line }, "the worker's line goes to core unapplied");
}

{
  const instances = [];
  class HangWorker {
    constructor(_url, _opts) {
      this.handlers = {};
      instances.push(this);
    }
    postMessage(data) {
      if (data?.type === "cancel") {
        queueMicrotask(() => {
          this.handlers.message?.({ data: { type: "cancelled" } });
        });
      }
    }
    terminate() {
      this.terminated = true;
    }
    set onmessage(fn) {
      this.handlers.message = fn;
    }
    set onerror(fn) {
      this.handlers.error = fn;
    }
  }
  const game = {
    getConfig() {
      return { difficulty: 1, log_level: 1 };
    },
  };
  const modal = generatingModalStub();
  const running = generate.generateWithWorker(game, modal, {
    genWorker: {
      workerUrl: "/gen_worker.js",
      wasmBytes: new Uint8Array([0]),
      WorkerCtor: HangWorker,
    },
  });
  await new Promise((r) => setTimeout(r, 0));
  modal.cancelBtn.click();
  const out = await running;
  assert.equal(out.cancelled, true);
  assert.equal(modal.el.hidden, true);
}

{
  let progressCb = null;
  const line = "3".repeat(81);
  const game = {
    setGenProgressListener(cb) {
      progressCb = cb;
    },
    requestGenAbort() {},
    generatePuzzle() {
      progressCb?.(0, "progress line 1");
      progressCb?.(2, "progress line 2");
      return { ok: true, line };
    },
    getConfig() {
      return { difficulty: 2, log_level: 1 };
    },
  };
  const progressRowsEl = makeProgressRowsEl();
  const modal = generatingModalStub({ progressRowsEl });
  const running = generate.generateWithModal(game, modal, { difficulty: 2 });
  await flushDialogPaint();
  assert.equal(progressRowsEl._children[0].textContent, "progress line 1");
  assert.equal(progressRowsEl._children[0].hidden, false);
  const hint = progressRowsEl._children.find((c) => c.classList?._set?.has("gen-progress-attempt-hint"));
  assert.equal(hint?.textContent, genText.fast_strip);
  const rowII = progressRowsEl._children.filter((c) => c.classList?._set?.has("gen-progress-row"))[1];
  assert.equal(rowII.textContent, "progress line 2");
  assert.equal(rowII.hidden, false);
  modal.continueBtn.click();
  const out = await running;
  assert.deepEqual(out, { ok: true, line });
}

// New on web and Android: the real wasm generates, and every line the generating dialog shows is the text core reported.
for (const [platform, makeSteps] of [
  ["web", (game, session, options) => webSteps.webSteps(game, session, options)],
  ["android", (game, session, options) => androidSteps.androidSteps(game, session, {}, options)],
]) {
  const game = await loadGame();
  const reported = [];
  const setGenProgressListener = game.setGenProgressListener.bind(game);
  game.setGenProgressListener = (cb) =>
    setGenProgressListener(cb && ((phase, text) => {
      reported.push(text);
      cb(phase, text);
    }));
  const progressRowsEl = makeProgressRowsEl();
  const modal = generatingModalStub({ progressRowsEl });
  let shownRows = [];
  modal.waitForContinue = async () => {
    shownRows = progressRowsEl._children.filter((c) => c.classList?._set?.has("gen-progress-row") && !c.hidden).map((c) => c.textContent);
  };
  const session = { legend: { new: true }, state: game.getState(), default_save_filename: "sudoku.sud" };
  const outcome = await stepRunner.runCommand(game, { action: "new", difficulty: "easy" }, makeSteps(game, session, { generatingModal: modal }));
  assert.equal(outcome.kind, stepRunner.STEP_DONE, `${platform}: New finishes`);
  assert.ok(reported.length > 0, `${platform}: core reported progress`);
  assert.ok(shownRows.length > 0, `${platform}: the dialog showed progress`);
  for (const row of shownRows) assert.ok(reported.includes(row), `${platform}: dialog row "${row}" is text core reported`);
}
