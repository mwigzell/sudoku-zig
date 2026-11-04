// gen_client.test.mjs — worker gen protocol.

import assert from "node:assert/strict";
import * as genClient from "./gen_client.js";

function makeMockWorker() {
  const instances = [];
  class MockWorker {
    constructor(_url, _opts) {
      this.handlers = {};
      instances.push(this);
    }
    postMessage(data) {
      this.lastPost = data;
    }
    terminate() {
      this.terminated = true;
    }
    addEventListener(type, fn) {
      this.handlers[type] = fn;
    }
    set onmessage(fn) {
      this.handlers.message = fn;
    }
    set onerror(fn) {
      this.handlers.error = fn;
    }
    emit(msg) {
      this.handlers.message?.({ data: msg });
    }
  }
  MockWorker.instances = instances;
  return MockWorker;
}

{
  const MockWorker = makeMockWorker();
  const { promise, cancel } = genClient.startGenInWorker({
    workerUrl: "/gen_worker.js",
    wasmBytes: new Uint8Array([0, 1, 2]),
    difficulty: 2,
    logLevel: 1,
    WorkerCtor: MockWorker,
  });
  const worker = MockWorker.instances[0];
  assert.equal(worker.lastPost.type, "run");
  assert.equal(worker.lastPost.difficulty, 2);
  worker.emit({ type: "progress", phase: 1, text: "progress line 1" });
  worker.emit({ type: "done", line: "0".repeat(81) });
  const out = await promise;
  assert.equal(out.ok, true);
  assert.equal(out.line.length, 81);
  assert.equal(worker.terminated, true);
}

// A core line from the worker's wasm goes to the page's log output as it came.
{
  const MockWorker = makeMockWorker();
  const { promise } = genClient.startGenInWorker({
    workerUrl: "/gen_worker.js",
    wasmBytes: new Uint8Array([0]),
    difficulty: 1,
    logLevel: 1,
    WorkerCtor: MockWorker,
  });
  const worker = MockWorker.instances[0];
  const originalWarn = console.warn;
  const originalFetch = globalThis.fetch;
  const warned = [];
  console.warn = (line) => warned.push(line);
  globalThis.fetch = undefined;
  try {
    worker.emit({ type: "log", level: "warn", scope: "gen", text: "log line 1" });
  } finally {
    console.warn = originalWarn;
    globalThis.fetch = originalFetch;
  }
  assert.deepEqual(warned, ["[gen] log line 1 {}"]);
  worker.emit({ type: "done", line: "0".repeat(81) });
  assert.equal((await promise).ok, true);
}

{
  const MockWorker = makeMockWorker();
  const { promise, cancel } = genClient.startGenInWorker({
    workerUrl: "/gen_worker.js",
    wasmBytes: new Uint8Array([0]),
    difficulty: 3,
    logLevel: 1,
    WorkerCtor: MockWorker,
  });
  const worker = MockWorker.instances[0];
  cancel();
  assert.equal(worker.lastPost?.type, "cancel");
  assert.notEqual(worker.terminated, true, "cooperative cancel waits for ack or timeout");
  worker.emit({ type: "cancelled" });
  const out = await promise;
  assert.equal(worker.terminated, true);
  assert.equal(out.ok, false);
  assert.equal(out.cancelled, true);
}

{
  const calls = [];
  const out = await genClient.prefetchWorkerScript("/gen_worker.js", {
    fetchFn: async (url) => {
      calls.push(url);
      return { ok: true, arrayBuffer: async () => new ArrayBuffer(8) };
    },
  });
  assert.equal(out.ok, true);
  assert.equal(calls.length, 1);
}
