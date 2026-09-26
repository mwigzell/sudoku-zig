// gen_client.test.mjs — worker gen protocol.

import assert from "node:assert/strict";
import { prefetchWorkerScript, startGenInWorker } from "./gen_client.js";

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
  const { promise, cancel } = startGenInWorker({
    workerUrl: "/gen_worker.js",
    wasmBytes: new Uint8Array([0, 1, 2]),
    difficulty: 2,
    logLevel: 1,
    WorkerCtor: MockWorker,
  });
  const worker = MockWorker.instances[0];
  assert.equal(worker.lastPost.type, "run");
  assert.equal(worker.lastPost.difficulty, 2);
  worker.emit({ type: "progress", phase: 1, a: 0, b: 0 });
  worker.emit({ type: "done", line: "0".repeat(81) });
  const out = await promise;
  assert.equal(out.ok, true);
  assert.equal(out.line.length, 81);
  assert.equal(worker.terminated, true);
}

{
  const MockWorker = makeMockWorker();
  const { promise, cancel } = startGenInWorker({
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
  const out = await prefetchWorkerScript("/gen_worker.js", {
    fetchFn: async (url) => {
      calls.push(url);
      return { ok: true, arrayBuffer: async () => new ArrayBuffer(8) };
    },
  });
  assert.equal(out.ok, true);
  assert.equal(calls.length, 1);
}
